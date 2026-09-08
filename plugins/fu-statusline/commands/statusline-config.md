---
disable-model-invocation: true
description: Install, uninstall or inspect the fu-statusline renderer and the statusLine it patches into settings.json.
argument-hint: "[status|install|uninstall] [flags]"
---

# /statusline-config

`statusLine` is not a plugin capability, and `${CLAUDE_PLUGIN_ROOT}` does not expand inside
`settings.json` — so the renderer has to be copied out of the plugin to a stable path and
`settings.json` patched to point there. This command manages that.

Run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh" $ARGUMENTS
```

With no arguments it reports **status** and changes nothing: whether the renderer is installed
and current, where `statusLine` points and whether that is ours, what would be restored on
uninstall, and whether a render cache exists.

`install [--force]`, all idempotent:

- copies `statusline.sh` to `~/.claude/statusline/statusline.sh` (mode 755),
- snapshots the current `settings.json` to `~/.claude/statusline/settings.json.bak`,
- records any `statusLine` it displaces in `~/.claude/statusline/previous-statusline.json`,
  so `uninstall` can put it back,
- sets `statusLine` to `{ "type": "command", "command": "~/.claude/statusline/statusline.sh",
  "padding": 0, "refreshInterval": 10 }`, keeping `padding` and `refreshInterval` if the user
  already tuned them.

It refuses, without changing anything, if `settings.json` is not valid JSON, or if a file that
is not a fu-statusline renderer already sits at the install path — `--force` overrides only the
latter.

`uninstall [--keep-script] [--purge]`:

- restores the `statusLine` recorded in `previous-statusline.json`, or deletes the key outright
  if there was nothing to restore,
- deletes the installed renderer, but only if it carries the `fu-statusline` marker —
  `--keep-script` leaves it,
- `--purge` also removes the render cache (`~/.cache/cc-statusline`) and the install directory.

A `statusLine` pointing at something other than this renderer is left untouched, and the command
reports that rather than changing it. Uninstalling when nothing is installed is a no-op, not an
error.

Report the outcome from the script's output. An install takes effect on the next status line
refresh; no restart is needed. If the user wants a different refresh cadence, point them at
`statusLine.refreshInterval` in `~/.claude/settings.json` rather than editing the renderer.
