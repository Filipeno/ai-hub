# List the chats Claude started with Codex (`codex exec` jobs). The Codex app does not show them.
# Read-only: it only reads ~\.codex\sessions.
#   codex-chats                 jobs of the last 48 hours: time, id, folder, task, answer
#   codex-chats -Hours 200      look further back
#   codex-chats -Id 01a15bd1-bc32   show one job in full (the id from the list, or any part of it)
#   codex-chats -All            also list chats started in the Codex app
param([int]$Hours = 48, [string]$Id, [switch]$All)

$root = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\sessions'
if (-not (Test-Path $root)) { Write-Output "No Codex sessions folder at $root."; exit 1 }

function Short([string]$s, [int]$n) {
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + '…' } else { $s }
}

# Reads one session file; scans raw lines first so large files stay fast.
function Read-Session([System.IO.FileInfo]$f) {
    $meta = $null; $task = $null; $answer = $null; $done = $false; $tokens = $null
    # Open with sharing so a session the Codex app still has open can be read.
    try { $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete') } catch { return $null }
    $sr = [System.IO.StreamReader]::new($fs)
    while ($null -ne ($line = $sr.ReadLine())) {
        if (-not $meta) {
            try { $meta = ($line | ConvertFrom-Json).payload } catch { return $null }
            continue
        }
        if ($line.Contains('"role":"user"') -and $line.Contains('"type":"message"')) {
            try {
                $text = (($line | ConvertFrom-Json).payload.content | ForEach-Object { $_.text }) -join "`n"
                # Skip the app's own preamble messages (instructions, environment, skills); keep the last real prompt.
                if ($text -and $text -notmatch '^\s*(<skill>|<environment_context|<permissions|<INSTRUCTIONS|# AGENTS\.md instructions)') {
                    $task = ($text -replace '</?image[^>]*>', '').Trim()
                }
            } catch {}
        } elseif ($line.Contains('"type":"task_complete"')) {
            try { $answer = ($line | ConvertFrom-Json).payload.last_agent_message; $done = $true } catch {}
        } elseif ($line.Contains('"total_token_usage"')) {
            try { $tokens = ($line | ConvertFrom-Json).payload.info.total_token_usage.total_tokens } catch {}
        }
    }
    $sr.Dispose()
    [pscustomobject]@{
        File = $f.FullName; Time = $f.LastWriteTime; Id = $meta.id; Cwd = $meta.cwd; Origin = $meta.originator
        Task = $task; Answer = $answer; Done = $done; Tokens = $tokens
    }
}

$files = Get-ChildItem $root -Recurse -File -Filter *.jsonl | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) } | Sort-Object LastWriteTime

if ($Id) {
    $f = $files | Where-Object { $_.Name -like "*$Id*" } | Select-Object -First 1
    if (-not $f) { $f = Get-ChildItem $root -Recurse -File -Filter "*$Id*.jsonl" | Select-Object -First 1 }
    if (-not $f) { Write-Output "No session matching '$Id'."; exit 1 }
    $s = Read-Session $f
    "Session  $($s.Id)"
    "Time     $($s.Time.ToString('yyyy-MM-dd HH:mm'))   Folder $($s.Cwd)   Started by $($s.Origin)"
    "Status   $(if ($s.Done) { 'finished' } else { 'no final answer recorded' })   Tokens $($s.Tokens)"
    "File     $($s.File)"
    ""
    "--- TASK ---"
    $s.Task
    ""
    "--- ANSWER ---"
    $s.Answer
    return
}

$rows = foreach ($f in $files) {
    $s = Read-Session $f
    if (-not $s) { continue }
    if (-not $All -and $s.Origin -ne 'codex_exec') { continue }
    $s
}
if (-not $rows) { Write-Output "No Codex jobs from Claude in the last $Hours hours (use -Hours or -All)."; return }
"{0,-11} {1,-13} {2,-22} {3,-46} {4}" -f 'Time', 'Id', 'Folder', 'Task', 'Answer'
foreach ($r in $rows) {
    "{0,-11} {1,-13} {2,-22} {3,-46} {4}" -f $r.Time.ToString('dd.MM HH:mm'), $r.Id.Substring(0, 13), (Short (Split-Path $r.Cwd -Leaf) 22), (Short $r.Task 46), $(if ($r.Done) { Short $r.Answer 60 } else { '(no final answer)' })
}
""
"$($rows.Count) job(s). Full text: codex-chats -Id <id>"
