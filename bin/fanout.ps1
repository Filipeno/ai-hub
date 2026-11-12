# Split a big job into chunks, run the chunks on several AIs at the same time, then combine the answers.
#   fanout.ps1 -Task "<question>" -Source <file|folder|name> [...] -Out <final answer file>
#              [-Kind big-read|web-research|summarize|extract|general] [-Effort low|medium|high] [-Reduce "<how to combine>"]
#              [-MaxChunks 8] [-ChunkKb <n>] [-Workers 4]
#   fanout.ps1 -Resume <job id>        run only the chunks that have no answer yet (after a quota stop or a crash)
# Why: a free Gemini key allows about 20 requests per model per day, and a job that runs out half way loses everything.
# Here each chunk is ONE request on its own, its answer is saved the moment it arrives, and ask.ps1 moves a failed
# chunk to the next helper or model. Chunks go round-robin over the ready helpers of the kind, so Gemini keys, the Gemini
# app (large chunks) and Codex work in parallel. Then one more request combines the partial answers.
# Exit codes: 0 done | 2 bad arguments | 3 some chunks have no answer (resume with -Resume) | 4 source too big for -MaxChunks | 10 a helper asked a question
param(
    [string]$Task,
    [string[]]$Source,
    [string]$Out,
    [string]$Kind = 'big-read',
    [ValidateSet('', 'low', 'medium', 'high')][string]$Effort = '',
    [string]$Reduce,
    [int]$MaxChunks = 8,
    [int]$ChunkKb = 0,
    [int]$Workers = 4,
    [string]$Resume
)
. "$PSScriptRoot\lib\hub.ps1"
. "$PSScriptRoot\lib\collect.ps1"
$hub = $script:Hub
$route = Get-Content (Join-Path $hub 'routing.json') -Raw | ConvertFrom-Json -AsHashtable
$ask = Join-Path $hub 'bin\ask.ps1'

function Test-Parked([string]$id) {
    $f = Join-Path $hub 'state\cooldown.json'
    if (-not (Test-Path $f)) { return $false }
    $c = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable
    return ($c.ContainsKey($id) -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [int64]$c[$id])
}

# ---- set up or resume the job ----
if ($Resume) {
    $work = Join-Path $hub "files\fanout\$Resume"
    if (-not (Test-Path "$work\state.json")) { Write-Output "ERROR: no fanout job $Resume."; exit 2 }
    $st = Get-Content "$work\state.json" -Raw | ConvertFrom-Json
    $Task = $st.task; $Out = $st.out; $Kind = $st.kind; $Effort = $st.effort; $Reduce = $st.reduce; $n = [int]$st.chunks
    $jobId = $Resume
} else {
    if (-not ($Task -and $Source -and $Out)) { Write-Output 'ERROR: -Task, -Source and -Out are required (or -Resume <id>).'; exit 2 }
    $kindInfo = if ($route.kinds.ContainsKey($Kind)) { $route.kinds[$Kind] } else { $route.kinds['general'] }
    if (-not $Effort) { $Effort = $kindInfo.effort }
    $files = @(Get-SourceFiles $Source)
    if ($files.Count -eq 0) { Write-Output 'ERROR: no readable files found in -Source (secrets, dependencies and binaries are skipped).'; exit 2 }
    $skipped = $script:CollectSkipped

    # chunk size: the Gemini app takes much more per request than the CLI keys
    $appReady = -not (Test-Parked 'gemini-app') -and ($kindInfo.chain -contains 'gemini-app')
    if (-not $ChunkKb) { $ChunkKb = if ($appReady -and $Kind -in 'big-read', 'web-research') { [int]$route.limits.gemini_app_chunk_kb } else { [int]$route.limits.gemini_chunk_kb } }
    $limit = $ChunkKb * 1KB

    # pack files into chunks; a file bigger than one chunk is cut at line breaks
    $chunks = [System.Collections.Generic.List[string]]::new()
    $buf = [System.Text.StringBuilder]::new()
    foreach ($f in $files) {
        $body = Get-Content $f.Path -Raw -ErrorAction SilentlyContinue
        if (-not $body) { continue }
        $piece = "`n===== FILE: $($f.Rel) =====`n$body"
        while ($piece.Length -gt $limit) {
            $cut = $piece.LastIndexOf("`n", $limit - 1); if ($cut -lt 1) { $cut = $limit }
            if ($buf.Length -gt 0) { $chunks.Add($buf.ToString()); [void]$buf.Clear() }
            $chunks.Add($piece.Substring(0, $cut)); $piece = "`n===== (continued: $($f.Rel)) =====`n" + $piece.Substring($cut)
        }
        if ($buf.Length + $piece.Length -gt $limit) { $chunks.Add($buf.ToString()); [void]$buf.Clear() }
        [void]$buf.Append($piece)
    }
    if ($buf.Length -gt 0) { $chunks.Add($buf.ToString()) }
    $n = $chunks.Count
    if ($n -gt $MaxChunks) {
        Write-Output "TOO BIG: $($files.Count) files make $n chunks of $ChunkKb KB; the limit is -MaxChunks $MaxChunks. Narrow -Source (a subfolder or single files) or raise -MaxChunks on purpose."
        exit 4
    }
    $jobId = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $work = Join-Path $hub "files\fanout\$jobId"
    New-Item -ItemType Directory -Force $work | Out-Null
    for ($i = 0; $i -lt $n; $i++) { Set-Content (Join-Path $work ('c{0:00}.in.txt' -f ($i + 1))) $chunks[$i] -Encoding UTF8 }
    [pscustomobject]@{ task = $Task; out = $Out; kind = $Kind; effort = $Effort; reduce = $Reduce; chunks = $n; chunkKb = $ChunkKb; files = $files.Count; skipped = $skipped } |
        ConvertTo-Json | Set-Content "$work\state.json"
    Write-Output "Job $jobId : $($files.Count) files, $n chunk(s) of up to $ChunkKb KB, $skipped file(s) skipped for safety."
}

