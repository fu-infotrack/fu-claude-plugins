---
max_turns: 20
timeout_seconds: 300
allowed_tools: [Bash, Write, Agent]
runs: 3
---
Set up a throwaway git repo at `./target-repo`: `git init`, then one commit with an empty `README.md` so there's a baseline HEAD.

Then get GitHub Copilot to do a trivial task in that repo: add a file `marker.txt` containing exactly the text `fu-copilot-eval-ok` (no extra whitespace or lines) and commit it.

Delegate this to the fu-copilot:copilot agent — write the brief yourself to a file under `/tmp` (not under `~/.claude`; if you're unsure a plain `/tmp/...` path will be visible to the delegated agent, check `$TMPDIR` and use that), point the agent at it, and give it the `./target-repo` directory to run in and a log path under `/tmp`. Do not write `marker.txt` yourself or do the coding — that is Copilot's job. Report back exactly what the agent tells you.
