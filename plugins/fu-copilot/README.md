# fu-copilot

Delegate a coding task to GitHub Copilot CLI, then verify what it actually did.

`/fu-copilot` (hidden; invoke explicitly) documents the procedure. `@copilot` runs
one long task and returns a receipt. Two scripts do the work:

| Script | Job |
|---|---|
| `scripts/dispatch.sh` | Stage the brief in `/tmp`, inline it into `-p`, launch detached, confirm it reached the process, print `PID` + `BASELINE_HEAD`. |
| `scripts/verify.sh` | `wait <pid>` via `kill -0`; `check` HEAD moved / empty commits / losslessness / clean tree / log denials. |

```bash
S=plugins/fu-copilot/scripts
$S/dispatch.sh --brief /tmp/brief.md --cwd ~/repo/thing --log /tmp/run.log
$S/verify.sh wait <PID> --poll 30        # 10-113 min; use run_in_background
$S/verify.sh check --cwd ~/repo/thing --baseline <SHA> --range <SHA>..HEAD --log /tmp/run.log
```

## Three things that will bite you

- **The brief must not live under `~/.claude`.** Copilot cannot read there and
  fails *silently* — one run inferred there was nothing to do and did a no-op
  force-push while reporting success. `dispatch.sh` refuses such a path. Logs
  there are fine; the shell writes those.
- **Never foreground.** Runs take 10–113 minutes; the Bash tool caps `timeout` at
  600 s. And wait on the PID, not a `pgrep 'copilot -p'` pattern — parallel runs
  across worktrees match each other.
- **Do not trust the summary.** Verify from git. `verify.sh` will also tell you
  when a passing check is *vacuous* because HEAD never moved.

`--no-color` is passed but does not fully clean the log — the stats footer still
emits ANSI escapes, so grep patterns must tolerate them.

Requires `copilot` on PATH and authenticated. See `docs/DESIGN.md` for the measured
evidence behind each rule, and what is deliberately left out of v1.

## Tests

```bash
bash plugins/fu-copilot/test/dispatch.test.sh
bash plugins/fu-copilot/test/verify.test.sh
```
