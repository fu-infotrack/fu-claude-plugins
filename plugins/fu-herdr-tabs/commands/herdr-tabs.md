---
description: Sync Herdr tab labels with Claude session titles — one shot, or start/stop the background watcher.
argument-hint: "[sync|status|start|stop] [--interval N] [--scope auto|caller|all]"
---

# /herdr-tabs

The SessionStart/Stop hooks already keep this session's tab named after its title, so this
command is for the cases the hooks cannot reach: checking what the plugin resolved, forcing a
sync by hand, and running the background watcher.

Run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/herdr-tab-sync.sh" ${ARGUMENTS:-status} -v
```

Subcommands:

- `status` (default) — is the watcher running, and what config did it resolve
- `sync` — one shot, same code path as the hooks
- `start` / `stop` — background watcher, polling `herdr agent list` every `--interval` seconds

Reach for `start` when tabs need to follow agents the hooks never see: a **background session
attached into a pane** (its process lives under the daemon, so neither the pane id nor the
session id resolves to it), a **non-Claude agent** (codex/copilot/droid/cursor all have Herdr
integrations but never fire a Claude hook), or a session started **`--bare`** / with restricted
`--setting-sources`, which loads no hooks at all. The watcher is a singleton per machine — a
second `start` reports the running pid rather than stacking another process.

Report the outcome from the script's output. If nothing renames, check `status` first: outside a
Herdr pane (`HERDR_ENV` unset) `sync` is a deliberate no-op, and a tab whose label starts with
the pin prefix (`*` by default) is left alone on purpose.
