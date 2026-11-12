# Run one job on the best helper AI, with model + effort chosen per task, automatic fallback, and question passing.
#   ask.ps1 -Task "<brief>" -Out <answer file> -Dir <folder> [-Kind <kind>] [-Effort low|medium|high] [-Helper auto|gemini|gemini-app|codex|agy]
#           [-Mode read|edit] [-InputFile <material file>] [-DriveFile "name.md"] [-NoDisk] [-Model <override>] [-NoFallback]
#   ask.ps1 -AnswerId <id> -Answer "<text>"      answer a helper's question and run the job again
# Routing knowledge lives in <hub>\routing.json (who is good at what, models per effort, limits). Edit that, not this.
#   -Kind    web-research | big-read | summarize | extract | qa | second-opinion | code-edit | image | general (default general).
#            It sets the helper order and the default effort. -Helper (not auto) puts one helper first.
#   -Effort  low = fast and cheap model, medium = everyday, high = strongest free model with long thinking.
#            It picks the model: Gemini CLI model list, Gemini app model + thinking level, Codex reasoning effort, agy model.
#   -InputFile  material for the job (text). Gemini CLI/Codex get it on stdin (one request, no folder roaming);
#            the Gemini app gets it uploaded as a file. Keep it under the chunk limits in routing.json (fanout.ps1 splits big input).
#   -NoDisk  the task needs nothing from the PC's disk, so the Gemini app may take it without attached files.
# Helpers: gemini (free API keys) | gemini-app (Google AI plan, hidden Chrome, 25 jobs/day) | perplexity (pay-as-you-go API, cited web search) | codex (only one that edits) | agy (tiny weekly quota).
# Questions: every brief tells the helper to reply "QUESTION: ..." instead of guessing; saved in <hub>\state\questions, exit 10.
# Exit codes: 0 done | 2 bad arguments | 3 no helper could do it | 10 the helper asked a question (answer with -AnswerId)
param(
    [ValidateSet('auto', 'gemini', 'gemini-app', 'perplexity', 'codex', 'agy')][string]$Helper = 'auto',
    [ValidateSet('read', 'edit')][string]$Mode = 'read',
    [string]$Kind = 'general',
    [ValidateSet('', 'low', 'medium', 'high')][string]$Effort = '',
    [string]$Dir,
    [string]$Out,
    [string]$Task,
    [string]$InputFile,
    [string]$Model,
    [switch]$NoDisk,
    [switch]$NoFallback,   # run only the named -Helper; fail instead of moving to the next one (used by council.ps1)
    [string]$AnswerId,
    [string]$Answer,
    [string[]]$DriveFile   # file names in your Google Drive to attach (gemini-app only; works for folders you sync to Drive)
)

. "$PSScriptRoot\lib\hub.ps1"
$hub = $script:Hub
$cfg = Get-HubConfig
$stateDir = Join-Path $hub 'state'
$questionDir = Join-Path $stateDir 'questions'
$cooldownFile = Join-Path $stateDir 'cooldown.json'
$appCountFile = Join-Path $stateDir 'gemini-app-count.json'
$pplxCountFile = Join-Path $stateDir 'perplexity-count.json'
$logFile = Join-Path $stateDir 'ask.log'
New-Item -ItemType Directory -Force $stateDir, $questionDir | Out-Null

$route = Get-Content (Join-Path $hub 'routing.json') -Raw | ConvertFrom-Json -AsHashtable
$AppDailyCap = [int]$route.limits.gemini_app_daily_cap
$park = $route.limits.park_hours

$limitRx = 'usage limit|quota|rate.?limit|429|exhausted|too many requests|try again (later|in)|capacity|limit (is )?reached'
$busyRx = 'high demand|503|overloaded|temporarily unavailable'
$goneRx = 'no longer available|404|not found for api|is not found'
$authRx = 'not logged in|log ?in|unauthenticated|401|403|api key|ineligible|no longer supported|not signed in'
$questionRule = "If you cannot do this task well without more information, do not guess: reply with only one line that starts with QUESTION: followed by your question."

function Write-Log([string]$msg) { Add-Content $logFile ("{0:yyyy-MM-dd HH:mm} {1}" -f (Get-Date), $msg) }

