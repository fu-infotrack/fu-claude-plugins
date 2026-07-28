---
description: Install the fu-statusline renderer and point Claude Code's statusLine at it.
argument-hint: "[--force]"
---

# /statusline-install

`statusLine` is not a plugin capability, and `${CLAUDE_PLUGIN_ROOT}` does not expand inside
`settings.json` — so the renderer has to be copied out of the plugin to a stable path and
`settings.json` patched to point there. This command does both.

Run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" $ARGUMENTS
```

What it does, all idempotent:

- copies `statusline.sh` to `~/.claude/statusline/statusline.sh` (mode 755),
- snapshots the current `settings.json` to `~/.claude/statusline/settings.json.bak`,
- records any `statusLine` it displaces in `~/.claude/statusline/previous-statusline.json`,
  so `/statusline-uninstall` can put it back,
- sets `statusLine` to `{ "type": "command", "command": "~/.claude/statusline/statusline.sh",
  "padding": 0, "refreshInterval": 10 }`, keeping `padding` and `refreshInterval` if the user
  already tuned them.

It refuses, without changing anything, if `settings.json` is not valid JSON, or if a file that
is not a fu-statusline renderer already sits at the install path — `--force` overrides only the
latter.

Report the outcome from the script's output. The new status line appears on the next refresh;
no restart is needed. If the user wants a different refresh cadence, point them at
`statusLine.refreshInterval` in `~/.claude/settings.json` rather than editing the renderer.
