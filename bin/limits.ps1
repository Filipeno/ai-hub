# Show which helper AIs are parked (out of quota, busy or logged out) and until when, plus the last jobs. Costs no model usage.
#   limits.ps1            parked helpers and the last 8 jobs
#   limits.ps1 -Clear     forget all parking (use after you fixed a login or bought more quota)
param([switch]$Clear)
. "$PSScriptRoot\lib\hub.ps1"
$cfg = Get-HubConfig
$cooldownFile = Join-Path $script:Hub 'state\cooldown.json'
$logFile = Join-Path $script:Hub 'state\ask.log'
$countFile = Join-Path $script:Hub 'state\gemini-app-count.json'

if ($Clear) { if (Test-Path $cooldownFile) { Remove-Item $cooldownFile }; Write-Host 'All parking cleared.'; return }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$c = @{}
if (Test-Path $cooldownFile) { try { $c = Get-Content $cooldownFile -Raw | ConvertFrom-Json -AsHashtable } catch {} }

Write-Host "Connected AIs: $((@($cfg.enabled)) -join ', ')"
$parked = @($c.GetEnumerator() | Where-Object { [int64]$_.Value -gt $now } | Sort-Object Key)
if ($parked.Count -eq 0) { Write-Host 'Parked: nothing, every helper is ready.' }
else {
    Write-Host 'Parked (skipped until the time shown):'
    foreach ($p in $parked) {
        $name = if ($p.Key -match '^gemini#(.{4})@(.+)$') { "gemini key ...$($Matches[1]) on $($Matches[2])" } elseif ($p.Key -match '^gemini@(.+)$') { "gemini model $($Matches[1])" } else { $p.Key }
        $until = [DateTimeOffset]::FromUnixTimeSeconds([int64]$p.Value).LocalDateTime
        $when = if ($until.Date -eq (Get-Date).Date) { $until.ToString('HH:mm') } else { $until.ToString('ddd HH:mm') }
        Write-Host ("  {0,-50} until {1}" -f $name, $when)
    }
}
if (Test-Path $countFile) {
    try { $n = Get-Content $countFile -Raw | ConvertFrom-Json; if ($n.date -eq (Get-Date).ToString('yyyy-MM-dd')) { Write-Host "Gemini app jobs today: $($n.count)" } } catch {}
}
$pplxFile = Join-Path $script:Hub 'state\perplexity-count.json'
if (Test-Path $pplxFile) {
    try { $n = Get-Content $pplxFile -Raw | ConvertFrom-Json; if ($n.date -eq (Get-Date).ToString('yyyy-MM-dd')) { Write-Host "Perplexity jobs today: $($n.count) (each costs a few cents; daily cap in routing.json)" } } catch {}
}
if (Test-Path $logFile) { Write-Host ''; Write-Host 'Last jobs:'; Get-Content $logFile -Tail 8 | ForEach-Object { "  $_" } }