# ---- answering a question: load the saved job and run it again with the answer ----
$qa = @()
if ($AnswerId) {
    $qFile = Join-Path $questionDir "$AnswerId.json"
    if (-not (Test-Path $qFile)) { Write-Output "ERROR: no open question with id $AnswerId."; exit 2 }
    if (-not $Answer) { Write-Output 'ERROR: -Answer "<text>" is required with -AnswerId.'; exit 2 }
    $saved = Get-Content $qFile -Raw | ConvertFrom-Json
    $Helper = $saved.helper; $Mode = $saved.mode; $Dir = $saved.dir; $Out = $saved.out; $Task = $saved.task
    $DriveFile = @($saved.driveFile | Where-Object { $_ }); $Kind = "$($saved.kind)"; $Effort = "$($saved.effort)"; $InputFile = "$($saved.inputFile)"
    if (-not $Kind) { $Kind = 'general' }
    $qa = @($saved.qa | Where-Object { $_ }) + @([pscustomobject]@{ q = $saved.question; a = $Answer })
    Remove-Item $qFile
    Get-ChildItem (Join-Path $hub 'inbox\claude') -Filter "*$AnswerId*.md" -ErrorAction SilentlyContinue |
        Move-Item -Destination (Join-Path $hub 'inbox\claude\done') -Force
    Write-Log "answer to $AnswerId given; running again"
}
if (-not ($Dir -and $Out -and $Task)) { Write-Output 'ERROR: -Dir, -Out and -Task are required (or -AnswerId and -Answer).'; exit 2 }
if ($InputFile -and -not (Test-Path $InputFile)) { Write-Output "ERROR: input file not found: $InputFile"; exit 2 }
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null

$kindInfo = if ($route.kinds.ContainsKey($Kind)) { $route.kinds[$Kind] } else { $route.kinds['general'] }
if (-not $Effort) { $Effort = $kindInfo.effort }
if ($kindInfo.noDisk) { $NoDisk = [switch]::Present }
if ($kindInfo.edit -and $Mode -eq 'read') { $Mode = 'edit' }

$prompt = $Task
foreach ($p in $qa) { $prompt += "`n`nEarlier you asked: $($p.q)`nAnswer: $($p.a)" }
$prompt += "`n`n$questionRule"

# ---- cooldowns (ids: codex, agy, gemini-app, gemini#<last4>@<model> = one key on one model, gemini@<model> = model busy/gone) ----
function Get-Cooldown {
    if (Test-Path $cooldownFile) { try { return Get-Content $cooldownFile -Raw | ConvertFrom-Json -AsHashtable } catch {} }
    return @{}
}
function Set-Cooldown([string]$who, [double]$hours) {
    # Several ask.ps1 processes can run at once (fanout.ps1): take a machine-wide lock around the read-modify-write.
    $lock = [System.Threading.Mutex]::new($false, 'Global\ai-hub-cooldown')
    try { [void]$lock.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] {}
    try {
        $c = Get-Cooldown
        $c[$who] = [DateTimeOffset]::UtcNow.AddHours($hours).ToUnixTimeSeconds()
        $c | ConvertTo-Json | Set-Content $cooldownFile
    } finally { try { $lock.ReleaseMutex() } catch {} }
}
function Test-Cooldown([string]$who) {
    $c = Get-Cooldown
    return ($c.ContainsKey($who) -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [int64]$c[$who])
}

