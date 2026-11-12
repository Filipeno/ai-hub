# Ask the same question to several AIs at the same time and keep each answer separately, for a real second opinion.
#   council.ps1 -Task "<question>" -Out <folder> [-Source <file|folder|name> ...] [-Effort high] [-Lanes gemini-app,gemini,codex]
# Each lane answers on its own (no fallback, so a lane that is out of quota is reported, not replaced by a copy of another).
# Output: <folder>\<lane>.md per AI and <folder>\council.md with all answers side by side. Claude reads them, compares and decides;
# the council never decides anything itself. Source material goes to every lane as one inline input file (max 300 KB).
# Exit codes: 0 at least two lanes answered | 3 fewer than two lanes answered
param(
    [Parameter(Mandatory)][string]$Task,
    [Parameter(Mandatory)][string]$Out,
    [string[]]$Source,
    [ValidateSet('low', 'medium', 'high')][string]$Effort = 'high',
    [string[]]$Lanes = @('gemini-app', 'gemini', 'codex')
)
$Lanes = @($Lanes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # -Lanes a,b arrives as one string under pwsh -File
. "$PSScriptRoot\lib\hub.ps1"
. "$PSScriptRoot\lib\collect.ps1"
$ask = Join-Path $PSScriptRoot 'ask.ps1'
New-Item -ItemType Directory -Force $Out | Out-Null

$mat = $null
if ($Source) {
    $files = @(Get-SourceFiles $Source)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($f in $files) { [void]$sb.Append("`n===== FILE: $($f.Rel) =====`n" + (Get-Content $f.Path -Raw)) }
    if ($sb.Length -gt 300KB) { Write-Output "ERROR: source is $([int]($sb.Length / 1KB)) KB; the council takes at most 300 KB. Narrow -Source or use fanout.ps1."; exit 2 }
    $mat = Join-Path $Out 'material.txt'
    Set-Content $mat $sb.ToString() -Encoding UTF8
}

$brief = "$Task`n`nGive your own best answer. Say what you are unsure about. Do not hedge for the sake of it."
$results = $Lanes | ForEach-Object -ThrottleLimit $Lanes.Count -Parallel {
    $lane = $_
    $h = @{ Helper = $lane; NoFallback = $true; Kind = 'second-opinion'; Effort = $using:Effort; Dir = $using:Out; Out = "$using:Out\$lane.md"; Task = $using:brief; NoDisk = $true }
    if ($using:mat) { $h.InputFile = $using:mat }
    $o = & $using:ask @h 2>&1 | Out-String
    [pscustomobject]@{ lane = $lane; code = $LASTEXITCODE; text = ($o.Trim() -split "`n" | Select-Object -Last 1) }
}
$ok = @($results | Where-Object { $_.code -eq 0 })
$md = @("# Council: $Task`n", "Effort: $Effort. Lanes asked: $($Lanes -join ', ').`n")
foreach ($r in $results) {
    if ($r.code -eq 0) { $md += "## $($r.lane)`n" + (Get-Content "$Out\$($r.lane).md" -Raw) }
    else { $md += "## $($r.lane)`n(no answer: $($r.text))`n" }
    Write-Output ("  {0,-11} {1}" -f $r.lane, $r.text)
}
Set-Content "$Out\council.md" ($md -join "`n") -Encoding UTF8
if ($ok.Count -lt 2) { Write-Output "Only $($ok.Count) lane(s) answered; a council needs at least two. See $Out\council.md."; exit 3 }
Write-Output "OK out=$Out\council.md ($($ok.Count) of $($Lanes.Count) lanes answered)"
exit 0
