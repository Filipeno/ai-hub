# Decide where a job should go: which helper chain, which effort (model), whether to split it, or whether to just do it yourself.
# Costs no model usage: it measures the input and applies the rules in <hub>\routing.json.
#   route.ps1 -Task "<what you want done>" [-Source <file|folder|name> ...] [-Kind <kind>] [-Effort low|medium|high] [-Edit]
# Prints a JSON plan and the exact command to run. Claude may override any field: it knows the conversation, this script does not.
param(
    [Parameter(Mandatory)][string]$Task,
    [string[]]$Source,
    [string]$Kind,
    [ValidateSet('', 'low', 'medium', 'high')][string]$Effort = '',
    [switch]$Edit
)
. "$PSScriptRoot\lib\hub.ps1"
. "$PSScriptRoot\lib\collect.ps1"
$hub = $script:Hub
$route = Get-Content (Join-Path $hub 'routing.json') -Raw | ConvertFrom-Json -AsHashtable
$t = $route.triggers
$lim = $route.limits

# ---- measure the input ----
$files = @(if ($Source) { Get-SourceFiles $Source })
$bytes = [int64]($files | Measure-Object Size -Sum).Sum
$kb = [math]::Round($bytes / 1KB)

# ---- kind ----
$why = @()
if (-not $Kind) {
    if ($Task -match $t.image) { $Kind = 'image'; $why += 'asks for an image' }
    elseif ($Edit -or ($Task -match $t.edit -and $Source)) { $Kind = 'code-edit'; $why += 'changes files: only Codex may' }
    elseif ($Task -match $t.web) { $Kind = 'web-research'; $why += 'needs live or recent facts: the Gemini app has Google Search' }
    elseif ($Task -match $t.opinion) { $Kind = 'second-opinion'; $why += 'wants judgement or a comparison' }
    elseif ($kb -gt [int]$lim.gemini_chunk_kb) { $Kind = 'big-read'; $why += "input is $kb KB, beyond one Gemini-CLI request" }
    elseif ($Task -match $t.summarize) { $Kind = 'summarize'; $why += 'summary request' }
    elseif ($Task.Length -lt 220 -and -not $Source) { $Kind = 'qa'; $why += 'short question without input' }
    else { $Kind = 'general' }
}
$kindInfo = if ($route.kinds.ContainsKey($Kind)) { $route.kinds[$Kind] } else { $route.kinds['general'] }

# ---- effort (picks the model) ----
if (-not $Effort) {
    $Effort = $kindInfo.effort
    if ($Task -match 'carefully|thorough|in depth|deep|hard|complex|architecture|design|tricky|subtle|security') { $Effort = 'high'; $why += 'wording says it needs depth: high effort' }
    elseif ($Task -match '\b(quick|simple|just|one word|short|list the|name the)\b' -and $Effort -ne 'high') { $Effort = 'low'; $why += 'wording says it is simple: low effort' }
}

# ---- is a hand-off worth it? ----
$handoff = $true
if ($Kind -eq 'qa' -and $Task.Length -lt 160 -and $kb -lt 5) { $handoff = $false; $why += 'tiny question: a hand-off costs more time than answering it yourself' }
if ($Task -match '(user|owner) (must|has to|will) (approve|decide|choose)|design decision|gameplay choice') { $handoff = $false; $why += 'needs the user''s decision: the boss AI only' }

# ---- split? ----
$chunkKb = [int]$lim.gemini_chunk_kb
if ($Kind -in 'big-read', 'web-research') { $chunkKb = [int]$lim.gemini_app_chunk_kb }
$chunks = if ($kb -gt $chunkKb) { [int][math]::Ceiling($kb / $chunkKb) } else { 1 }

$warning = $null
if ($chunks -gt 8) { $warning = "Source makes $chunks chunks (limit 8 per job, and the Gemini app allows 25 jobs a day). Narrow -Source to the part that matters, or accept the cost on purpose with fanout.ps1 -MaxChunks." }

# ---- the command ----
$srcArg = if ($Source) { ' -Source ' + (($Source | ForEach-Object { '"' + $_ + '"' }) -join ',') } else { '' }
$command = if (-not $handoff) { '(answer it yourself)' }
elseif ($chunks -gt 1) { "pwsh -NoProfile -File `"$hub\bin\fanout.ps1`" -Task `"<question>`"$srcArg -Kind $Kind -Effort $Effort -Out `"$hub\files\<job>\answer.md`"" }
elseif ($Kind -in 'code-edit', 'image') { "pwsh -NoProfile -File `"$hub\bin\ask.ps1`" -Kind $Kind -Effort $Effort -Mode edit -Dir `"<project dir>`" -Out `"$hub\files\<job>\answer.md`" -Task `"<brief>`"" }
elseif ($files.Count -gt 0) { "pwsh -NoProfile -File `"$hub\bin\fanout.ps1`" -Task `"<question>`"$srcArg -Kind $Kind -Effort $Effort -Out `"$hub\files\<job>\answer.md`"   (one chunk, so one request)" }
else { "pwsh -NoProfile -File `"$hub\bin\ask.ps1`" -Kind $Kind -Effort $Effort -Dir `"$hub`" -Out `"$hub\files\<job>\answer.md`" -Task `"<brief>`"" }

[ordered]@{
    handoff    = $handoff
    kind       = $Kind
    effort     = $Effort
    chain      = @($kindInfo.chain)
    inputKb    = $kb
    files      = $files.Count
    skipped    = $script:CollectSkipped
    chunks     = $chunks
    chunkKb    = $chunkKb
    parallel   = ($chunks -gt 1)
    models     = [ordered]@{
        gemini       = @($route.models.gemini[$Effort])
        'gemini-app' = $route.models['gemini-app'][$Effort]
        codex        = $route.models.codex[$Effort]
    }
    warning    = $warning
    why        = $why
    command    = $command
} | ConvertTo-Json -Depth 5
