---
name: copilot
description: Use when delegating a coding task to GitHub Copilot CLI — dispatch a detached run, wait on it, and verify what it actually did from git rather than from its summary. Triggers — "hand this to copilot", "get copilot to implement", "second opinion from copilot", "copilot run failed", "did copilot actually change anything".
disable-model-invocation: true
---

# Delegating to GitHub Copilot CLI

Two scripts. `dispatch.sh` launches a detached run and prints a handle; `verify.sh`
waits on it and checks what happened. **You** write the brief and read the verdict.

```bash
S="${CLAUDE_PLUGIN_ROOT}/scripts"
```

## 1. Write the brief to /tmp

**Not under `~/.claude`.** Copilot CLI cannot read anything there — every read
returns `Permission denied and could not request permission from user` — and it
fails *silently*: a run that could not read its brief inferred there was nothing
to do and did a no-op force-push while reporting success. `dispatch.sh` refuses
such a path rather than letting that recur.

> **If you are a background job**, your harness instructions tell you to put
> temporary files in `$CLAUDE_JOB_DIR/tmp` — which is `~/.claude/jobs/<id>/tmp`,
> exactly the location `dispatch.sh` refuses. The two rules collide; `/tmp` wins
> for the brief. Logs there are fine (the shell writes those, not Copilot).

```bash
brief=/tmp/copilot-brief-$$.md
cat > "$brief" <<'EOF'
...what to do, which files, what "done" means...

## Finish
- Commit with messages saying why. Do not create a PR.
- `/implement` ends with `/code-review`; that skill is not installed here. Skip it.
EOF
```

Write the brief yourself and pass it through unchanged. It is a contract, not a
draft — if a sub-agent retypes it, the precise part (the output contract) is the
part that gets reworded.

You do not need to tell Copilot where its brief lives: `dispatch.sh` appends a
footer to the *staged copy* naming the absolute path, which the caller cannot do
because this script chooses the mktemp name. Measured as a two-run A/B — a brief
saying only "a copy is staged by the dispatcher" sent Copilot to a repo-scoped
`glob **/*brief*` that found nothing; a brief naming the path had it read the
file as its second action. Your own file is never modified.

## 2. Dispatch

```bash
"$S/dispatch.sh" --brief "$brief" --cwd /path/to/worktree --log /tmp/copilot-run.log
```

Prints `PID`, `BRIEF` (the staged /tmp copy — worth naming in the brief as a
re-readable copy), `LOG`, `USAGE_FILE`, `SESSION_ID`, `USAGE_BASELINE`,
`BASELINE_HEAD`, `BRIEF_REACHED_PROCESS`. Keep `PID`, `BASELINE_HEAD`,
`USAGE_FILE` and `SESSION_ID`.

A non-zero exit means the brief did **not** reach the process — kill the PID and
investigate rather than waiting on it.

Optional: `--model`, `--context long_context`, `--dry-run`, `--max-ai-credits
<n|off>`, `--allow-subagents`, and `--session-id <uuid>`. Pass the *same* `--session-id` again to
continue that Copilot session instead of restarting: Copilot keeps its own
context, so a follow-up costs a short prompt rather than a re-sent brief.

Generate the id with `cat /proc/sys/kernel/random/uuid` — **`uuidgen` is not
installed here.** An empty value is rejected rather than ignored, so
`--session-id "$SID"` with `SID` unset fails loudly instead of silently
starting a fresh session.

Thread `SESSION_ID` into `verify.sh check --session-id` at the end of every run.
Copilot's usage JSON is **cumulative for the session**, not per dispatch, so
that is what lets the *next* resumed run report its own cost instead of the
whole session's. See the credit cap below.

### The credit cap

A **100 AI-credit** session cap is passed by default. Nobody is watching the
credit footer of a detached run, and a runaway agentic loop is exactly the kind
of thing this plugin dispatches. Raise it for a big task, or `--max-ai-credits
off` to remove it. Copilot's documented minimum is 30 (`copilot help limits`);
`dispatch.sh` rejects less, since Copilot would otherwise die instantly for no
visible reason.

The cap is a **soft** cap by Copilot's own account: usage is known only after a
response returns, so a response can exceed the limit and the *next* model call
is what gets blocked. Consequence worth internalising — **a capped-out run stops
between model calls with its work half-done and every git check still passing.**
Read `USAGE_SESSION:` against the cap before believing `CHECKS: pass`.

