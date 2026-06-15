# /review-prs — Automated PR Review Orchestrator

You are an automated PR review orchestrator. Follow these steps exactly, in order. Do not skip steps.

---

## Step 1 — Lock, setup, detect work

```bash
source /home/fu/.claude/pr-review/lib.sh
pr_review_init
```

- `LOCKED` → **stop**. Another instance is running (lock not held by us).
- `NO_WORK` → **stop**. Lock already released and run logged — do NOT run Step 3.
- One or more `PR_NUM REASON` lines → work queue. Process one at a time in Step 2, then run Step 3.

---

## Step 2 — For each queued PR (sequential)

### Step 2a — Pre-flight

```bash
source /home/fu/.claude/pr-review/lib.sh
pr_review_preflight <PR> <REASON>
```

- `SKIP` → skip this PR, next.
- `PROCEED` line → tab-separated fields: `current_commit`, `current_tree`. Hold these for Step 2c.

### Step 2b — Spawn Task sub-agent

Dispatch a Task sub-agent with this exact prompt (substitute the PR number):

```
Read /home/fu/.claude/pr-review/review-task.md and follow it exactly. Review PR #<PR>.
```

The sub-agent derives its own commit/tree/mode, runs `/code-review`, writes the review body to `state/review-body-<PR>.md`, and emits a `DECISION:` line. It does NOT post to GitHub — Step 2c does.

### Step 2c — Post review, save state, log

After Task completes: find the last line matching `DECISION: APPROVE` or `DECISION: COMMENT`. If none, use `COMMENT`.

```bash
source /home/fu/.claude/pr-review/lib.sh
pr_review_finish <PR> <current_commit> <current_tree> <APPROVE or COMMENT>
```

`pr_review_finish` reads the body file, posts the GitHub Review, and saves state only on a successful post (so a sub-agent that produced no body retries next tick).

---

## Step 3 — Release lock (work path only)

Run this after all queued PRs are processed, even if some failed. Skip it only if Step 1 returned `LOCKED` or `NO_WORK` (those already released the lock).

```bash
source /home/fu/.claude/pr-review/lib.sh
pr_review_cleanup
```
