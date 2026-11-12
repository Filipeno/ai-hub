<#
.SYNOPSIS
  Removes what install.ps1 added outside the hub folder. The hub folder itself, your API keys and your Gemini-app login are left alone.
.PARAMETER Yes
  Do not ask.
.PARAMETER HomeDir
  Same test override as install.ps1.
#>
param([switch]$Yes, [string]$HomeDir)
$Hub = $PSScriptRoot
$UserHome = if ($HomeDir) { $HomeDir } else { [Environment]::GetFolderPath('UserProfile') }
$begin = [regex]::Escape('<!-- ai-hub:begin -->'); $end = [regex]::Escape('<!-- ai-hub:end -->')

function Confirm-Step([string]$q) { if ($Yes) { return $true }; return ((Read-Host "$q [Y/n]") -notmatch '^n') }

foreach ($f in '.claude\CLAUDE.md', '.gemini\GEMINI.md', '.codex\AGENTS.md') {
    $path = Join-Path $UserHome $f
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content $path -Raw
    if ($text -match "$begin[\s\S]*?$end" -and (Confirm-Step "Remove the AI Hub block from $path?")) {
        $new = [regex]::Replace($text, "\r?\n*$begin[\s\S]*?$end\r?\n*", "`r`n").Trim()
        if ($new) { Set-Content $path ($new + "`r`n") -NoNewline -Encoding UTF8 } else { Remove-Item $path }
        Write-Host "  cleaned $path"
    }
}
$skill = Join-Path $UserHome '.claude\skills\delegate'
if ((Test-Path $skill) -and (Confirm-Step "Remove the 'delegate' skill ($skill)?")) { Remove-Item $skill -Recurse -Force; Write-Host '  removed the delegate skill' }

$bin = Join-Path $Hub 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -and (($userPath -split ';') -contains $bin) -and (Confirm-Step "Remove $bin from your user PATH?")) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin }) -join ';'), 'User')
    Write-Host '  removed from PATH'
}
Write-Host 'Done. Backups of files the installer edited are next to them as *.bak-aihub. Your Gemini keys (~\.gemini\api-keys.txt) and robot login (~\.gemini-app-profile) were not touched; delete them by hand if you want.'
