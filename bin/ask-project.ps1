# Ask a question about a whole project (or a school folder) and get the answer in one file.
#   ask-project.ps1 -Project <folder name under your source roots | full path> -Question "<question>" [-Out <file>] [-Effort low|medium|high]
# The project's readable text (secrets, dependencies and build output left out) is read by fanout.ps1: split into chunks if needed,
# sent as inline material (one request per chunk, never a helper roaming the folder), chunks run on several AIs at once, answers combined.
# Exit codes as fanout.ps1: 0 done | 2 bad arguments | 3 incomplete (resume) | 4 too big (narrow it) | 10 a helper asked a question.
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$Question,
    [string]$Out,
    [ValidateSet('', 'low', 'medium', 'high')][string]$Effort = ''
)
. "$PSScriptRoot\lib\hub.ps1"
. "$PSScriptRoot\lib\collect.ps1"
$dir = Resolve-SourcePath $Project
if (-not $dir) { Write-Output "ERROR: project '$Project' not found (looked in the path itself and in the sourceRoots of config.json)."; exit 2 }
$name = Split-Path $dir -Leaf
if (-not $Out) { $Out = "$($script:Hub)\files\project-answers\$name-$((Get-Date).ToString('yyyyMMdd-HHmm')).md" }

$task = "You are answering a question about the project '$name'. Never print secrets or keys you find. Answer in English, concisely, and name the files you used.`n`nQuestion: $Question"
$cmd = @{ Task = $task; Source = @($dir); Out = $Out; Kind = 'big-read' }
if ($Effort) { $cmd.Effort = $Effort }
& (Join-Path $PSScriptRoot 'fanout.ps1') @cmd
exit $LASTEXITCODE
