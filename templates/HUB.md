# AI Hub ({{HUB}})

A shared space for the AIs you connected. Every AI reads this file before using the hub.
Connected AIs (also in `config.json`): {{ENABLED}}.

## Roles
- **The boss is Claude Code** (or whichever AI the user is talking to). It plans, decides with the user, hands bulk work to the helpers and checks their results.
- **Helpers** (Perplexity, Gemini app, Gemini CLI, Codex, Antigravity/agy) do only the task they get and write results where the task says.
- **Fallback boss:** when the user opens a helper AI directly (for example because Claude is out of usage), that AI is the boss: it reads `HANDOFF.md` and continues the work. `ai codex` / `ai gemini` open them with that instruction.
- The user approves every design choice, plan, commit, push and publish. No AI pushes, publishes or commits without the user's OK.

## Folders and files
| Path | Use |
|---|---|
| `HANDOFF.md` | Work in progress. The boss updates it when a task starts, changes or stops, so another AI can continue. |
| `MEMORY.md` | Facts every AI should know about the user and the setup. |
| `routing.json` | Who is good at what, models per effort, limits. Edit it to change the routing. |
| `inbox\<ai>\` | Messages and tasks for that AI, one Markdown file each. The reader moves handled files to `done\`. |
| `files\` | Outputs and files passed between AIs; one subfolder per job. |
| `state\` | Parking of helpers that are out of quota (`cooldown.json`), the job log (`ask.log`), saved helper questions. |
| `bin\` | The tools: `route.ps1`, `ask.ps1`, `fanout.ps1`, `council.ps1`, `limits.ps1`, `gemini-keys.ps1`, `perplexity-key.ps1`, `codex-chats.ps1`. |

## Message format
File name: `YYYY-MM-DD-HHMM-from-<ai>-<topic>.md`.
```markdown
# <topic>
From: claude   To: gemini   Date: 2026-01-31 14:30
## Task
What to do, in one or two sentences.
## Files
Paths to read; where to write the result.
## Done when
The exact condition for "finished".
```

## Rules for every AI
- Never delete or edit another AI's message or file. Only move your own inbox messages to `done\`.
- Write only in the folders the task names, plus your own inbox and `files\`.
- Never put passwords, tokens or API keys in the hub. Gemini keys live in `~\.gemini\api-keys.txt` and the Perplexity key in `~\.perplexity\api-key.txt`, outside the hub.
- When you finish work as boss, update `HANDOFF.md`.
