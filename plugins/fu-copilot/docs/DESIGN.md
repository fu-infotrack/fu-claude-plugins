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
user`; the string appears in three of that session's output logs, and it was
**re-confirmed live on 2026-09-01** against the current Copilot build -- a probe
read of `~/.claude/jobs/.../probe-denied.md` failed with exactly that text while a
sibling read of `/tmp/fu-probe-readable.md` succeeded in the same run. The rule is
current behaviour, not history. **It fails
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
- `--session-id <uuid>` is a passthrough, and **measured working** (2026-09-01):
  a caller-generated UUID became the session's own id (Copilot echoed it back as its
  `--resume` handle), and a second dispatch with the same id recalled a token from
  the first turn with no tool calls, its prompt cache growing 52.5k -> 69.9k. So a
  follow-up costs a short prompt instead of a re-sent ~5 KB brief. Caveat: round one
  had also stashed the token in a `session_memory` SQL table of its own, so recall
  *could* have come from there; the absence of any tool call in round two plus the
  cache growth is what favours conversation context.

  The session that motivated this plugin used `--resume`/`--session-id` in **0 of
  24** invocations despite Copilot printing a handle every time, re-sending a full
  brief each round -- so this is the largest easy saving available.
- Generate the id with `cat /proc/sys/kernel/random/uuid`: **`uuidgen` is not
  installed on this host.** `dispatch.sh` rejects an explicitly-passed empty flag
  value rather than ignoring it -- found the hard way, when `--session-id "$SID"`
  with `SID` unset silently started a fresh session instead of continuing one.

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

Exercised against real Copilot runs on 2026-09-01, through the installed plugin
cache:

| Path | Result |
|---|---|
| dispatch -> wait -> check | brief confirmed in the process cmdline, PID wait returned, resume handle extracted |
| `/tmp` brief readable by Copilot | yes -- marker returned verbatim |
| `~/.claude/jobs` read | denied, with the exact expected error text |
| `--session-id` continuation | yes -- second dispatch recalled the first turn |

Still **not** exercised: the long-run path (10–113 min). Everything here completed
in 10–20 s, so the `--poll`/timeout behaviour under a genuinely long run is
inferred from the code, not observed.

## Tests

Hermetic; `copilot` stubbed on PATH, throwaway `$HOME`, throwaway git fixtures.

```bash
bash plugins/fu-copilot/test/dispatch.test.sh
bash plugins/fu-copilot/test/verify.test.sh
```
