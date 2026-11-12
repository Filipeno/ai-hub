# Open an AI as the boss in the current folder.
#   ai           Claude Code
#   ai codex     Codex as fallback boss (use when Claude is out of usage)
#   ai gemini    Gemini CLI as fallback boss
param([string]$Who = 'claude')
. "$PSScriptRoot\lib\hub.ps1"
$hub = $script:Hub

$fallback = "You are the fallback boss because Claude is out of usage. Read $hub\README.md and $hub\HANDOFF.md, check your inbox in $hub\inbox, then tell the user what is in progress and wait for their OK."

switch ($Who.ToLower()) {
    'claude' { claude }
    'codex'  { codex $fallback }
    'gemini' { gemini -i $fallback }
    default  { Write-Host "Usage: ai [claude|codex|gemini]"; exit 1 }
}
