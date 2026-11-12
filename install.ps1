<#
.SYNOPSIS
  AI Hub installer. Connects the AIs you choose (Claude Code, Gemini CLI, Gemini web app, Codex, Antigravity) into one team.
.DESCRIPTION
  Run it from the folder you cloned:   pwsh -File .\install.ps1
  The FIRST thing it asks is which AIs you want to connect. It only touches what you choose, asks before every change to your
  own files, backs up what it edits, and can be undone with uninstall.ps1.
.PARAMETER AIs
  Skip the question: claude, gemini, gemini-app, codex, agy (comma separated).
.PARAMETER Yes
  Answer "yes" to every confirmation (not to the Gemini-app risk notice: that needs -AcceptRobotRisk).
.PARAMETER AcceptRobotRisk
  Confirms you read the Gemini-app risk notice (needed with -Yes when gemini-app is chosen).
.PARAMETER HomeDir
  Use another folder instead of your user profile for ~\.claude, ~\.gemini, ~\.codex (for testing).
.PARAMETER NoPath
  Do not add <hub>\bin to your user PATH.
.PARAMETER SkipTests
  Do not run the small test job for each connected AI at the end.
#>
param(
    [string[]]$AIs,
    [switch]$Yes,
    [switch]$AcceptRobotRisk,
    [string]$HomeDir,
    [switch]$NoPath,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows) {
    Write-Host 'This installer needs PowerShell 7 on Windows. Get it with:  winget install Microsoft.PowerShell   then run:  pwsh -File .\install.ps1' -ForegroundColor Yellow
    exit 1
}

$Hub = $PSScriptRoot
$UserHome = if ($HomeDir) { (New-Item -ItemType Directory -Force $HomeDir).FullName } else { [Environment]::GetFolderPath('UserProfile') }
$Marker = @{ Begin = '<!-- ai-hub:begin -->'; End = '<!-- ai-hub:end -->' }

