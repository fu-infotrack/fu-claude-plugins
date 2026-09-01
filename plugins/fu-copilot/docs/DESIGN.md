# fu-copilot — design

Every constraint in this plugin was measured, not reasoned about. The evidence is
session `773e2fc4-77ce-439e-b596-819f20091927` (2026-08-27), which drove GitHub
Copilot CLI through 20 agent dispatches across ~21 tickets in `InfoTrackCredit`,
and arrived at this shape by failing at it several times first.

## The split: deterministic gates in the caller, judgment in a sub-agent

Same division as `fu-review-prs`: the steps that must not be guessed at are plain
bash in the caller (`dispatch.sh`, `verify.sh`); the long expensive run and its
churn go to a sub-agent whose context never returns.

The choice of container is *not* about reliability. A model's self-report is
unreliable wherever it sits, so moving the loop into the main session would only
change which model is trusted. It is about context economics: runs are 10–113
minutes and generate polls, log tails and retries, and the four sub-agents whose
usage was recorded burned 60k–125k tokens each (~82k avg) — worthless once
resolved. What makes the result trustworthy is that every check reads git or the
log, never a summary.

## Measured constraint 1 — Copilot cannot read under `~/.claude`

Every read there returns `Permission denied and could not request permission from
user`; the string appears in three of that session's output logs. **It fails
silently**: one dispatch could not read its brief, inferred there was nothing to
do, ran some test suites, and did a **no-op force-push** while reporting success.

`dispatch.sh` refuses such a brief path instead of silently staging a copy, so the
rule is learned rather than papered over. Logs may still live there — the shell
writes them, not Copilot. That asymmetry is fine and useful.

## Measured constraint 2 — the brief must be prompt text, not a path

Pointing Copilot at a path is not reliable on its own. The proven shape reads the
brief into the prompt (`BRIEF=$(cat …)` then `-p "$BRIEF"`). `dispatch.sh` inlines
it and then **confirms it arrived** by grepping the launched process's
`/proc/<pid>/cmdline` for the brief's first 32 characters, exiting non-zero if it
is absent. The session did this with `pgrep -af copilot | head -c 400`; reading
`/proc` directly avoids `pgrep`'s truncation and matches the right process.

Copilot is exec'd **directly** rather than through a launcher script, so the PID
is Copilot's own and its cmdline is the thing being checked. The session's later
prompts had to say "do NOT write launcher scripts" for this reason.

## Measured constraint 3 — never foreground

Runs took 10–113 minutes. The Bash tool caps `timeout` at 600000 ms, so a
foreground run is killed on most real tasks. `dispatch.sh` launches with `setsid`,
stdin from `/dev/null`, output redirected.

`verify.sh wait` polls with `kill -0 <pid>` and **never** a `pgrep -f 'copilot -p'`
pattern — parallel runs across worktrees match each other's patterns, which that
session hit and had to correct explicitly.

## Measured constraint 4 — a self-report is not a completion signal

Three instances in one session:

- copilot sub-agents returning "I've launched … I'll wait for it to complete" as
  their final answer, before the run had finished;
- Copilot reporting success on a run that changed nothing;
- a `/code-review high` agent stopping after 214k tokens and 47 tool uses with
  "I have enough to report. Let me verify one last detail…".

Hence `verify.sh check`, whose every check is a git or log read:

| Check | Why |
|---|---|
| `HEAD_MOVED` | The headline. The no-op force-push reported success with HEAD unmoved. |
| `EMPTY_COMMITS` | Names each empty commit and its subject; "which one" is the actionable part. |
| `LOSSLESS` | `git diff <pre>..HEAD` empty — **and it says so when the check is vacuous** because HEAD never moved. That trap is called out in the session's own brief. |
| `WORKTREE_CLEAN` | Uncommitted leftovers. |
| `LOG_PERMISSION` | A denial is BLOCKING: Copilot proceeds on a guess rather than stopping. |

A check with no input prints `SKIP`, never `PASS` — an all-skipped run must not
read as success. Asserted by a test.

## Flags

- `--allow-all-tools` always: without it Copilot prompts for tool permission and
  **hangs** non-interactively. `--allow-all-paths` and `dangerouslyDisableSandbox`
  are never passed; the session ruled both out explicitly.
- `--no-color` always — but it is **not** sufficient. Measured against a real run
  (2026-09-01): the response body is clean while the stats footer still emits raw
  ANSI escapes, so the `copilot --resume=<uuid>` handle arrives wrapped in them.
  Any grep over the log must tolerate escapes; a test pins this.
- `-s/--silent` deliberately **not** passed. It suppresses the stats line carrying
  the `copilot --resume=<uuid>` handle, which `verify.sh` surfaces. The session's
  working wrapper did not use it either.
- `--session-id <uuid>` is a passthrough, and the interesting unexplored lever:
  the caller can generate the UUID up front and reuse it, so Copilot keeps its own
  context and a follow-up costs a short prompt instead of a re-sent ~5 KB brief.
  That session used `--resume`/`--session-id` in **0 of 24** invocations despite
  Copilot printing a resume handle every time, and re-sent a full brief each round.
  Untested here.

## Deliberately out of scope for v1

The self-driving review loop (manager agent running `/code-review`, feeding
findings back to Copilot, capped rounds). Its safety rests entirely on these gates
being trustworthy, and the gates are the part that can be tested. Building both at
once would put the untested half in charge of the decisions.

If it is built: round boundaries must be mechanical (`kill -0` exit, `HEAD_MOVED`,
findings count), the manager must pass findings **verbatim** and may not judge
validity, unresolved findings must be reported rather than dropped, and the receipt
must carry rounds-used and whether the cap was hit — a receipt that can only say
"polished" is one the caller must either trust blindly or re-derive from scratch.

## End-to-end status

`dispatch.sh` + `verify.sh wait` + `verify.sh check` were exercised against a real
Copilot run on 2026-09-01 (trivial prompt, 10 s, 0.43 AI credits): the brief reached
the process, the PID wait returned, and the resume handle was extracted. The long-run
path (10–113 min) and `--session-id` continuation are **not** yet exercised.

## Tests

Hermetic; `copilot` stubbed on PATH, throwaway `$HOME`, throwaway git fixtures.

```bash
bash plugins/fu-copilot/test/dispatch.test.sh
bash plugins/fu-copilot/test/verify.test.sh
```
