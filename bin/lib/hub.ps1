# Shared by every script in bin\. Dot-source it first:   . "$PSScriptRoot\lib\hub.ps1"
# Sets $script:Hub (the hub folder = the parent of bin\) and gives Get-HubConfig, which reads <hub>\config.json
# (written by install.ps1) and fills in defaults, so the scripts also work before the installer ran.
$script:Hub = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:UserHome = [Environment]::GetFolderPath('UserProfile')

function Get-HubConfig {
    $cfg = @{
        enabled        = @('claude', 'gemini', 'gemini-app', 'codex', 'agy')   # which AIs the user chose to connect
        geminiKeysFile = Join-Path $script:UserHome '.gemini\api-keys.txt'     # one Gemini API key per line, never inside the hub
        robotProfile   = Join-Path $script:UserHome '.gemini-app-profile'      # the Gemini-app robot's own Chrome profile
        sourceRoots    = @()                                                   # folders where project names are looked up (ask-project, fanout -Source <name>)
    }
    $file = Join-Path $script:Hub 'config.json'
    if (Test-Path $file) {
        try {
            $saved = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
            foreach ($k in $saved.Keys) { $cfg[$k] = $saved[$k] }
        } catch { Write-Warning "config.json is not valid JSON; using defaults." }
    }
    return $cfg
}

function Test-HelperEnabled([string]$name, $cfg = $null) {
    if (-not $cfg) { $cfg = Get-HubConfig }
    return (@($cfg.enabled) -contains $name)
}
