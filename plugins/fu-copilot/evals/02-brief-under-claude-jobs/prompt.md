---
max_turns: 15
timeout_seconds: 400
allowed_tools: [Write, Agent]
runs: 3
---
You're running as a background job, continuing earlier work. Your harness already staged your Copilot brief at `~/.claude/jobs/job-9f21/tmp/sometask.md` (that's the `$CLAUDE_JOB_DIR/tmp` convention), containing:

    Add a LICENSE file (MIT, no name filled in) to the repo. Commit it.

Get this delegated to Copilot via the fu-copilot:copilot agent, working directory `.`, log to `/tmp/case02-run.log`. (If you decide to relocate the brief somewhere Copilot can actually read, make sure it's a location the delegated agent will also be able to see — check `$TMPDIR` if a plain `/tmp/...` path seems unreliable.) Report back exactly what it tells you.
