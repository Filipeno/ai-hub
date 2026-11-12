# Manage the Perplexity API key (stored in ~\.perplexity\api-key.txt, only your Windows user can read it; never inside the hub).
# Run this in your OWN terminal; never paste a key into a chat. Create a key at https://console.perplexity.ai/project/keys
# (the API is pay as you go: a typical question costs a few cents; set a spending limit in the console).
#   perplexity-key add       prompt for the key (hidden input), save it, then test it
#   perplexity-key test      one tiny request (a fraction of a cent) to check the key and your credit
#   perplexity-key remove    delete the saved key
#   perplexity-key status    is a key saved, and how many Perplexity jobs ran today (the daily cap protects your bill)
param([Parameter(Position = 0)][string]$Action = 'status')
. "$PSScriptRoot\lib\hub.ps1"
$cfg = Get-HubConfig
$file = $cfg.perplexityKeyFile
$base = if ($cfg.perplexityBaseUrl) { $cfg.perplexityBaseUrl } else { 'https://api.perplexity.ai' }

function Get-Key {
    if (Test-Path $file) { $k = (Get-Content $file -Raw).Trim(); if ($k) { return $k } }
    return [Environment]::GetEnvironmentVariable('PERPLEXITY_API_KEY', 'User')
}
function Test-Key([string]$key) {
    try {
        $body = @{ effort = 'low'; input = 'Reply with exactly: ok' } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$base/v1/agent" -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body -TimeoutSec 90 | Out-Null
        return 'ok'
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $msg = "$($_.ErrorDetails.Message)"
        if ($status -in 401, 403) { return 'rejected' }
        if ($status -eq 402 -or $msg -match 'credit|billing|insufficient|payment') { return 'nocredit' }
        if ($status -eq 429) { return 'ratelimit' }
        return "error (HTTP $status)"
    }
}
function Show-Test([string]$r) {
    switch -Wildcard ($r) {
        'ok'        { Write-Host 'The key works.' -ForegroundColor Green }
        'rejected'  { Write-Host 'Perplexity rejected this key. Create a new one at https://console.perplexity.ai/project/keys' -ForegroundColor Yellow }
        'nocredit'  { Write-Host 'The key is valid but the account has no credit. Add credit in the Perplexity console.' -ForegroundColor Yellow }
        'ratelimit' { Write-Host 'The key is valid but rate limited right now; try again in a minute.' -ForegroundColor Yellow }
        default     { Write-Host "Could not check the key: $r" -ForegroundColor Yellow }
    }
}

switch ($Action.ToLower()) {
    'add' {
        $sec = Read-Host 'Paste Perplexity API key (hidden)' -AsSecureString
        $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
        if ($key -notmatch '^[A-Za-z0-9_\-]{20,200}$') { Write-Host "That does not look like an API key (letters, digits, - _ ; 20-200 characters; yours has $($key.Length)). Nothing saved."; exit 1 }
        New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
        Set-Content $file $key -NoNewline
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        icacls $file /inheritance:r /grant:r "${me}:(R,W)" | Out-Null   # only this user
        Write-Host "Saved (...$($key.Substring($key.Length - 4)))."
        Show-Test (Test-Key $key)
    }
    'test' {
        $key = Get-Key
        if (-not $key) { Write-Host 'No key saved. Run: perplexity-key add'; exit 1 }
        Show-Test (Test-Key $key)
    }
    'remove' {
        if (Test-Path $file) { Remove-Item $file -Force; Write-Host 'Key removed.' } else { Write-Host 'No key file to remove.' }
    }
    default {
        $key = Get-Key
        if ($key) { Write-Host "A Perplexity key is saved (...$($key.Substring($key.Length - 4)))." } else { Write-Host 'No Perplexity key saved. Run: perplexity-key add' }
        $countFile = Join-Path $script:Hub 'state\perplexity-count.json'
        $route = Get-Content (Join-Path $script:Hub 'routing.json') -Raw | ConvertFrom-Json
        $n = 0
        if (Test-Path $countFile) { try { $c = Get-Content $countFile -Raw | ConvertFrom-Json; if ($c.date -eq (Get-Date).ToString('yyyy-MM-dd')) { $n = [int]$c.count } } catch {} }
        Write-Host "Perplexity jobs today: $n of $($route.limits.perplexity_daily_cap) (daily cap, set in routing.json)"
    }
}