# ---- lanes: the ready helpers of this kind, round-robin ----
$kindInfo = if ($route.kinds.ContainsKey($Kind)) { $route.kinds[$Kind] } else { $route.kinds['general'] }
$lanes = @($kindInfo.chain | Where-Object { $_ -ne 'agy' -and -not (Test-Parked $_) })
if ($lanes.Count -eq 0) { $lanes = @('gemini') }

$todo = 1..$n | Where-Object { -not (Test-Path (Join-Path $work ('c{0:00}.md' -f $_))) }
if ($todo.Count -eq 0) { Write-Output 'All chunks already have answers.' }
else {
    $mapRule = if ($n -gt 1) { "You receive PART {0} of $n of the material (attached or below). Answer only from this part and name the files you used. If this part has nothing relevant, reply exactly: NOTHING RELEVANT. Be concise and concrete." } else { 'The material is attached or below. Name the files you used.' }
    $results = $todo | ForEach-Object -ThrottleLimit ([math]::Min($Workers, $todo.Count)) -Parallel {
        $i = $_; $lane = ($using:lanes)[($i - 1) % ($using:lanes).Count]
        $c = '{0:00}' -f $i
        $brief = "$($using:Task)`n`n" + (($using:mapRule) -f $i)
        $o = & $using:ask -Helper $lane -Kind $using:Kind -Effort $using:Effort -Dir $using:work -Out "$using:work\c$c.md" -InputFile "$using:work\c$c.in.txt" -Task $brief -NoDisk 2>&1 | Out-String
        [pscustomobject]@{ chunk = $i; lane = $lane; code = $LASTEXITCODE; text = $o.Trim() }
    }
    foreach ($r in ($results | Sort-Object chunk)) {
        $line = ($r.text -split "`n" | Select-Object -Last 1)
        Write-Output ("  chunk {0,2}  lane {1,-10} {2}" -f $r.chunk, $r.lane, $line)
    }
    $q = $results | Where-Object { $_.text -match 'QUESTION id=' } | Select-Object -First 1
    if ($q) { Write-Output "A helper asked a question: $($q.text -split "`n" | Where-Object { $_ -match 'QUESTION id=' } | Select-Object -First 1). Answer it (ask.ps1 -AnswerId ...), then run: fanout.ps1 -Resume $jobId"; exit 10 }
}

$missing = 1..$n | Where-Object { -not (Test-Path (Join-Path $work ('c{0:00}.md' -f $_))) }
if ($missing.Count -gt 0) {
    Write-Output "INCOMPLETE: no answer for chunk(s) $($missing -join ', '). The finished chunks are saved. Run: pwsh -NoProfile -File $hub\bin\fanout.ps1 -Resume $jobId"
    exit 3
}

# ---- combine ----
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
if ($n -eq 1) { Copy-Item (Join-Path $work 'c01.md') $Out -Force; Write-Output "OK out=$Out (1 chunk, no combine step)"; exit 0 }
$parts = 1..$n | ForEach-Object { "## Part $_`n" + (Get-Content (Join-Path $work ('c{0:00}.md' -f $_)) -Raw) }
Set-Content "$work\partials.md" ($parts -join "`n`n") -Encoding UTF8
$combine = if ($Reduce) { $Reduce } else { "Combine the partial answers into one final answer. Remove duplicates, keep the file names, mention contradictions between parts, and drop parts that say NOTHING RELEVANT." }
$o = & $ask -Kind summarize -Effort $Effort -Dir $work -Out $Out -InputFile "$work\partials.md" -NoDisk -Task "The question was: $Task`n`n$combine" 2>&1 | Out-String
$o.Trim() -split "`n" | Select-Object -Last 1 | ForEach-Object { Write-Output "combine: $_" }
if ($LASTEXITCODE -ne 0) { Write-Output "Combine step failed; the partial answers are in $work\partials.md. Run fanout.ps1 -Resume $jobId to retry the combine."; exit $LASTEXITCODE }
Write-Output "OK out=$Out ($n chunks, job $jobId)"
exit 0
