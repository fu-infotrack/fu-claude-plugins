---
description: Remove the fu-statusline renderer and restore whatever statusLine it displaced.
argument-hint: "[--keep-script] [--purge]"
---

# /statusline-uninstall

Run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/uninstall.sh" $ARGUMENTS
```

What it does:

- restores the `statusLine` recorded in `~/.claude/statusline/previous-statusline.json`, or
  deletes the key outright if there was nothing to restore,
- deletes `~/.claude/statusline/statusline.sh`, but only if it carries the `fu-statusline`
  marker — `--keep-script` leaves it,
- `--purge` also removes the render cache (`~/.cache/cc-statusline`) and the install directory.

A `statusLine` pointing at something other than this renderer is left untouched, and the
command reports that rather than changing it. Running it when nothing is installed is a no-op,
not an error.

Report the outcome from the script's output.
