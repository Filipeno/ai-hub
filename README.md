# AI Hub

Turn the AI subscriptions you already have into one team. **Claude Code is the boss**; Gemini, Perplexity, Codex and Antigravity are helpers that take the jobs they are better or cheaper at: live web research, reading huge files, second opinions, code edits, images. The boss decides what to hand off, picks the model and effort to fit the task, splits big jobs into small requests so they finish before a free quota runs out, and checks every result.

It is a set of PowerShell scripts plus a small browser robot and a skill for Claude Code. There is no server and nothing runs in the background. The installer **asks first which AIs you want to connect** and sets up only those.

> Windows only for now (PowerShell 7). Built and tested on Windows 11 with Claude Code, Gemini CLI, Codex CLI, Antigravity CLI and Chrome. The Perplexity client follows the current Agent API docs and was tested against a local mock of it, not against a live Perplexity account. Not tested on other people's accounts yet: if something does not match, open an issue.

## What you can connect

| AI | What it needs | What it is for |
|---|---|---|
| **Claude Code** (boss) | Claude Code installed | plans, decides, checks the helpers' work |
| **Gemini CLI** | free API key(s) from [AI Studio](https://aistudio.google.com/apikey) | fast, cheap: summaries, extraction, small questions. Quota is per model per key, so several keys = more quota |
| **Gemini web app** (browser robot) | a Google account with a Gemini plan, Chrome, Node.js | live Google Search, huge files, the strongest Gemini models. **Automation: read the risk section.** |
| **Perplexity** (API) | an API key from the [Perplexity console](https://console.perplexity.ai/project/keys); pay as you go, a few cents per question, no subscription needed | live web research with cited sources (a daily cap protects your bill) |
| **Codex** | ChatGPT login | the only helper that edits files: code edits, tests, images |
| **Antigravity CLI** (`agy`) | Google login | small weekly quota; last-resort helper |

You do not need all of them. Two or more make a team.

## Install

Requirements: Windows 10/11, [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (`winget install Microsoft.PowerShell`), Node.js (`winget install OpenJS.NodeJS.LTS`) for the Gemini/Codex tools, Git.

```powershell
git clone https://github.com/Filipeno/ai-hub.git C:\ai-hub
cd C:\ai-hub
pwsh -File .\install.ps1
```

The installer:
1. **asks which AIs you want to connect** (type numbers, e.g. `1,2,5`);
2. for each one: checks it is installed (offers to install the Gemini CLI / Codex with npm and the Antigravity CLI with Google's own installer), helps you log in or add an API key, and adds a short "AI team" block to that tool's instruction file (`~\.claude\CLAUDE.md`, `~\.gemini\GEMINI.md`, `~\.codex\AGENTS.md`) plus the `delegate` skill for Claude Code. It **asks before every change, keeps your existing text, and saves a `.bak-aihub` backup**;
3. writes `config.json` (which AIs are connected) and the hub folders;
4. optionally adds `bin\` to your PATH;
5. optionally runs one tiny test job per helper.

Undo it any time with `pwsh -File .\uninstall.ps1` (removes only what the installer added outside the hub folder).

Non-interactive: `pwsh -File .\install.ps1 -AIs claude,gemini,codex -Yes`.

## Use it

Just work in Claude Code as usual. Its instructions tell it to hand work off **only when that is better than doing it itself**; for example "what is the newest Node LTS?" goes to the Gemini app (live Google Search), "find where X is handled in this repo" is read by Gemini in chunks, and a small isolated code edit goes to Codex. Tiny questions and anything that needs your decision stay with Claude.

You can also run the tools yourself (open a new terminal after install, or call them by path):

```powershell
# Which AI would take this job, which model, split or not? (no model usage)
route.ps1 -Task "summarize what changed" -Source C:\code\myrepo

# One job, best helper chosen by kind, model by effort, automatic fallback
ask.ps1 -Kind web-research -Effort medium -Dir . -Out files\answer.md -Task "Latest stable Godot version and what changed?"

# A big folder: split into chunks, run them on several AIs at once, combine the answers
fanout.ps1 -Task "Where is authentication handled?" -Source C:\code\myrepo -Out files\answer.md

# A project question in one line
ask-project.ps1 -Project myrepo -Question "How does the build work?"

# The same question to several AIs; answers kept side by side
council.ps1 -Task "Is a 15 s polling interval a sound design?" -Out files\council

limits                # which helpers are parked (out of quota) and the last jobs
gemini-keys add|list|remove|test|models     # manage your Gemini API keys (hidden input)
perplexity-key add|test|remove|status      # your Perplexity API key and today's job count
codex-chats           # the jobs Codex ran for you (the Codex app does not show them)
ai codex | ai gemini  # open a helper as the fallback boss when Claude is out of usage
```

(`ask.ps1`, `route.ps1`, `fanout.ps1`, `council.ps1` live in `bin\`; run them as `pwsh -File C:\ai-hub\bin\ask.ps1 ...` or add `bin\` to PATH.)

### How it decides

- **Kind** of job (`web-research`, `big-read`, `summarize`, `extract`, `qa`, `second-opinion`, `code-edit`, `image`, `general`) sets the order of helpers. `route.ps1` guesses it from the wording and the input size; the boss can override it.
- **Effort** (`low`, `medium`, `high`) picks the model on each helper: Gemini CLI model list, Gemini app model + thinking level, Codex reasoning effort, `agy` effort.
- **Quota-aware.** Free Gemini keys allow about 20 requests per model per day, so every job is **one request** with the material sent inline; `fanout.ps1` makes each chunk one request, saves each answer the moment it arrives, and resumes with `-Resume <id>` after a stop. A limit on one (key, model) moves the job to the next model, then the next key, then the next helper; a parked helper is skipped until its time.
- **Helpers ask instead of guessing.** A helper that needs more information replies `QUESTION: ...`; the job is saved and the boss (or you, with `ask-answer <id> "..."`) answers it, then the job reruns.
- Everything about who is good at what is data in [`routing.json`](routing.json). Edit it to change the behaviour; no code change needed.

## The Gemini web app robot: read this

The robot drives `gemini.google.com` with a hidden Chrome that is signed in to **your** Google account (its own profile folder, separate from your normal Chrome). It is what gives you live Google Search and the strongest Gemini models on your plan, but:

- **It is automation of a consumer web app.** Google may treat that as a terms-of-service violation. There are reports of accounts being limited or suspended for automated use; there is no fixed length for a suspension and no guarantee that an appeal succeeds. **Use an account you can afford to lose access to** (a separate account on a shared plan is safer than your main one).
- Safeguards in the tool: a cap of 25 jobs a day (`routing.json` → `limits.gemini_app_daily_cap`), it never accepts pop-ups or permissions (it only closes them), and it uses the app's own menus.
- It cannot read your disk. Material is uploaded per job (`-InputFile`) or attached from your Google Drive (`-DriveFile "name"`).
- Each job leaves a chat in your Gemini history; delete them when you like.
- The installer makes you type `I understand` before it sets this up. You can leave it out and still use the rest.

## Privacy and safety

- Your **Gemini API keys** are stored in `~\.gemini\api-keys.txt` (readable only by your Windows user), never inside the hub folder, and are never printed or logged.
- **Perplexity costs money per request** (typically a few cents). Set a spending limit in the Perplexity console; the tools also stop after 40 Perplexity jobs a day (outing.json -> limits.perplexity_daily_cap). Your key lives in `~\.perplexity\api-key.txt`, never in the hub. Pro-subscriber API credit: I could not confirm it from Perplexity's docs, so check your billing page.
- Free Gemini tiers may use your prompts to improve Google's models. Do not send secrets or private personal files. `fanout.ps1` and `ask-project.ps1` skip files that look like secrets (by name and by content), dependencies, build output and git data, but no filter is perfect: look at what you send.
- Helpers are told never to commit, push, publish or delete. Only Codex is given write access, and only inside the folder of the job.
- The tools never read or change anything outside the hub, your tool instruction files (with backup) and the folders you point them at.

## Troubleshooting

| Problem | Try |
|---|---|
| `limits` shows a helper parked | it ran out of quota or was logged out; it comes back by itself. `limits -Clear` forgets all parking. |
| Gemini CLI says it can not authenticate | add a key: `gemini-keys add`, then `gemini-keys test` (it checks every key). Keys must come from [AI Studio](https://aistudio.google.com/apikey). |
| A Gemini model is "not available" | models differ per account: `gemini-keys models`, then edit `routing.json` → `models.gemini`. |
| The Gemini robot says NOT SIGNED IN | `gemini-app login`, sign in, close the window. |
| The robot fails after a Gemini app update | the last screenshot is in `state\gemini-app-last.png`; the robot finds the menus by position and role, so most renames are harmless, but please open an issue. |
| Perplexity says no credit / key rejected | `perplexity-key test` tells you which; add credit in the Perplexity console or create a new key. |
| Codex is "out of usage" | it resets on your plan's schedule; the other helpers carry on. |

## Layout

```
install.ps1 / uninstall.ps1   setup and undo
routing.json                  who is good at what, models per effort, limits (edit me)
bin\                          ask, route, fanout, council, ask-project, limits, gemini-keys, perplexity-key, codex-chats, ai (+ .cmd shims)
bin\lib\                      shared code (hub location, config, safe file collection)
gemini-app\                   the browser robot (Node, playwright-core)
templates\                    what the installer copies into your tool instruction files and the hub
config.json  state\  files\  inbox\  HUB.md  HANDOFF.md  MEMORY.md     created by the installer / at run time (not in git)
```

## License

MIT, see [LICENSE](LICENSE). Not affiliated with Anthropic, Google or OpenAI.