# ---- Gemini keys: the file named by geminiKeysFile in config.json (default ~\.gemini\api-keys.txt, one per line), else the user env variable. Never printed or logged. ----
function Get-GeminiKeys {
    $f = $cfg.geminiKeysFile
    $keys = @()
    if (Test-Path $f) { $keys = @(Get-Content $f | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) }
    if ($keys.Count -eq 0) {
        $k = [Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')
        if ($k) { $keys = @($k) }
    }
    return ,$keys
}
function Get-GeminiModels { if ($Model) { return ,@($Model) } else { return ,@($route.models.gemini[$Effort]) } }
function Test-GeminiReady {
    foreach ($m in (Get-GeminiModels)) {
        if (Test-Cooldown "gemini@$m") { continue }
        foreach ($k in (Get-GeminiKeys)) { if (-not (Test-Cooldown ("gemini#" + $k.Substring($k.Length - 4) + "@$m"))) { return $true } }
    }
    return $false
}

# ---- Gemini app daily cap ----
function Get-AppCount {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (Test-Path $appCountFile) { try { $c = Get-Content $appCountFile -Raw | ConvertFrom-Json; if ($c.date -eq $today) { return [int]$c.count } } catch {} }
    return 0
}
function Add-AppCount { @{ date = (Get-Date).ToString('yyyy-MM-dd'); count = (Get-AppCount) + 1 } | ConvertTo-Json | Set-Content $appCountFile }

# ---- Perplexity (pay-as-you-go API): key, and a daily job cap so a loop cannot run up a bill ----
function Get-PerplexityKey {
    $f = $cfg.perplexityKeyFile
    if ($f -and (Test-Path $f)) { $k = (Get-Content $f -Raw).Trim(); if ($k) { return $k } }
    return [Environment]::GetEnvironmentVariable('PERPLEXITY_API_KEY', 'User')
}
function Get-PplxCount {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (Test-Path $pplxCountFile) { try { $c = Get-Content $pplxCountFile -Raw | ConvertFrom-Json; if ($c.date -eq $today) { return [int]$c.count } } catch {} }
    return 0
}
function Add-PplxCount { @{ date = (Get-Date).ToString('yyyy-MM-dd'); count = (Get-PplxCount) + 1 } | ConvertTo-Json | Set-Content $pplxCountFile }

function Get-Reason([string]$all) {
    if ($all -match $busyRx) { 'busy' } elseif ($all -match $limitRx) { 'limit' } elseif ($all -match $goneRx) { 'model_gone' } elseif ($all -match $authRx) { 'auth' } else { 'error' }
}
function Get-Detail([string]$all) { ($all.Trim() -split "`n" | Select-Object -Last 2) -join ' ' }
function Get-Material { if ($InputFile) { Get-Content $InputFile -Raw } else { $null } }

# Returns @{ ok; reason; detail; model } for one helper. On ok the answer is in $Out.
function Invoke-Helper([string]$who) {
    $err = New-TemporaryFile
    try {
        switch ($who) {
            'codex' {
                $cfg = $route.models.codex[$Effort]
                $cargs = @('exec', '--skip-git-repo-check', '-s', $(if ($Mode -eq 'edit') { 'workspace-write' } else { 'read-only' }), '-C', $Dir, '-o', $Out,
                    '-c', "model_reasoning_effort=$($cfg.effort)")
                $codexModel = if ($Model) { $Model } else { $cfg.model }
                if ($codexModel) { $cargs += @('-m', $codexModel) }   # empty = Codex's own default model
                $material = Get-Material
                if ($material) { $text = ("$prompt`n`n--- MATERIAL ---`n$material") | & codex @cargs - 2>$err | Out-String }
                else { $text = & codex @cargs $prompt 2>$err | Out-String }
                $code = $LASTEXITCODE
                $answer = if (Test-Path $Out) { Get-Content $Out -Raw } else { '' }
                $usedModel = "$(if ($codexModel) { $codexModel } else { 'default' })/$($cfg.effort)"
            }
            'perplexity' {
                # Perplexity Agent API (pay as you go): live web search with sources. Needs a key: perplexity-key add
                $key = Get-PerplexityKey
                if (-not $key) { return @{ ok = $false; reason = 'auth'; detail = 'no Perplexity API key (run: perplexity-key add)' } }
                $cap = [int]$route.limits.perplexity_daily_cap
                if ((Get-PplxCount) -ge $cap) { return @{ ok = $false; reason = 'cap'; detail = "daily cap of $cap Perplexity jobs reached" } }
                $material = Get-Material
                $inputText = if ($material) { "$prompt`n`n--- MATERIAL ---`n$material" } else { $prompt }
                $base = if ($cfg.perplexityBaseUrl) { $cfg.perplexityBaseUrl } else { 'https://api.perplexity.ai' }
                $body = @{ effort = $route.models.perplexity[$Effort]; input = $inputText } | ConvertTo-Json -Depth 5 -Compress
                Add-PplxCount
                try {
                    $res = Invoke-RestMethod -Method Post -Uri "$base/v1/agent" -Headers @{ Authorization = "Bearer $key" } `
                        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240
                } catch {
                    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    $msg = "$($_.ErrorDetails.Message)"
                    $why = if ($status -in 401, 403) { 'auth' }
                           elseif ($status -eq 402 -or $msg -match 'credit|billing|insufficient|payment') { 'limit' }   # out of credit: top up, then it comes back
                           elseif ($status -eq 429 -or $status -ge 500 -or $msg -match 'overloaded') { 'busy' }
                           elseif ($status -eq 404) { 'model_gone' }
                           else { 'error' }
                    return @{ ok = $false; reason = $why; detail = "HTTP $status " + $msg.Substring(0, [Math]::Min(150, $msg.Length)) }
                }
                $message = @($res.output | Where-Object { $_.type -eq 'message' }) | Select-Object -Last 1
                $answer = (@($message.content | Where-Object { $_.type -eq 'output_text' }) | ForEach-Object { $_.text }) -join "`n"
                $sources = @($res.output | Where-Object { $_.type -eq 'search_results' } | ForEach-Object { $_.results })
                if ($answer.Trim() -and $sources.Count -gt 0) {
                    $answer += "`n`nSources:`n" + ((@($sources | Select-Object -First 8 | ForEach-Object { "- $($_.title) - $($_.url)" })) -join "`n")
                }
                if (-not $answer.Trim()) { return @{ ok = $false; reason = 'error'; detail = 'Perplexity returned no answer text' } }
                Set-Content $Out $answer
                $cost = $res.usage.cost.total_cost
                if ($cost) { Write-Log ("perplexity cost `${0}" -f $cost) }
                return @{ ok = $true; model = "agent/$Effort" }
            }
            'agy' {
                $agy = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
                if (-not (Test-Path $agy)) { return @{ ok = $false; reason = 'auth'; detail = 'agy not installed' } }
                $material = Get-Material
                if ($material -and $material.Length -gt ([int]$route.limits.agy_max_inline_kb * 1KB)) { return @{ ok = $false; reason = 'skip'; detail = 'material too big for agy' } }
                $agyPrompt = if ($material) { "$prompt`n`n--- MATERIAL ---`n$material" } else { $prompt }
                $agyArgs = @('-p', $agyPrompt, '--mode', 'plan', '--effort', $Effort, '--print-timeout', '5m')
                if ($Model) { $agyArgs += @('--model', $Model) }   # otherwise agy's own default model
                $usedModel = if ($Model) { $Model } else { 'default' }
                Push-Location $Dir
                try { $answer = & $agy @agyArgs 2>$err | Out-String; $code = $LASTEXITCODE } finally { Pop-Location }
                $text = $answer
                if ($code -eq 0 -and $answer.Trim()) { Set-Content $Out $answer }
            }
            'gemini-app' {
                # Hidden Chrome robot typing into gemini.google.com. Exit 4 = not signed in, 5 = app limit reached, 6 = Drive file not found.
                # One robot Chrome only: jobs from parallel ask.ps1 processes wait their turn here.
                $robotLock = [System.Threading.Mutex]::new($false, 'Global\gemini-app-robot')
                try { [void]$robotLock.WaitOne(900000) } catch [System.Threading.AbandonedMutexException] {}
                if ((Get-AppCount) -ge $AppDailyCap) { try { $robotLock.ReleaseMutex() } catch {}; return @{ ok = $false; reason = 'cap'; detail = "daily cap of $AppDailyCap jobs reached" } }
                Add-AppCount
                $cfg = $route.models['gemini-app'][$Effort]
                $robot = @('--task', $prompt, '--out', $Out, '--timeout', '300', '--model', $cfg.model, '--think', $cfg.think)
                foreach ($f in $DriveFile) { $robot += @('--drive', $f) }
                if ($InputFile) { $robot += @('--file', $InputFile) }
                try { $text = & node (Join-Path $hub 'gemini-app\ask.mjs') @robot 2>$err | Out-String; $code = $LASTEXITCODE } finally { try { $robotLock.ReleaseMutex() } catch {} }
                $answer = if ($code -eq 0 -and (Test-Path $Out)) { Get-Content $Out -Raw } else { '' }
                $usedModel = "$($cfg.model)/$($cfg.think)"
                if ($code -eq 4) { return @{ ok = $false; reason = 'auth'; detail = 'robot Chrome not signed in (run: gemini-app login)' } }
                if ($code -eq 6) { return @{ ok = $false; reason = 'error'; detail = 'Drive file not found by the Gemini picker' } }
                if ($code -eq 7) { return @{ ok = $false; reason = 'busy'; detail = 'Gemini app answered with an error message' } }
                if ($code -eq 5) { return @{ ok = $false; reason = 'limit'; detail = 'Gemini app says the limit is reached' } }
            }
            'gemini' {
                # Per effort a list of models; each (key, model) pair has its own daily quota and its own parking.
                $last = @{ ok = $false; reason = 'limit'; detail = 'no Gemini key/model available' }
                $material = Get-Material
                foreach ($m in (Get-GeminiModels)) {
                    if (Test-Cooldown "gemini@$m") { continue }
                    foreach ($key in (Get-GeminiKeys)) {
                        $tail = $key.Substring($key.Length - 4)
                        $id = "gemini#$tail@$m"
                        if (Test-Cooldown $id) { continue }
                        # Run the CLI in a job with a time limit: it retries some errors (e.g. a 429 inside its web search) forever.
                        $job = Start-Job -ArgumentList $prompt, $m, $material, $key, $Dir, $err -ScriptBlock {
                            param($prompt, $m, $material, $key, $dir, $err)
                            $env:GEMINI_API_KEY = $key
                            Set-Location $dir
                            if ($material) { $text = $material | & gemini -p $prompt -m $m --skip-trust 2>$err | Out-String }
                            else { $text = & gemini -p $prompt -m $m --skip-trust 2>$err | Out-String }
                            @{ answer = $text; code = $LASTEXITCODE }
                        }
                        if (Wait-Job $job -Timeout $route.limits.gemini_cli_timeout_seconds) {
                            $res = Receive-Job $job; $answer = "$($res.answer)"; $code = $res.code
                        } else {
                            Stop-Job $job; $answer = ''; $code = 124
                            Add-Content $err "temporarily unavailable: timed out after $($route.limits.gemini_cli_timeout_seconds) s"
                        }
                        Remove-Job $job -Force
                        if ($code -eq 0 -and $answer.Trim()) { Set-Content $Out $answer; return @{ ok = $true; model = $m } }
                        $all = $answer + (Get-Content $err -Raw)
                        $reason = Get-Reason $all
                        $last = @{ ok = $false; reason = $reason; detail = "key ...$tail on ${m}: " + (Get-Detail $all) }
                        switch ($reason) {
                            'limit' { Set-Cooldown $id $park.limit; Write-Log "gemini key ...$tail hit its limit on $m"; continue }
                            'busy' { Set-Cooldown "gemini@$m" $park.busy; Write-Log "gemini $m busy"; break }
                            'model_gone' { Set-Cooldown "gemini@$m" $park.model_gone; Write-Log "gemini $m not available"; break }
                            'auth' { Set-Cooldown $id $park.key_rejected; Write-Log "gemini key ...$tail rejected on $m"; continue }
                            default { return $last }   # other error: the task itself is the problem
                        }
                        if ($reason -in 'busy', 'model_gone') { break }   # next model
                    }
                }
                return $last
            }
        }
        if ($code -eq 0 -and $answer -and $answer.Trim()) { return @{ ok = $true; model = $usedModel } }
        $all = "$text" + (Get-Content $err -Raw)
        return @{ ok = $false; reason = (Get-Reason $all); detail = (Get-Detail $all) }
    } finally { Remove-Item $err -ErrorAction SilentlyContinue }
}

# Saves a helper's question and tells the caller. The boss AI answers it, or asks the user.
function Save-Question([string]$who, [string]$question) {
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + "-$who"
    [pscustomobject]@{ id = $id; helper = $who; mode = $Mode; dir = $Dir; out = $Out; task = $Task; driveFile = $DriveFile; kind = $Kind; effort = $Effort; inputFile = $InputFile; qa = $qa; question = $question } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $questionDir "$id.json")
    $msg = @"
# Question from $who
From: $who   To: claude   Date: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))   Id: $id
## Question
$question
## Original task
$Task
## How to answer
The boss AI answers if it knows; otherwise it asks the user. Then run:
pwsh -NoProfile -File "$hub\bin\ask.ps1" -AnswerId $id -Answer "<answer>"
(The user can also run: ask-answer $id "<answer>")
"@
    Set-Content (Join-Path $hub "inbox\claude\$((Get-Date).ToString('yyyy-MM-dd-HHmm'))-from-$who-question-$id.md") $msg
    Remove-Item $Out -ErrorAction SilentlyContinue
    Write-Log "$who asked a question ($id)"
    Write-Output "QUESTION id=$id helper=${who}: $question"
    exit 10
}

