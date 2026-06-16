---
title: "Orchestrator/sub-agent architecture for a loop-driven PR-review bot"
date: 2026-06-05
category: architecture-patterns
module: "review-prs"
problem_type: architecture_pattern
component: tooling
severity: medium
related_components:
  - development_workflow
applies_when:
  - "Building a long-running Claude Code slash command driven by /loop that delegates work to Task sub-agents"
  - "Per-item sub-agent output would otherwise pollute a shared, long-lived orchestrator context"
  - "A delegated full slash command (e.g. /code-review) tends to end the sub-agent flow before follow-up steps run"
  - "Coordinating concurrency or state handoff across separate Bash tool calls that each spawn a fresh shell"
  - "Keeping a local checkout fresh because a delegated tool reads ambient filesystem context"
tags:
  - claude-code
  - sub-agent
  - orchestration
  - context-isolation
  - pr-review
  - flock-concurrency
  - file-handoff
  - code-review
---

# Orchestrator/sub-agent architecture for a loop-driven PR-review bot

## Context

A working PR-review bot existed the "old way": a cron job that, every few minutes, spawned a fresh `claude -p` headless process to review newly-requested PRs and post a GitHub Review. Fresh process per tick meant each run started with clean context — isolation came for free — but there was no live UI, no shared session, and the bot lived outside the Claude Code session model.

The redesign moves the bot *inside* Claude Code: a `/review-prs` slash command driven on a schedule by `/loop`, delegating the actual review to the `/code-review` plugin command and posting the result as a real GitHub Review. The structure is three files — `commands/review-prs.md` (thin orchestrator), `lib.sh` (all bash helpers), `review-task.md` (sub-agent instructions) — with state and temp files under `state/`.

The friction that shaped every decision below: **`/loop` shares ONE session.** Context accumulates across ticks and across every PR processed within a tick. It is *not* a fresh process per tick the way cron + `claude -p` was. You trade true per-tick isolation for UI visibility — and that trade forces you to engineer the isolation back in by hand, because an orchestrator that reads diffs and findings into its own context will bloat, compact, and grow expensive over a long-running loop.

## Guidance

Ordered highest-leverage first.

1. **In a same-session loop, keep the orchestrator thin and push all heavy/variable content into sub-agents.** The orchestrator's per-tick and per-PR footprint is what accumulates forever in the shared session, so it must approach zero.
   - Review each PR inside its own `Task` sub-agent so diffs, file reads, and findings live and die in the sub-agent's context, never entering the orchestrator.
   - Move all bash out of the command file into a sourced `lib.sh`. The command file should orchestrate, not contain implementation.
   - Put the sub-agent's full instruction template in a static `review-task.md` that the sub-agent *Reads* — the template then lives only in sub-agent context, not in the orchestrator's prompt.
   - Have the sub-agent **self-derive** its own commit SHA, tree SHA, and review mode. The orchestrator passes only the PR number. This dropped per-PR orchestrator cost from ~65 lines to ~1.

2. **Make irreversible / external actions deterministic bash in the orchestrator, not model-driven.** This is the key reliability lesson. `/code-review` is a large command that tends to *end* the sub-agent's flow. In a real run the sub-agent ran `/code-review` (72 tool uses), returned findings, then never posted the GitHub review and emitted no DECISION line — a silent no-op.
   - Reframe the sub-agent's deliverable as "write a body file + emit a DECISION line," with `/code-review` demoted to a mere data-gathering substep. Instruct it explicitly: *do NOT stop after `/code-review`.*
   - The orchestrator reads the body file and posts via `gh api`. The model's job is to *produce content*; the side effect is the orchestrator's job.

3. **Hand off between orchestrator and sub-agent through files, not return-value parsing or piped permissions.**
   - Orchestrator pre-writes prior findings to `state/prior-<pr>.txt`; sub-agent writes the review body to `state/review-body-<pr>.md`.
   - File handoff dodges fragile permission matching — a `gh api | jq | sed` pipeline may not satisfy a `Bash(gh:*)` allowlist, whereas a plain file Read/Write always works.
   - Use a stable dir under `state/`, **not** `/tmp` — `/tmp` gets clobbered by parallel jobs sharing the host.

4. **Hold cross-tool-call locks with a background holder process.** Each Bash tool call is a *new shell*, so a normal fd-based `flock` releases the instant that call returns — giving no mutual exclusion across the orchestrator's separate bash calls. Spawn a background process that holds the lock for the life of the run, store its PID, and kill it at cleanup. Never delete the lock file (deleting it created a TOCTOU race where two ticks flock different inodes).

5. **Know what your delegated tool actually reads before deciding what local state to maintain.** Reading `/code-review`'s own definition revealed that it pulls PR *content* from the GitHub API (`gh pr diff`/`gh pr view`), but its spawned reviewer sub-agents read the *local filesystem* for ambient context (CLAUDE.md, neighbouring code, git blame). So the bot must keep a local checkout and refresh it — pulling **`main`**, not the PR branch (the PR delta comes from `gh`; the base context comes from the tree). Log pull failures; don't `|| true`-swallow them, because a stale tree silently degrades every review.

6. **Save success state only after the external action succeeds, so failures retry.** Persist the reviewed commit/tree SHA *only* on a successful post. A no-body or failed-post run then naturally retries next tick instead of silently marking the PR done.

7. **Make cleanup independent of the agent.** Fold the stale-file purge into `init`, and have `init` self-release the lock on NO_WORK / LOCKED, so the common no-work tick is a single bash call and the run never depends on the agent remembering a final cleanup step. The holder's timeout backstops a skipped release.