# ---------- small helpers ----------
function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Confirm-Step([string]$question, [bool]$default = $true) {
    if ($Yes) { return $true }
    $hint = if ($default) { 'Y/n' } else { 'y/N' }
    $a = Read-Host "$question [$hint]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim().ToLower().StartsWith('y')
}
function Test-Command([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Test-Agy { return (Test-Path (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe')) }
function Find-Chrome {
    foreach ($p in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) { if (Test-Path $p) { return $p } }
    return $null
}
function Expand-Template([string]$text, [string[]]$enabled) {
    return $text.Replace('{{HUB}}', $Hub).Replace('{{ENABLED}}', ($enabled -join ', '))
}
# Writes a block between markers into a file the user owns: replaces our old block, never touches the rest. Backs up once.
function Set-ManagedBlock([string]$file, [string]$text) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $block = "$($Marker.Begin)`r`n$($text.TrimEnd())`r`n$($Marker.End)"
    if (Test-Path $file) {
        $old = Get-Content $file -Raw
        if (-not (Test-Path "$file.bak-aihub")) { Copy-Item $file "$file.bak-aihub" }
        $rx = [regex]::Escape($Marker.Begin) + '[\s\S]*?' + [regex]::Escape($Marker.End)
        if ($old -match $rx) { $new = [regex]::Replace($old, $rx, { param($m) $block }) } else { $new = $old.TrimEnd() + "`r`n`r`n" + $block + "`r`n" }
    } else { $new = $block + "`r`n" }
    Set-Content $file $new -NoNewline -Encoding UTF8
}

# ---------- welcome ----------
Say '  AI Hub: one team out of the AIs you already pay for' 'Cyan'
Say "  Hub folder: $Hub"
Say '  Nothing is changed until you answer. You can stop with Ctrl+C at any question.'

# ---------- 1. which AIs? (the first question) ----------
$catalog = [ordered]@{
    'claude'     = @{ n = 'Claude Code';  d = 'the boss: plans, decides, hands bulk work to the others (needs Claude Code installed)' }
    'gemini'     = @{ n = 'Gemini CLI';   d = 'free Gemini API keys: fast, cheap helper for summaries, extraction, small questions' }
    'gemini-app' = @{ n = 'Gemini web app (browser robot)'; d = 'uses your Google AI plan: live Google Search, huge files, strongest Gemini models  [automation, read the risk notice]' }
    'codex'      = @{ n = 'Codex';        d = 'ChatGPT login: the only helper that edits files; code edits, tests, images' }
    'agy'        = @{ n = 'Antigravity CLI (agy)'; d = 'Google login: small weekly quota, last-resort helper' }
}
$keys = @($catalog.Keys)

Step 'Which AIs do you want to connect?'
if (-not $AIs) {
    $i = 1
    foreach ($k in $keys) {
        $found = switch ($k) { 'claude' { Test-Command 'claude' } 'gemini' { Test-Command 'gemini' } 'codex' { Test-Command 'codex' } 'agy' { Test-Agy } 'gemini-app' { [bool](Find-Chrome) } }
        $tag = if ($found) { '(found on this PC)' } else { '(not installed yet; I can install it)' }
        if ($k -eq 'gemini-app') { $tag = if (Find-Chrome) { '(Chrome found)' } else { '(needs Chrome or Edge)' } }
        if ($k -eq 'claude' -and -not $found) { $tag = '(not installed; get it from https://claude.com/claude-code)' }
        Write-Host ('  {0}. {1,-34} {2}' -f $i, $catalog[$k].n, $tag) -ForegroundColor White
        Write-Host ('     {0}' -f $catalog[$k].d) -ForegroundColor DarkGray
        $i++
    }
    Write-Host ''
    Say 'Type the numbers you want, separated by commas (for example 1,2,4), or "all". At least two make a team.'
    do {
        $answer = Read-Host 'Your choice'
        $picked = @()
        if ($answer.Trim().ToLower() -eq 'all') { $picked = $keys }
        else { foreach ($n in ($answer -split '[,\s]+' | Where-Object { $_ })) { if ($n -match '^[1-5]$') { $picked += $keys[[int]$n - 1] } } }
        $picked = @($picked | Select-Object -Unique)
        if ($picked.Count -eq 0) { Say 'Please type at least one number from 1 to 5.' 'Yellow' }
    } while ($picked.Count -eq 0)
    $AIs = $picked
}
$AIs = @($AIs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $keys -contains $_ } | Select-Object -Unique)
if ($AIs.Count -eq 0) { Say 'No valid AI chosen. Valid names: claude, gemini, gemini-app, codex, agy.' 'Red'; exit 1 }
Say ("Connecting: " + (($AIs | ForEach-Object { $catalog[$_].n }) -join ', ')) 'Green'
if ($AIs.Count -eq 1) { Say 'Note: with one AI there is nobody to hand work to. You can run this installer again to add more.' 'Yellow' }

$needNode = ($AIs | Where-Object { $_ -in 'gemini', 'gemini-app', 'codex' }).Count -gt 0
if ($needNode -and -not (Test-Command 'node')) {
    Say 'Node.js is needed for the Gemini and Codex tools. Install it with:  winget install OpenJS.NodeJS.LTS   then run this installer again.' 'Yellow'
    if (-not (Confirm-Step 'Continue anyway (those AIs will be skipped)?' $false)) { exit 1 }
    $AIs = @($AIs | Where-Object { $_ -notin 'gemini', 'gemini-app', 'codex' })
}

$connected = [System.Collections.Generic.List[string]]::new()
$notes = [System.Collections.Generic.List[string]]::new()

# ---------- 2. set up each chosen AI ----------
foreach ($ai in $AIs) {
    Step "Setting up: $($catalog[$ai].n)"
    switch ($ai) {
        'claude' {
            if (-not (Test-Command 'claude')) { Say 'Claude Code is not installed. Get it from https://claude.com/claude-code, then run this installer again to finish this part.' 'Yellow'; $notes.Add('Install Claude Code, then re-run install.ps1 to add its instructions.'); break }
            if (Confirm-Step "Add the AI-team instructions to $UserHome\.claude\CLAUDE.md and the 'delegate' skill to $UserHome\.claude\skills? (your existing text stays; a backup is kept)") {
                $block = Expand-Template (Get-Content (Join-Path $Hub 'templates\claude-block.md') -Raw) $AIs
                Set-ManagedBlock (Join-Path $UserHome '.claude\CLAUDE.md') $block
                $skillDir = Join-Path $UserHome '.claude\skills\delegate'
                New-Item -ItemType Directory -Force $skillDir | Out-Null
                Set-Content (Join-Path $skillDir 'SKILL.md') (Expand-Template (Get-Content (Join-Path $Hub 'templates\skills\delegate\SKILL.md') -Raw) $AIs) -NoNewline -Encoding UTF8
                Say 'Done: Claude will hand work off on its own when that is better.' 'Green'
                $connected.Add('claude')
            }
        }
        'gemini' {
            if (-not (Test-Command 'gemini')) {
                if (Confirm-Step 'Gemini CLI is not installed. Install it now with: npm install -g @google/gemini-cli ?') { npm install -g '@google/gemini-cli' 2>&1 | Select-Object -Last 2 | ForEach-Object { Say "  $_" } }
            }
            if (-not (Test-Command 'gemini')) { Say 'Gemini CLI still not found; skipping it.' 'Yellow'; $notes.Add('Install the Gemini CLI (npm install -g @google/gemini-cli), then re-run install.ps1.'); break }
            Say 'The Gemini CLI uses free API keys (Google login is no longer accepted for it on personal accounts).'
            Say 'Get a key at https://aistudio.google.com/apikey (Create API key). Several keys from different projects multiply your free quota.'
            $keysFile = Join-Path $UserHome '.gemini\api-keys.txt'
            if (-not (Test-Path $keysFile) -and (Confirm-Step 'Add your first API key now? (hidden input; it is stored only in your user profile, never in the hub)')) {
                if ($Yes) { Say 'Skipped: keys need hidden typing. Run later:  gemini-keys add' 'Yellow' }
                else { & (Join-Path $Hub 'bin\gemini-keys.ps1') add }
            }
            if (Confirm-Step "Set the Gemini CLI to use API keys (edits $UserHome\.gemini\settings.json, backup kept) and add the team instructions to $UserHome\.gemini\GEMINI.md?") {
                $settings = Join-Path $UserHome '.gemini\settings.json'
                New-Item -ItemType Directory -Force (Split-Path $settings) | Out-Null
                $obj = @{}
                if (Test-Path $settings) { Copy-Item $settings "$settings.bak-aihub" -Force; try { $obj = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable } catch { $obj = @{} } }
                if (-not $obj) { $obj = @{} }
                if (-not $obj.ContainsKey('security')) { $obj['security'] = @{} }
                if (-not $obj['security'].ContainsKey('auth')) { $obj['security']['auth'] = @{} }
                $obj['security']['auth']['selectedType'] = 'gemini-api-key'
                $obj | ConvertTo-Json -Depth 10 | Set-Content $settings -Encoding UTF8
                Set-ManagedBlock (Join-Path $UserHome '.gemini\GEMINI.md') (Expand-Template (Get-Content (Join-Path $Hub 'templates\helper-block.md') -Raw) $AIs)
                Say 'Done.' 'Green'
                $connected.Add('gemini')
            }
            if (-not (Test-Path $keysFile)) { $notes.Add('Add a Gemini API key:  gemini-keys add   (then: gemini-keys test)') }
        }
        'gemini-app' {
            Say 'RISK NOTICE - please read:' 'Yellow'
            Say '  This tool drives gemini.google.com with a hidden, automated Chrome that is signed in to YOUR Google account.'
            Say '  Google may treat automated use of the consumer Gemini app as a terms-of-service violation. Reports exist of'
            Say '  accounts being limited or suspended for automation; there is no fixed length for a suspension and no guarantee of'
            Say '  an answer to an appeal. Use a Google account you can afford to lose access to (a separate account on a shared plan is'
            Say '  safer than your main one). The tool caps itself at 25 jobs a day and never accepts pop-ups or permissions.'
            if ($Yes) { $ok = [bool]$AcceptRobotRisk } else { $ok = ((Read-Host 'Type  I understand  to continue, or press Enter to skip the Gemini app') -eq 'I understand') }
            if (-not $ok) { Say 'Skipping the Gemini app.' 'Yellow'; break }
            if (-not (Find-Chrome)) { Say 'Chrome or Edge not found; install Chrome and run this installer again.' 'Yellow'; $notes.Add('Install Chrome, then re-run install.ps1 for the Gemini app.'); break }
            Say 'Installing the robot''s one dependency (playwright-core, from npm; it does not download a browser)...'
            Push-Location (Join-Path $Hub 'gemini-app')
            try { npm install --no-audit --no-fund 2>&1 | Select-Object -Last 1 | ForEach-Object { Say "  $_" } } finally { Pop-Location }
            if (Confirm-Step 'Open the sign-in window now? You sign in to Google in it, send one test message, then CLOSE it.') {
                & node (Join-Path $Hub 'gemini-app\login.mjs')
                if (-not $Yes) { Read-Host 'Press Enter here after you signed in and closed that Chrome window' | Out-Null }
            } else { $notes.Add('Sign the Gemini robot in:  gemini-app login') }
            $connected.Add('gemini-app')
        }
        'codex' {
            if (-not (Test-Command 'codex')) {
                if (Confirm-Step 'Codex is not installed. Install it now with: npm install -g @openai/codex ?') { npm install -g '@openai/codex' 2>&1 | Select-Object -Last 2 | ForEach-Object { Say "  $_" } }
            }
            if (-not (Test-Command 'codex')) { Say 'Codex still not found; skipping it.' 'Yellow'; $notes.Add('Install Codex (npm install -g @openai/codex), then re-run install.ps1.'); break }
            $status = (& codex login status 2>&1 | Out-String).Trim()
            if ($status -notmatch 'Logged in') {
                Say 'Codex is not logged in.' 'Yellow'
                if (Confirm-Step 'Run "codex login" now (opens your browser)?') { & codex login } else { $notes.Add('Log Codex in:  codex login') }
            } else { Say "Codex: $status" 'Green' }
            if (Confirm-Step "Add the team instructions to $UserHome\.codex\AGENTS.md?") {
                Set-ManagedBlock (Join-Path $UserHome '.codex\AGENTS.md') (Expand-Template (Get-Content (Join-Path $Hub 'templates\helper-block.md') -Raw) $AIs)
                $connected.Add('codex')
            }
        }
        'agy' {
            if (-not (Test-Agy)) {
                Say 'The Antigravity CLI installer comes from Google: https://antigravity.google/cli/install.ps1 (it downloads a signed-by-hash binary, installs it in %LOCALAPPDATA%\agy\bin and adds that to your PATH).'
                if (Confirm-Step 'Download and run it now?' $false) {
                    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'agy-install.ps1'
                    Invoke-WebRequest 'https://antigravity.google/cli/install.ps1' -OutFile $tmp -UseBasicParsing
                    & pwsh -NoProfile -File $tmp 2>&1 | Select-Object -Last 4 | ForEach-Object { Say "  $_" }
                    Remove-Item $tmp -ErrorAction SilentlyContinue
                }
            }
            if (Test-Agy) { Say 'agy is installed. If it asks you to sign in, run:  agy   once and follow the browser prompt.' 'Green'; $connected.Add('agy') }
            else { Say 'agy not installed; skipping it.' 'Yellow' }
        }
    }
}

# ---------- 3. hub files and config ----------
Step 'Writing the hub files'
$sourceRoots = @()
if (-not $Yes) {
    $roots = Read-Host 'Folders where your projects live, so you can say "project foo" instead of a full path (comma separated, Enter to skip)'
    $sourceRoots = @($roots -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -and (Test-Path $_) })
}
$cfgFile = Join-Path $Hub 'config.json'
$config = [ordered]@{
    enabled        = @($connected)
    geminiKeysFile = Join-Path $UserHome '.gemini\api-keys.txt'
    robotProfile   = Join-Path $UserHome '.gemini-app-profile'
    sourceRoots    = @($sourceRoots)
}
$config | ConvertTo-Json | Set-Content $cfgFile -Encoding UTF8
foreach ($d in 'inbox\claude\done', 'inbox\gemini\done', 'inbox\codex\done', 'files', 'state\questions') { New-Item -ItemType Directory -Force (Join-Path $Hub $d) | Out-Null }
Set-Content (Join-Path $Hub 'HUB.md') (Expand-Template (Get-Content (Join-Path $Hub 'templates\HUB.md') -Raw) @($connected)) -Encoding UTF8
foreach ($f in 'HANDOFF.md', 'MEMORY.md') { $dest = Join-Path $Hub $f; if (-not (Test-Path $dest)) { Set-Content $dest (Expand-Template (Get-Content (Join-Path $Hub "templates\$f") -Raw) @($connected)) -Encoding UTF8 } }
Say "config.json written (connected: $($connected -join ', '))." 'Green'

# ---------- 4. PATH ----------
if (-not $NoPath) {
    $bin = Join-Path $Hub 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $bin) {
        if (Confirm-Step "Add $bin to your user PATH so you can type 'limits', 'gemini-keys', 'codex-chats', 'ai' anywhere?") {
            [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
            Say 'Added. Open a new terminal for it to take effect.' 'Green'
        }
    }
}

# ---------- 5. self-test ----------
$tests = @($connected | Where-Object { $_ -in 'gemini', 'gemini-app', 'codex' })
if (-not $SkipTests -and $tests.Count -gt 0 -and (Confirm-Step "Run one tiny test job on each connected helper ($($tests -join ', '))? It uses a few free requests.")) {
    Step 'Testing'
    foreach ($t in $tests) {
        $out = Join-Path $Hub "files\install-test-$t.md"
        $r = & pwsh -NoProfile -File (Join-Path $Hub 'bin\ask.ps1') -Helper $t -NoFallback -Kind qa -Effort low -NoDisk -Dir $Hub -Out $out -Task 'Reply with exactly: ok' 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE -eq 0) { Say "  $t : works ($r)" 'Green' } else { Say "  $t : did not answer ($r). Details: $Hub\state\ask.log" 'Yellow' }
        Remove-Item $out -ErrorAction SilentlyContinue
    }
}

# ---------- summary ----------
Step 'Finished'
Say "Connected: $($connected -join ', ')" 'Green'
foreach ($n in $notes) { Say "  TODO: $n" 'Yellow' }
Say ''
Say 'Next:'
Say '  1. Open Claude Code in any folder and give it a big job (for example "summarize this repo"); it hands off by itself when that is better.'
Say "  2. See which AI would take a job:   pwsh -File `"$Hub\bin\route.ps1`" -Task `"find the latest Node LTS version`""
Say '  3. See what is parked or out of quota:   limits   (new terminal)'
Say "  Undo everything this installer wrote outside the hub:   pwsh -File `"$Hub\uninstall.ps1`""