# ---- build the chain: the kind's helper order, an explicit -Helper first ----
$chain = @($kindInfo.chain)
if ($Mode -eq 'edit') { $chain = @('codex') }
elseif ($Helper -ne 'auto') { $chain = @($Helper) + @($chain | Where-Object { $_ -ne $Helper }) }
if ($Mode -eq 'edit' -and $Helper -notin 'auto', 'codex') { Write-Output 'ERROR: Only Codex edits files. Use -Helper codex or do the job yourself.'; exit 2 }
# The Gemini app cannot see the PC's disk: it joins only for tasks without local files, or with files attached/uploaded, or when named.
$appOk = $NoDisk -or $DriveFile -or $InputFile -or $Helper -eq 'gemini-app'
if (-not $appOk) { $chain = @($chain | Where-Object { $_ -ne 'gemini-app' }) }
# Perplexity cannot see the PC's disk either, and it costs money per request: it joins only when the job needs no local files.
if (-not ($NoDisk -or $InputFile -or $Helper -eq 'perplexity')) { $chain = @($chain | Where-Object { $_ -ne 'perplexity' }) }
if ($NoFallback -and $Helper -ne 'auto') { $chain = @($Helper) }
# Always keep the rest of the helpers as last resorts (read jobs only).
if ($Mode -ne 'edit' -and -not $NoFallback) { foreach ($h in 'gemini', 'gemini-app', 'codex', 'agy') { if ($h -notin $chain -and $h -notin @($kindInfo.never) -and ($h -ne 'gemini-app' -or $appOk)) { $chain += $h } } }