8. **Process sequentially when sub-agents share mutable state.** PRs share one checkout dir, so parallel branch operations conflict — process one sub-agent at a time.

9. **Auto-detect identity from cwd.** `REPO_DIR=$(git rev-parse --show-toplevel)`, `REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)`. Run from a dedicated throwaway clone; bail (logged, lock released) if the repo can't be detected. No hardcoded repo means the same bot reviews whatever clone it is launched in.

10. **Choose safe defaults for the side effect.** `DECISION: APPROVE|COMMENT` sentinel on the last line; missing/malformed → COMMENT (the safe default); never `REQUEST_CHANGES` (reserved for humans). Tree-SHA dedup so pure rebases don't re-trigger; re-request detection compares the `review_requested` event timestamp against the state-file mtime. Delta mode reconciles prior findings as RESOLVED / STILL OPEN / REINTRODUCED.

11. **Keep living docs, delete stale ones.** Delete the brainstorm spec/plan once the implementation diverges; keep README + CLAUDE.md as the single source of truth.

## Why This Matters

- **Context bloat (thin orchestrator).** In a shared-session `/loop`, anything the orchestrator reads stays in context across every future tick. Pull diffs and findings into the orchestrator and you march toward compaction and rising per-tick cost on every iteration. Isolation that was free under cron must be deliberately rebuilt.
- **Model-driven external actions (deterministic posting).** The 72-tool-use run that posted nothing is the cautionary tale: a large delegated command can consume the model's "finish the turn" budget, and the genuinely important side effect (the GitHub review) silently never happens. Determinism in bash removes the model's discretion over whether the irreversible step runs.
- **fd-flock (background holder).** Without a holder process, the "lock" releases the moment each bash call returns, so two overlapping ticks both think they hold it — no real mutual exclusion, concurrent checkouts corrupting the shared tree.
- **Swallowed pull failure (logged, not `|| true`).** A `|| true`'d pull leaves a stale local tree. Since `/code-review`'s reviewers read that tree for ambient context, every subsequent review is quietly degraded with no error anywhere — the worst kind of failure, invisible.
- **State-before-success.** Saving the reviewed SHA before a confirmed post means a failed/empty run marks the PR done anyway and never retries — a permanent silent miss.

## When to Apply

Designing any long-running `/loop`-driven Claude Code automation that:
- runs in a **shared session** and therefore accumulates context across ticks;
- **fans work into sub-agents** to bound per-item context;
- **delegates to another slash command** (especially a large one that may end the sub-agent's flow);
- performs **external side effects** (posting reviews, comments, API writes) that must not silently no-op;
- needs **concurrency control across multiple tool calls** (where fd-based flock won't survive).

## Examples

### Cross-call lock: fd-flock vs. background holder

```bash
# BEFORE — releases the instant this bash call returns; the next tick's
# bash call is a brand-new shell, so there is no mutual exclusion at all.
flock -n 9 9>"$LOCK_FILE" || exit 1
# ... orchestrator continues in *separate* bash calls; lock already gone ...

# AFTER — a background holder keeps the lock alive across every separate
# bash call for the life of the run. Store the PID; kill it at cleanup.
( flock -n 9 || exit 1; sleep 7200 ) 9>"$LOCK_FILE" &
HOLDER_PID=$!
echo "$HOLDER_PID" > "$BASE_DIR/review-prs.lock.holder"
# The 7200s sleep is a timeout backstop. Never rm the lock file
# (deleting it races two ticks onto different inodes).
```

### File handoff + deterministic post

```bash
# Orchestrator pre-writes prior findings for the sub-agent to read.
fetch_prior_findings "$PR" > "$STATE_DIR/prior-${PR}.txt"

# The sub-agent runs /code-review as a data-gathering substep, then MUST:
#   - write the review body to state/review-body-<pr>.md
#   - emit a final line: DECISION: APPROVE | DECISION: COMMENT
# (Instruction to sub-agent: "do NOT stop after /code-review.")

# Orchestrator posts — deterministically, in bash, NOT the model.
body_file="$STATE_DIR/review-body-${PR}.md"
if [ -s "$body_file" ]; then
    body="$REVIEW_MARKER
$(cat "$body_file")"
    if gh api "repos/$REPO/pulls/$PR/reviews" --method POST \
            -f "event=$decision" -f "body=$body" >/dev/null 2>&1; then
        save_review_state "$PR" "$commit" "$tree"   # save ONLY on a successful post
    else
        log "PR #$PR: post failed — NOT saving state (retries next tick)"
    fi
else
    log "PR #$PR: no review body produced — NOT posting, NOT saving state"
fi
# No body / failed post -> state NOT saved -> retried next tick (no silent pass).
```

### Auto-detect identity from cwd

```bash
# Run from a dedicated throwaway clone; derive identity from the checkout.
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [ -z "$REPO" ]; then
    log "ERROR: could not detect target repo from $PWD — run from inside the review clone"
    pr_review_release_lock           # log + release, don't hang the loop
    return 0
fi

# Refresh the ambient context that /code-review's reviewer sub-agents read
# from the LOCAL tree. Pull main (not the PR branch); LOG failures.
git_err=$(git -C "$REPO_DIR" pull origin main --quiet 2>&1) \
    || log "WARNING: 'git pull origin main' failed in $REPO_DIR: $git_err"
```

## Related

- This repo's `README.md`, `CLAUDE.md`, `review-task.md`, `commands/review-prs.md`, and `lib.sh` are the authoritative implementation of this pattern.
- No prior `docs/solutions/` entries — this is the first knowledge-store doc in this repo.
