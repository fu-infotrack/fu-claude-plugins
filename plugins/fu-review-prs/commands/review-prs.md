---
description: One tick of the automated PR-review loop for the current repo (auto-detected from cwd) — locks, finds PRs needing review, dispatches a sub-agent per PR, posts the GitHub review. Run via /loop from inside the review clone.
---

# /review-prs — Automated PR Review Orchestrator

You are an automated PR review orchestrator. Follow these steps exactly, in order. Do not skip steps.

---

## Step 1 — Lock, setup, detect work

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_init
```

- `LOCKED` → **stop**. Another instance is running (lock not held by us).
- `NO_WORK` → **stop**. Lock already released and run logged — do NOT run Step 3.
- One or more `PR_NUM REASON` lines → work queue. Process one at a time in Step 2, then run Step 3.

---

## Step 2 — For each queued PR (sequential)

### Step 2a — Pre-flight

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_preflight <PR> <REASON>
```

- `SKIP` → skip this PR, next.
- `PROCEED` line → tab-separated fields: `current_commit`, `current_tree`. Hold these for Step 2c.

### Step 2b — Spawn Task sub-agent

Resolve the task-file path and this PR's namespaced state paths:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
echo "TASK_FILE=$REVIEW_TASK_FILE"
pr_review_paths <PR>
```

Dispatch a Task sub-agent. Use this prompt, substituting the PR number and the four absolute paths just printed (`TASK_FILE`, `STATE_FILE`, `PRIOR_FILE`, `BODY_FILE`):

```
Read <TASK_FILE> and follow it exactly. Review PR #<PR>.
Use these absolute paths verbatim — do not construct your own:
  STATE_FILE = <STATE_FILE>
  PRIOR_FILE = <PRIOR_FILE>
  BODY_FILE  = <BODY_FILE>
```

The sub-agent derives its own commit/tree/mode, runs `/code-review`, writes the review body to `BODY_FILE`, and emits a `DECISION:` line. It does NOT post to GitHub — Step 2c does.

### Step 2c — Post review, save state, log

After Task completes: find the last line matching `DECISION: APPROVE` or `DECISION: COMMENT`. If none, use `COMMENT`.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_finish <PR> <current_commit> <current_tree> <APPROVE or COMMENT>
```

`pr_review_finish` reads the body file, posts the GitHub Review, and saves state only on a successful post (so a sub-agent that produced no body retries next tick).

---

## Step 3 — Release lock (work path only)

Run this after all queued PRs are processed, even if some failed. Skip it only if Step 1 returned `LOCKED` or `NO_WORK` (those already released the lock).

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_cleanup
```