**The cap is a session cap, and so is the usage file.** Measured 2026-09-07
across two dispatches sharing one `--session-id`: both usage files carried the
same `sessionStartTime` and byte-identical `agentMetrics` blocks for the first
run's sub-agents, and the second file's `totalNanoAiu` was the first's plus only
that run's own. So there are two different numbers and they answer different
questions:

| Line | Means | Use it for |
|---|---|---|
| `USAGE_SESSION:` | the whole Copilot session so far | comparing against `--max-ai-credits` |
| `USAGE_RUN:` | this dispatch alone (baseline subtracted) | "what did this run cost" |

`USAGE_RUN:` appears only when `dispatch.sh` had a stored baseline, i.e. on the
second and later dispatch of a session that `verify.sh --session-id` recorded.

`USAGE_CHANGES:` is cumulative too and is **not graded** — a resumed read-only
run still reports the prior run's modified files. It is printed as context, not
evidence; `HEAD_MOVED` and `EMPTY_COMMITS` are the authority on what changed.

## 3. Wait

```bash
"$S/verify.sh" wait <PID> --poll 30    # run this with run_in_background
```

Runs take **10–113 minutes**; the Bash tool caps `timeout` at 600 s, so never run
Copilot in the foreground. `wait` uses `kill -0`, never a `pgrep -f 'copilot -p'`
pattern — parallel runs across worktrees match each other's patterns.

## 4. Verify — do not trust the summary

```bash
"$S/verify.sh" check --cwd /path/to/worktree \
  --baseline "$BASELINE_HEAD" --range "$BASELINE_HEAD..HEAD" \
  --lossless-from <pre-state-sha> --log /tmp/copilot-run.log \
  --usage /tmp/copilot-run.usage.json --session-id "$SESSION_ID"
```

Exits non-zero if any check FAILed. Checks: `HEAD_MOVED` (did anything happen at
all — the headline), `EMPTY_COMMITS`, `LOSSLESS` (and it says so when the check is
*vacuous* because HEAD never moved), `WORKTREE_CLEAN`, `LOG_PERMISSION` (a denial
is BLOCKING — Copilot proceeds on a guess). Skipped checks print `SKIP`, never
`PASS`.

`--usage` (the `USAGE_FILE` dispatch printed) adds `USAGE_SESSION:` and, on a
resumed run, `USAGE_RUN:` — see the table above for which answers what. Both are
**reported, never graded**: a session sitting at the cap was cut short, and no
git check can tell you that.

`--session-id` (the `SESSION_ID` dispatch printed) records this run's totals so
the next dispatch of the same session can report its own cost. Omitting it costs
nothing today but leaves the *next* resumed run over-reporting by everything
spent so far.

Then read the log for detail — bounded, e.g. `tail -c 4000 "$log"` — not the whole
file, and not in place of the checks.

## Iterating

Review the outcome yourself, then dispatch again with a new brief (or the same
`--session-id`) naming what to fix. Copilot does not review its own work here.
For a Claude-side review, run `/code-review:code-review low` as a sub-agent so
its findings do not land in your context wholesale.

## Notes

- `--excluded-tools task` is always passed, so Copilot cannot spawn its own
  sub-agents. A dispatch is one scoped brief; measured on a real run, the main
  agent spent 2.9 AIU while a single `general-purpose` sub-agent it spawned spent
  375 — 129x — against the same session cap, and sub-agent credits are
  indistinguishable in the usage JSON, so `USAGE_RUN:` cannot attribute them.
  Pass `--allow-subagents` when the brief genuinely wants fan-out — it is opt-in
  rather than opt-out because nobody watches a detached run's credit footer.
- `--allow-all-tools` is always passed — without it Copilot prompts for tool
  permission and hangs non-interactively. `--allow-all-paths` and
  `dangerouslyDisableSandbox` are deliberately never passed.
- `-s/--silent` is deliberately not passed: it suppresses the stats line that
  carries the `copilot --resume=<uuid>` handle, which `verify.sh` surfaces.
- `--no-color` is always passed, but note it does **not** clean the log: measured
  against a real run, the stats footer still emits raw ANSI escapes. Grep patterns
  must tolerate them (`verify.sh`'s resume extraction does).
