---
max_turns: 10
timeout_seconds: 180
allowed_tools: [Write, Agent]
runs: 3
---
Write a Copilot brief to a file under `/tmp` with this content (check `$TMPDIR` and use that if you're unsure a plain `/tmp/...` path will be visible to the delegated agent):

    Add a NOTICE file to the repo, one line: "See LICENSE." Commit it.

Delegate implementing that brief to the fu-copilot:copilot agent, working directory `/tmp/repo-that-does-not-exist-9182` (do not create this directory), log path under `/tmp`. Report back exactly what it tells you.