# Only the AIs the user chose to connect (config.json, written by install.ps1) take part.
$chain = @($chain | Where-Object { Test-HelperEnabled $_ $cfg })
if ($chain.Count -eq 0) { Write-Output 'ERROR: none of the AIs this job needs is connected. Run install.ps1 again or edit "enabled" in config.json.'; exit 3 }

Write-Log "job kind=$Kind effort=$Effort mode=$Mode chain=$($chain -join '>')"
foreach ($who in $chain) {
    $parked = if ($who -eq 'gemini') { -not (Test-GeminiReady) } else { Test-Cooldown $who }
    if ($parked) { Write-Log "$who skipped (cooldown)"; continue }
    $r = Invoke-Helper $who
    if ($r.ok) {
        $first = (Get-Content $Out | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($first -match '^\W*QUESTION:\s*(.+)$') { Save-Question $who $Matches[1].Trim() }
        Write-Log "$who ok ($Mode, $Effort, $($r.model)) -> $Out"
        Write-Output "OK helper=$who model=$($r.model) effort=$Effort out=$Out"
        exit 0
    }
    if ($who -ne 'gemini' -and $r.reason -notin 'cap', 'skip') {   # Gemini parks each key+model on its own, inside Invoke-Helper
        switch ($r.reason) {
            'limit' { Set-Cooldown $who $(if ($who -eq 'agy') { $park.agy_limit } else { $park.limit }) }
            'busy'  { Set-Cooldown $who $park.busy }
            'auth'  { Set-Cooldown $who $park.auth }
        }
    }
    Write-Log "$who failed: $($r.reason) $($r.detail)"
}

Write-Output "FAILED: no helper could do this job (see $logFile). Do the job yourself and note it in HANDOFF.md."
exit 3
