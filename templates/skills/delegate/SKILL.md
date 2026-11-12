---
name: delegate
description: Route work to the helper AIs of the AI Hub (Perplexity, Gemini app, Gemini CLI keys, Codex, agy) and run several of them in parallel. Use on your own, without being asked, ONLY when a hand-off is better than doing it yourself: live web research, reading more than about 30 KB of files or logs, many independent chunks, an independent second opinion, an isolated code edit for Codex, image generation. Never for tiny questions, decisions the user must make, or work that needs this conversation's context. Also use when the user says "delegate", "give it to Gemini/Codex", "ask the council" or "fan out".
---

# Delegate: know what to send where

You are the boss. Your own usage is the scarce thing, so spend it on judgement, design, coordination and checking. Helpers get the bulk work they are better or cheaper at. The hub is `{{HUB}}`; the rules are data in `{{HUB}}\routing.json` (edit that, not the scripts). Connected AIs: {{ENABLED}} (a helper that is not connected is skipped automatically).

## 1. Decide: hand off or do it yourself?
Run the router first when unsure. It costs no model usage:
```powershell
pwsh -NoProfile -File "{{HUB}}\bin\route.ps1" -Task "<what you want done>" [-Source <file|folder> ...] [-Kind <kind>] [-Effort low|medium|high]
```
It prints JSON: `handoff` (true/false), `kind`, `effort`, helper `chain`, input size, number of `chunks`, a `warning`, and the exact `command`. You know the conversation and it does not: override any field.

| Situation | Do |
|---|---|
| Tiny question, or a few tool calls would do it | Do it yourself (`handoff: false`) |
| Needs the user's choice (design, taste, publish, git) or this conversation's context | Do it yourself |
| Needs live or recent facts (versions, prices, news, docs lookups) | `web-research`: Perplexity (cited sources, a few cents) if connected, else the Gemini app (real Google Search) |
| Reading more than about 30 KB of files, logs or documents, or many files | `big-read` / `summarize`: Gemini app (huge context) and Gemini keys; `fanout.ps1` if it must be split |
| Independent second opinion on a design, bug or plan | `council.ps1`: several AIs answer separately |
| Isolated code edit in 1-5 files, boilerplate, tests | `code-edit`: Codex only (it alone may change files) |
| Image generation | `image`: Codex (`$imagegen`) |
| Check or fix a helper's result | You only |

Never send secrets, passwords or private personal files to any helper. Free Gemini tiers may train on prompts.

## 2. The helpers
- **perplexity**: the Perplexity Agent API, pay as you go. Live web search with cited sources (a Sources: list is appended to the answer). Costs a few cents per job and is capped per day. It cannot see the PC's disk (material goes in with `-InputFile`) and is not for big files. Effort low / medium / high maps to the API's own effort levels.
- **gemini-app**: the Gemini web app on the user's Google AI plan through a hidden Chrome. Real Google Search, huge context, uploads (text, PDF, images), three models (fast / everyday / most capable) with thinking levels. 15-75 s per job, 25 jobs a day (safety cap), each job leaves a chat in the user's Gemini history. It cannot see the PC's disk: give it material with `-InputFile` (uploaded) or `-DriveFile "name"` (a file in the user's Google Drive; the first search match is used).
- **gemini** (CLI on free API keys): about 20 requests per day per model per key, several keys. Fast and cheap for small jobs. Material goes in on stdin (`-InputFile`): one job is one request. No Pro model on the free tier, and Google Search hits 429.
- **codex**: the only helper allowed to edit files. Strong at code edits, tests, images.
- **agy** (Antigravity CLI): a small weekly quota. Last resort only.

## 3. Effort picks the model
`-Effort low | medium | high` (the router suggests one; override it): low = fast cheap model (lookups, extraction, short summaries); medium = everyday; high = strongest available model with long thinking (design critique, subtle bugs, security). Each (key, model) pair has its own quota and its own parking, so a limit on one model moves the job to the next model, then the next key, then the next helper.

## 4. The tools
Run long jobs with `run_in_background: true`.
```powershell
# one job: best helper by kind, model by effort, automatic fallback
pwsh -NoProfile -File "{{HUB}}\bin\ask.ps1" -Kind <kind> -Effort <e> -Dir "<dir>" -Out "{{HUB}}\files\<job>\answer.md" -Task "<brief>" [-InputFile <material>] [-NoDisk] [-DriveFile "x.md"] [-Mode edit] [-Helper <first>]
# big or many inputs: split into chunks, run them on several AIs at once, combine
pwsh -NoProfile -File "{{HUB}}\bin\fanout.ps1" -Task "<question>" -Source <file|folder> -Out "{{HUB}}\files\<job>\answer.md" [-Kind big-read] [-Effort e] [-MaxChunks 8]
# a whole project folder question in one line
pwsh -NoProfile -File "{{HUB}}\bin\ask-project.ps1" -Project <folder> -Question "<question>"
# same question to several AIs; answers kept apart in <folder>\council.md
pwsh -NoProfile -File "{{HUB}}\bin\council.ps1" -Task "<question>" [-Source ...] -Out "{{HUB}}\files\<job>" [-Effort high]
```
- Why splitting matters: a free key allows about 20 requests per model a day, and a job that runs out half way loses everything. `fanout.ps1` makes each chunk one request, saves each answer the moment it arrives, and `-Resume <id>` redoes only the missing chunks. Chunks run at the same time on the ready helpers. Over 8 chunks it refuses: narrow `-Source`.
- Last output line: `OK helper=<who> model=<m> effort=<e> out=<file>` (exit 0), `FAILED` (exit 3: do the job yourself and note it in `HANDOFF.md`), `INCOMPLETE` (fanout exit 3: resume it), `QUESTION id=...` (exit 10).
- `{{HUB}}\bin\limits.ps1` shows which helpers are parked and the last jobs. Never read, print or log `~\.gemini\api-keys.txt`.
- Briefs must stand alone: name the files, say what a good answer looks like, and where to write it.

## 5. When a helper asks a question (exit 10)
Every brief tells helpers to reply `QUESTION: ...` instead of guessing. The job is saved and a note lands in `{{HUB}}\inbox\claude\`.
1. Answer it yourself if you know it from the conversation, the code or memory.
2. If it needs the user's choice, ask the user in chat and wait.
3. Then: `pwsh -NoProfile -File "{{HUB}}\bin\ask.ps1" -AnswerId <id> -Answer "<answer>"`. The user can also run `ask-answer <id> "<answer>"`.

## 6. After the helper ends
1. Read the answer file. For edits, read the diff and run the tests or build.
2. Check it yourself; fix or redo a bad result. Helpers read, you decide. Never pass unchecked output on.
3. Add a line under "Delegated jobs" in `{{HUB}}\HANDOFF.md`: `- <date time> <boss> to <helper>: <task>, result in files\<job>\ (done/failed)`.
4. Tell the user in one line which helper and model did what.
5. If a helper changed files outside the named ones: revert and tell the user.

## 7. Reference
- `codex-chats` lists the jobs Codex ran for you (the Codex app does not show them).
- `perplexity-key add|test|remove|status` manages the Perplexity key (the user runs it in their own terminal; never read, print or log `~\.perplexity\api-key.txt`).
- `gemini-keys add|list|remove|test|models` manages the Gemini API keys (the user runs it in their own terminal). `gemini-app login` re-signs-in the robot if the login is lost.
