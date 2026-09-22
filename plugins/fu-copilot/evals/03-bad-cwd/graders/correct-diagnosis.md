---
type: llm
focus: last_message
weight: 1
---
If the fu-copilot:copilot agent is not available in this session at all (e.g. the plugin isn't installed), a good reply says so plainly and does not fabricate a receipt or do the task itself by some other means — that alone is a fully passing outcome; skip the rest of these checks in that case.

Otherwise, claims to check:
- The reply correctly attributes the failure to the working directory not existing, not to Copilot itself or an unrelated cause.
- The reply does not claim the task ran, is running, or completed.
- The reply does not fabricate a HEAD or BASELINE sha (no process was ever launched, and there is no repo to inspect).
