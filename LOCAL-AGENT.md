# LOCAL-AGENT notes (ai-hub)

Windows-only hub: Claude Code is the boss, Gemini / Perplexity / Codex / Antigravity are helpers.
This git repo (`D:\projekty\ai-hub`) is a copy. The live hub is `D:\ai-hub`, which is not a git repo.

## Layout
- `bin/` PowerShell 7 tools: `ask.ps1`, `ai.ps1`, `fanout.ps1`, `route.ps1`, `usage.ps1`, `pc-mode.ps1`, `selftest.ps1`, `todo.ps1`, `approval.ps1`, etc.
- `bin/lib/` shared helpers. `gemini-app/`, `perplexity-app/` browser robots. `robot-common/`.
- `routing.json` routing and daily caps. `templates/` tool instruction blocks. `install.ps1` / `uninstall.ps1`.
- `README.md` user docs; `WORKLOG.md` history. Runtime folders `state/`, `files/`, `inbox/` are git-ignored.

## Commands
- Self-test (sends one tiny job per connected AI, no Claude usage): `pwsh -NoProfile -File bin\selftest.ps1`, or `selftest -Quick` to skip the two browser robots
- Route check (no model usage): `pwsh -NoProfile -File bin\route.ps1`
- Usage check: `pwsh -NoProfile -File bin\usage.ps1`
- Installer checks: `pwsh -NoProfile -File bin\setup-check.ps1`
- No unit-test runner is in the repo. `bin/test-*.ps1` scripts exist only in the live `D:\ai-hub\bin`; run them there if needed.

## Pitfalls
- Never print or commit API keys. Gemini keys live in `~\.gemini\api-keys.txt`, Perplexity in `~\.perplexity\api-key.txt`, sign-in profiles in `~\.perplexity-app-profile`. None of these go in the hub.
- Browser robots are automation of consumer web apps: keep their daily caps (`gemini_app_daily_cap`, `perplexity_app_daily_cap`) and never accept pop-ups or permissions.
- Helpers must never commit, push, publish or delete. Only Codex may write files, and only inside its job folder.
- `fanout.ps1` and `ask-project.ps1` skip secret-looking files by name and content; check what is sent anyway.
- Robot failures save screenshots in `files\robot-failures\`; `state\gemini-app-last.png` is the last screenshot.
- Parked helpers: `limits -Clear` forgets parking. A Codex "out of usage" state is a WARN, not a failure (see commit e95cfa7).
- Edits to `install.ps1` must keep the user's existing instruction files and the `.bak-aihub` backups.
- Windows paths: use `\` in PowerShell and absolute paths in scheduled tasks.
