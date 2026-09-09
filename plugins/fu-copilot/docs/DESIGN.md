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

**Both sides of that comparison must be normalised the same way.** Fixed 2026-09-02
after a peer session reported it with a repro: the marker was newline-stripped
while `tr '\0' ' '` leaves real newlines in the cmdline, so any brief whose first
32 characters crossed a line break reported `BRIEF_REACHED_PROCESS: no` with the
full text sitting in the process's argv. A 10-character `/implement` first line
was enough. It cost a killed run that had already read the files its brief named —
the worst kind of gate failure, one that punishes a healthy run. A test pins it,
and was itself checked by reverting the fix.

### Naming the staged copy

The brief text arrives via `-p` regardless, so the staged `/tmp` copy matters only
for **re-reading** during a long run — and a brief cannot name its own staged
location, because this script picks the mktemp name. So `dispatch.sh` appends a
footer to the copy naming its absolute path.

Measured 2026-09-02 as an accidental A/B by a peer session, same model and task,
two consecutive dispatches: a brief saying only "a re-readable copy is staged by
the dispatcher" sent Copilot to a repo-scoped `glob **/*brief*`, "No matches
found", never found it; a brief naming the path explicitly had it read the file
with `sed -n '1,240p' <path>` as its **second** action, with no glob anywhere in
the log. It read through a shell rather than a file-read tool, so the footer needs
no tool-permission consideration.

The "it is outside the repo, so a repo-scoped glob will not find it" clause is
part of the stimulus that was measured, not decoration — the observed failure is
specifically reaching for a repo-scoped glob first, so dropping the clause would
ship a weaker stimulus than the one with evidence behind it. **n=1 each way:
directional, not proven.**

This is also why the brief does *not* move into the target worktree. A
worktree-local `tmp/` would be untracked, and `verify.sh`'s `WORKTREE_CLEAN` counts
untracked paths, so it would need an ignore rule the plugin cannot guarantee in
every target repo — a plugin guarantee resting on untracked per-machine state.
(For the record, the mechanism that *does* work is a `tmp/.gitignore` containing
exactly `*`: measured clean in a linked worktree, and it also makes the brief
unstageable. Adding a `!.gitignore` negation breaks it — the directory reappears
as untracked. Nothing needs it for the brief.)

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
- `--excluded-tools task` always: Copilot may not spawn its own sub-agents. A
  dispatch is already one scoped brief, and fan-out is expensive in exactly the
  place this plugin cannot see. Measured 2026-09-09 from a real dispatch's usage
  JSON: `agentMetrics.main` was 2908309000 nanoAiu, while the one
  `general-purpose` sub-agent it spawned was 375050720000 -- **129x the parent**,
  drawn against the same session cap, which is how a run reaches the soft ceiling
  and stops half-done with every check in `verify.sh` still passing. It also
  defeats the receipt: sub-agent credits land in the same cumulative totals, so
  `USAGE_RUN:` cannot say which agent spent them.

  `--excluded-tools` rather than `--deny-tool`, because the former removes the tool
  from the model's list entirely -- verified live: Copilot prints
  `Disabled tools: task` and `functions.task` is absent from the tools it
  enumerates -- while `--deny-tool` leaves it offered and merely refuses the call,
  spending a turn on a tool that cannot work. The tool name was confirmed by asking
  a live `copilot -p` to enumerate its own registered tools; the sibling
  `read_agent`/`list_agents`/`write_agent` tools only read and write agent
  definitions, so they are left alone. No flag re-enables it -- the point is that
  the unit of work is small.
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

## The AI-credit cap -- and the failure mode it introduces

`dispatch.sh` passes `--max-ai-credits 100` by default. The reasoning is the same
one that makes this plugin exist: a detached run has nobody watching its credit
footer, and the thing being detached is an agentic loop with `--allow-all-tools`.
An unattended default of "no ceiling" is the wrong default. `--max-ai-credits
<n>` raises or lowers it; `off` removes it. Copilot's documented minimum is 30
(`copilot help limits`), and a smaller value is rejected here rather than by
Copilot, where it would surface as a run that died instantly for no stated reason.

**This is the first constraint in the plugin taken from documentation rather than
from a measured run.** The flag exists in CLI 1.0.82 and the minimum is
documented; what has *not* been observed is a real run hitting the ceiling. Read
the rest of this section accordingly.

The cap is documented as **soft**: usage is known only after a model response
returns, so a response can exceed or exhaust the limit before the CLI observes
it, and the *next* model call is what gets blocked. Hidden work such as
compaction counts toward it. Subagents share the parent's limit.

