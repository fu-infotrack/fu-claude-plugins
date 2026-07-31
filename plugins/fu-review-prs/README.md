# fu-review-prs

Automated PR-review orchestrator. One `/review-prs` tick finds open PRs that
need your review on the current repo, dispatches a Task sub-agent per PR (which
runs `/code-review` and writes a review body), and posts a formal GitHub review.
Run it on an interval with `/loop` from inside a dedicated review clone.

```
cd <review-clone> && claude
/loop 30m /review-prs
```

The target repo is **auto-detected from cwd** (`gh repo view`), so run from
inside the clone. `gh` must be authenticated for that repo.

## Posting policy — COMMENT by default

Every review posts as a GitHub `COMMENT`, **including** reviews that found zero
BLOCKERs (the body then notes that no blockers were found). An `APPROVE` is a
durable, outward-facing signal that can satisfy branch protection and unblock a
merge, so it has to be asked for:

```
/loop 30m /review-prs --auto-approve    # clean PRs get an APPROVE
/loop 30m /review-prs                   # default: comment-only
```

`REQUEST_CHANGES` is never posted — it stays reserved for humans.

Mechanically: the sub-agent's `APPROVE` only means "zero BLOCKERs". `pr_review_init`
records the tick's mode to `state/<slug>/auto-approve`, and `pr_review_finish`
downgrades `APPROVE` → `COMMENT` when that file is absent. The mode lives on disk
for the same reason the decision does — a mid-tick compaction can't flip it — and is
cleared at cleanup so it never leaks into a later tick. `PR_REVIEW_AUTO_APPROVE=1`
is an equivalent env seam (used by the tests).

## Code vs. state

- **Code** ships in the plugin: `scripts/lib.sh` (orchestrator helpers) and
  `review-task.md` (sub-agent instructions). The command sources them via
  `${CLAUDE_PLUGIN_ROOT}`.
- **Mutable runtime state** lives under `~/.claude/pr-review/` — locks, logs,
  and per-PR state. It is kept OUTSIDE the plugin because the plugin cache is
  wiped and recopied on every reinstall.

## Per-repo isolation

Lock, log, and state are namespaced by a repo slug (`owner/name` → `owner-name`),
so loops on different remotes run concurrently without contending on one lock,
and PR-number-keyed state never collides across repos:

```
~/.claude/pr-review/
  review-prs-<slug>.lock          # flock target, one per repo
  review-prs-<slug>.lock.holder   # holder PID
  review-<slug>.log
  state/<slug>/last-reviewed-<PR> # commit+tree of last review
  state/<slug>/prior-<PR>.txt     # prior findings (delta mode)
  state/<slug>/review-body-<PR>.md
  state/<slug>/auto-approve       # present only while a --auto-approve tick runs
```

The orchestrator resolves these via `pr_review_paths <PR>` and injects the
absolute paths into the sub-agent prompt — the sub-agent never builds its own.

## Pieces

- `commands/review-prs.md` — the per-tick orchestrator (context-thin).
- `scripts/lib.sh` — lock/setup/detect/finish helpers; sourced per Bash call.
- `review-task.md` — sub-agent spec: derive mode, read PR/linked-issue intent,
  run `/code-review`, scope-check the diff against the intent, write body, emit a
  `DECISION:` line. Posts nothing itself.
- `test/auto-approve.test.sh` — the posting-policy contract (hermetic: throwaway
  `HOME`, stubbed `gh`/`git`). Run `bash plugins/fu-review-prs/test/auto-approve.test.sh`.
