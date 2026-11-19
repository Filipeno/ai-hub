# Commands

Every script in `bin/`, with the first comment line of the script as its description.

| Script | Description |
|---|---|
| `ai.ps1` | Open an AI as the boss in the current folder. |
| `ask-project.ps1` | Ask a question about a whole project (or a school folder) and get the answer in one file. |
| `ask.ps1` | Run one job on the best helper AI, with model + effort chosen per task, automatic fallback, and question passing. |
| `codex-chats.ps1` | List the chats Claude started with Codex (`codex exec` jobs). The Codex app does not show them. |
| `council.ps1` | Ask the same question to several AIs at the same time and keep each answer separately, for a real second opinion. |
| `fanout.ps1` | Split a big job into chunks, run the chunks on several AIs at the same time, then combine the answers. |
| `gemini-keys.ps1` | Manage Gemini API keys (stored in `~\.gemini\api-keys.txt`, one per line, only your Windows user can read it). |
| `limits.ps1` | Show which helper AIs are parked (out of quota, busy or logged out) and until when, plus the last jobs. Costs no model usage. |
| `perplexity-key.ps1` | Manage the Perplexity API key (stored in `~\.perplexity\api-key.txt`, only your Windows user can read it; never inside the hub). |
| `route.ps1` | Decide where a job should go: which helper chain, which effort (model), whether to split it, or whether to just do it yourself. |
| `selftest.ps1` | Daily AI hub self-test. Uses no Claude usage: one tiny job per helper + a model check. |
| `test-parse-all.ps1` | Parses every bin/*.ps1 with the PowerShell parser; lists files with syntax errors and exits 1, else prints OK. |
| `test-routing.ps1` | Checks routing.json: exits 1 if it is not valid JSON or a top-level entry is null or empty, else prints OK (-SelfTest also runs failure fixtures). |
