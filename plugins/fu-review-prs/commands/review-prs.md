---
disable-model-invocation: true
description: One tick of the automated PR-review loop for the current repo (auto-detected from cwd) — locks, finds PRs needing review, dispatches a sub-agent per PR, posts the GitHub review as a COMMENT (pass --auto-approve to let clean PRs be approved). Run via /loop from inside the review clone.
argument-hint: [--auto-approve]
---

# /review-prs — Automated PR Review Orchestrator

Follow these steps exactly, in order. Every value that crosses a step lives on disk, so carry nothing in context beyond the work queue.

**Posting policy:** you do not decide APPROVE vs COMMENT — `pr_review_finish` enforces it from the flag Step 1 records.

## Step 1 — Lock, setup, detect work

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_init $ARGUMENTS
```

- `LOCKED` → **stop**. Another instance holds the lock.
- `NO_WORK` → **stop**. Lock already released — do NOT run Step 3.
- One or more `PR_NUM REASON` lines → work queue. Process each in Step 2, then run Step 3.

## Step 2 — For each queued PR (sequential)

### 2a — Pre-flight

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_preflight <PR> <REASON>
```

- `SKIP` → next PR.
- `PROCEED` on the first line → go to 2b.

### 2b — Spawn Task sub-agent

Dispatch a Task sub-agent whose prompt is **everything after the `PROCEED` line, verbatim**. Do not edit it or add to it.

**Ignore the Task's reply** — whatever it says, always run 2c.

### 2c — Post review, save state

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_finish <PR>
```

## Step 3 — Release lock (work path only)

Run after all queued PRs, even if some failed. Skip only if Step 1 returned `LOCKED` or `NO_WORK`.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_cleanup
```
