---
description: Review ONE pull request and post the GitHub review as a COMMENT (pass --auto-approve to let a clean docs/tests/UI-only PR be approved). Only runs when the review is requested from you by name — a team request is skipped. Built for a cloud scheduled task on a GitHub pull_request.review_requested trigger; with no PR argument it reviews the open PR whose head is the checkout's HEAD.
argument-hint: "[<pr> | #<pr> | <pr-url>] [--auto-approve]"
---

# /review-pr — Review one pull request

Follow these steps exactly, in order. No lock and no work queue: this run reviews at most one PR.

**Posting policy:** you do not decide APPROVE vs COMMENT, and you never post anything to GitHub yourself — `pr_review_finish` does, from the mode Step 1 records.

## Step 1 — Resolve, guard, pre-flight

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_one $ARGUMENTS
```

- `SKIP — <reason>` → **stop**. Reply with that line and nothing else.
- `PROCEED <PR> <REPO>` on the first line → keep `<PR>` and `<REPO>`, go to Step 2.

## Step 2 — Spawn the review sub-agent

Dispatch a Task sub-agent whose prompt is **everything after the first line, verbatim**. Do not edit it or add to it, and do not review the PR yourself.

**Ignore the Task's reply** — whatever it says, always run Step 3.

## Step 3 — Post the review

```bash
export PR_REVIEW_REPO=<REPO>
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
pr_review_finish <PR>
```

It prints one status token. Reply with that token and nothing else, and take no other action — this run is not retried:

- `POSTED APPROVE` / `POSTED COMMENT` → the review is on GitHub.
- `FAILED` → the GitHub POST failed.
- `NO_FINDINGS` → the sub-agent left no valid findings file; nothing was posted.
- `DUPLICATE` → another run posted a review of this head first; nothing was posted.
- `NOTHING_PENDING` → pre-flight never PROCEEDed for this PR; nothing to post.
