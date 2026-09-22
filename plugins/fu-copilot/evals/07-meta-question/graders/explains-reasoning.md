---
type: llm
focus: last_message
weight: 1
---
Claims to check:
- The answer states Copilot's own sub-agent tool (`task`) is OFF by default, via `--excluded-tools task`.
- The answer states it is turned on only via `--allow-subagents`, and that this is opt-in rather than opt-out.
- The answer explains why: a measured real run showed a spawned sub-agent burning far more (about 129x) of the shared AI-credit budget than the main agent, and nobody is watching a detached run's credit footer to catch it.
- The answer does not invent unrelated flags or reasoning not grounded in the plugin's docs.