That soft edge introduces a new silent failure, and it is worth naming plainly
because it is the exact shape this plugin was built to catch: **a capped-out run
stops between model calls with its work half-done, and every git check still
passes.** `HEAD_MOVED` sees commits, `EMPTY_COMMITS` finds none, `WORKTREE_CLEAN`
is clean -- and the task is half-finished. No git read can distinguish that from
success, so it is not graded.

What is done instead: `dispatch.sh` passes `--usage-output-file` (always, cap or
no cap) to a path beside the log, and `verify.sh check --usage <file>` reports
it. Reported, never graded -- a session sitting at the cap was cut short, and
that judgement belongs to the caller. The agent receipt carries it as `CREDITS:`
for the same reason.

### The usage file is per SESSION, not per dispatch

MEASURED 2026-09-07, two dispatches sharing one `--session-id`. Both files
carried the same `sessionStartTime`, and the two sub-agent blocks from the first
run appeared byte-identical in the second file -- same `totalNanoAiu`, same
`totalApiDurationMs`. The totals reconcile exactly:

```
30926116000 (sub-agents, carried over) + 5722834000 = 36648950000  <- run 1
30926116000 (same, unchanged)          + 7062438000 = 37988554000  <- run 2
```

So run 2 cost 1339604000 nAIU (1.34 AIU) while its file said 37.99. Printing that
file as "what this run cost" over-reports every resumed run by the whole prior
run -- and `--session-id` reuse is the single biggest saving this plugin
recommends, which puts the misreport exactly where it is most likely to be
believed.

Worse, `codeChanges` is cumulative on the same terms. Run 2 was **read-only**,
and its file still reported `linesAdded 251`, `linesRemoved 202` and five
modified paths -- all of them run 1's. That is a self-report-shaped field in a
file this plugin already parses, i.e. precisely the failure the plugin exists to
prevent, sitting in the plugin's own output.

The fix keeps both numbers rather than picking one, because they answer different
questions and the cap makes both live: the cap Copilot enforces is a **session**
cap, so `USAGE_SESSION:` is what to compare against it, while `USAGE_RUN:` is the
delta that answers "what did this dispatch cost". `dispatch.sh` stages the
session's prior totals as `<usage>.baseline.json` (from a store keyed by session
id under `$FU_COPILOT_STATE`, default `~/.claude/fu-tools/cache/fu-copilot`), and
`verify.sh check --session-id` rolls the store forward once a run has finished --
only a finished run has totals, which is why the write lives there and not in
`dispatch.sh`.

Only monotonic counters are subtracted (`totalNanoAiu`, `totalPremiumRequestCost`,
`totalUserRequests`, `totalApiDurationMs`). `codeChanges` is deliberately **not**
delta'd: `filesModified` is a set, so a file touched by both runs appears once and
no subtraction recovers per-run truth. It is labelled `SESSION-cumulative and NOT
graded` and left to `HEAD_MOVED`/`EMPTY_COMMITS` -- inventing a per-run number
there would be the same "check that lies" the log-grep below is rejected for.

One arithmetic detail worth keeping: the human-readable `aiu` is derived *after*
subtracting, never by subtracting two rounded values -- the latter yields
`1.3400000000000034` where the answer is `1.34`.

Not attempted: grepping the log for an exhaustion message. The documented status
line is `Session limits: 0.5/1 AI credits used.`, which appears on *healthy* runs
at 50/75/90%, so the obvious `session limit` pattern would FAIL passing runs; the
wording Copilot actually prints when the limit is reached has not been observed.
A guessed pattern in `verify.sh` would be a check that lies, which is worse than
a number the caller reads. The JSON *is* now parsed by field name (see above),
but only to separate the session total from the per-run delta and to render nAIU
readably -- never to decide whether the run succeeded. Nothing in it is graded.

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

The AI-credit cap (added 2026-09-02, v0.2.0) is **not** in that table: the flag
and its minimum come from `copilot help limits` on CLI 1.0.82, and no run has
been observed hitting the ceiling. The `--usage-output-file` JSON has never been
seen either, which is why nothing parses it.

Still **not** exercised: the long-run path (10–113 min). Everything here completed
in 10–20 s, so the `--poll`/timeout behaviour under a genuinely long run is
inferred from the code, not observed.

## Tests

Hermetic; `copilot` stubbed on PATH, throwaway `$HOME`, throwaway git fixtures.

```bash
bash plugins/fu-copilot/test/dispatch.test.sh
bash plugins/fu-copilot/test/verify.test.sh
```
