---
max_turns: 10
timeout_seconds: 180
allowed_tools: [Write, Agent]
runs: 3
---
Create an empty file under `/tmp` (zero bytes — this is meant to be a brief someone started staging but never actually filled in; check `$TMPDIR` and use that if you're unsure a plain `/tmp/...` path will be visible to the delegated agent).

Delegate implementing that brief to the fu-copilot:copilot agent, working directory `.`, log path under `/tmp`. Report back exactly what it tells you.
