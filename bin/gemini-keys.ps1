# Manage Gemini API keys (stored in ~\.gemini\api-keys.txt, one per line, only your Windows user can read it).
# Keys never go into the hub folder. Run this in your OWN terminal; never paste a key into a chat.
#   gemini-keys add       prompt for a key (hidden input) and append it
#   gemini-keys list      show each key as ...last4 with its cooldown state
#   gemini-keys remove N  remove key number N
#   gemini-keys test      one tiny request per key (uses a little free quota)
#   gemini-keys import    copy the key from user env GEMINI_API_KEY into the file (once)
param([Parameter(Position = 0)][string]$Action = 'list', [Parameter(Position = 1)][string]$Arg)

. "$PSScriptRoot\lib\hub.ps1"
$cfg = Get-HubConfig
$file = $cfg.geminiKeysFile
$cooldownFile = Join-Path $script:Hub 'state\cooldown.json'

function Get-Keys {
    if (-not (Test-Path $file)) { return @() }
    return ,@(Get-Content $file | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })   # leading comma: keep a one-key list an array, not a string
}
function Save-Keys([string[]]$keys) {
    New-Item -ItemType File -Force $file | Out-Null
    Set-Content $file $keys
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $file /inheritance:r /grant:r "${me}:(R,W)" | Out-Null   # only this user
}
function Tail([string]$k) { '...' + $k.Substring($k.Length - 4) }
# Asks the Gemini API for its model list with this key (reads only, no quota use). Returns ok | invalid | limit | unknown.
function Test-Key([string]$k) {
    try {
        Invoke-RestMethod -Uri 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1' -Headers @{ 'x-goog-api-key' = $k } -TimeoutSec 30 | Out-Null
        return 'ok'
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -in 400, 401, 403) { return 'invalid' }
        if ($code -eq 429) { return 'limit' }
        return 'unknown'
    }
}
function Get-Cooldowns { if (Test-Path $cooldownFile) { try { return Get-Content $cooldownFile -Raw | ConvertFrom-Json -AsHashtable } catch {} }; return @{} }

switch ($Action.ToLower()) {
    'add' {
        $sec = Read-Host 'Paste Gemini API key (hidden)' -AsSecureString
        $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
        # Google key formats differ (old: AIza + 35 characters, newer ones are longer), so only check the character set and length.
        if ($key -notmatch '^[A-Za-z0-9_.\-]{30,120}$') { Write-Host "That does not look like an API key (letters, digits, - _ . only; 30-120 characters; yours has $($key.Length)). Nothing saved."; exit 1 }
        $keys = Get-Keys
        if ($keys -contains $key) { Write-Host 'Key already saved.'; exit 0 }
        $check = Test-Key $key
        if ($check -eq 'invalid') {
            Write-Host 'Google rejected this key for the Gemini API. Nothing saved.'
            Write-Host 'Make the key at https://aistudio.google.com/apikey (Create API key). Keys starting with AQ. come from Google Cloud / Vertex and do not work here.'
            exit 1
        }
        if ($check -eq 'unknown') { Write-Host 'Could not reach Google to check the key; saving it anyway. Run gemini-keys test later.' }
        Save-Keys ($keys + $key)
        Write-Host "Saved as key $($keys.Count + 1) ($(Tail $key)). Tip: make each key in a different AI Studio project, since quota is per project."
    }
    'import' {
        $k = [Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')
        if (-not $k) { Write-Host 'No GEMINI_API_KEY in user environment.'; exit 1 }
        $keys = Get-Keys
        if ($keys -contains $k) { Write-Host 'Already in the file.'; exit 0 }
        Save-Keys ($keys + $k)
        Write-Host "Imported ($(Tail $k))."
    }
    'remove' {
        $keys = Get-Keys
        $n = 0
        if (-not [int]::TryParse($Arg, [ref]$n) -or $n -lt 1 -or $n -gt $keys.Count) { Write-Host "Usage: gemini-keys remove <1-$($keys.Count)>"; exit 1 }
        $gone = $keys[$n - 1]
        Save-Keys @($keys | Where-Object { $_ -ne $gone })
        Write-Host "Removed key $n ($(Tail $gone))."
    }
    'models' {
        $keys = @(Get-Keys)
        if ($keys.Count -eq 0) { Write-Host 'No keys saved. Run: gemini-keys add'; exit 1 }
        try {
            $r = Invoke-RestMethod -Uri 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200' -Headers @{ 'x-goog-api-key' = $keys[0] } -TimeoutSec 30
        } catch { Write-Host 'Could not list models (key rejected or no network).'; exit 1 }
        Write-Host "Models your first key can call (gemini-keys models). Put the ones you like into routing.json -> models.gemini:"
        $r.models | Where-Object { $_.supportedGenerationMethods -contains 'generateContent' -and $_.name -match 'gemini' -and $_.name -notmatch 'tts|image|embedding|robotics|computer-use|transcribe|omni' } |
            ForEach-Object { '  ' + $_.name.Replace('models/', '') } | Sort-Object
        Write-Host 'Note: a model can be listed and still have no free quota (Pro models usually have none).'
    }
    'test' {
        $keys = Get-Keys
        $i = 0
        foreach ($k in $keys) {
            $i++
            $r = Test-Key $k
            $msg = switch ($r) { 'ok' { 'works' } 'limit' { 'valid, but over its limit right now' } 'invalid' { 'REJECTED by Google (wrong kind of key? use https://aistudio.google.com/apikey)' } default { 'could not reach Google' } }
            Write-Host ("{0}. {1}  {2}" -f $i, (Tail $k), $msg)
        }
    }
    default {
        $keys = Get-Keys
        $c = Get-Cooldowns
        if ($keys.Count -eq 0) { Write-Host 'No keys saved. Run: gemini-keys add   (or gemini-keys import)'; break }
        $i = 0
        foreach ($k in $keys) {
            $i++
            $id = 'gemini#' + $k.Substring($k.Length - 4)
            $state = 'ready'
            if ($c.ContainsKey($id) -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [int64]$c[$id]) {
                $state = 'cooldown until ' + [DateTimeOffset]::FromUnixTimeSeconds([int64]$c[$id]).LocalDateTime.ToString('HH:mm')
            }
            Write-Host ("{0}. {1}  {2}" -f $i, (Tail $k), $state)
        }
    }
}
