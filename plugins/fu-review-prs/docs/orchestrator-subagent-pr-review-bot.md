---
title: "Orchestrator/sub-agent architecture for a loop-driven PR-review bot"
date: 2026-06-05
updated: 2026-06-17
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
  - per-repo-isolation
---

# Orchestrator/sub-agent architecture for a loop-driven PR-review bot

## Context

A working PR-review bot existed the "old way": a cron job that, every few minutes, spawned a fresh `claude -p` headless process to review newly-requested PRs and post a GitHub Review. Fresh process per tick meant each run started with clean context — isolation came for free — but there was no live UI, no shared session, and the bot lived outside the Claude Code session model.

The redesign moves the bot *inside* Claude Code: a `/review-prs` slash command driven on a schedule by `/loop`, delegating the actual review to the `/code-review` plugin command and posting the result as a real GitHub Review. The structure is three files — `commands/review-prs.md` (thin orchestrator), `scripts/lib.sh` (all bash helpers), `review-task.md` (sub-agent instructions). These ship together as the `fu-review-prs` plugin and resolve via `${CLAUDE_PLUGIN_ROOT}`; mutable runtime state (locks, logs, per-PR state) lives OUTSIDE the plugin under `~/.claude/pr-review/`, since the plugin cache is wiped on reinstall.

> Update (2026-06-17): originally a standalone repo; now packaged as the `fu-review-prs` plugin, and lock/log/state are namespaced per repo (see guidance #12) so concurrent loops on different remotes don't collide.

The friction that shaped every decision below: **`/loop` shares ONE session.** Context accumulates across ticks and across every PR processed within a tick. It is *not* a fresh process per tick the way cron + `claude -p` was. You trade true per-tick isolation for UI visibility — and that trade forces you to engineer the isolation back in by hand, because an orchestrator that reads diffs and findings into its own context will bloat, compact, and grow expensive over a long-running loop.

## Guidance

Ordered highest-leverage first.

1. **In a same-session loop, keep the orchestrator thin and push all heavy/variable content into sub-agents.** The orchestrator's per-tick and per-PR footprint is what accumulates forever in the shared session, so it must approach zero.
   - Review each PR inside its own `Task` sub-agent so diffs, file reads, and findings live and die in the sub-agent's context, never entering the orchestrator.
   - Move all bash out of the command file into a sourced `lib.sh`. The command file should orchestrate, not contain implementation.
   - Put the sub-agent's full instruction template in a static `review-task.md` that the sub-agent *Reads* — the template then lives only in sub-agent context, not in the orchestrator's prompt.
   - Have the sub-agent **self-derive** its own commit SHA, tree SHA, and review mode. The orchestrator passes only the PR number plus the per-repo absolute state paths the sub-agent can't safely reconstruct (see #12). This dropped per-PR orchestrator cost from ~65 lines to ~1.

2. **Make irreversible / external actions deterministic bash in the orchestrator, not model-driven.** This is the key reliability lesson. `/code-review` is a large command that tends to *end* the sub-agent's flow. In a real run the sub-agent ran `/code-review` (72 tool uses), returned findings, then never posted the GitHub review and emitted no DECISION line — a silent no-op.
   - Reframe the sub-agent's deliverable as "write a body file + emit a DECISION line," with `/code-review` demoted to a mere data-gathering substep. Instruct it explicitly: *do NOT stop after `/code-review`.*
   - The orchestrator reads the body file and posts via `gh api`. The model's job is to *produce content*; the side effect is the orchestrator's job.

3. **Hand off between orchestrator and sub-agent through files, not return-value parsing or piped permissions.**
   - Orchestrator pre-writes prior findings to `state/prior-<pr>.txt`; sub-agent writes the review body to `state/review-body-<pr>.md`.
   - File handoff dodges fragile permission matching — a `gh api | jq | sed` pipeline may not satisfy a `Bash(gh:*)` allowlist, whereas a plain file Read/Write always works.
   - Use a stable dir under `state/`, **not** `/tmp` — `/tmp` gets clobbered by parallel jobs sharing the host.
   - This applies to **every** value the post step needs, not just the body — see guidance #14: parsing the decision/commit/tree out of the model's context is the same fragility, one compaction away from breaking.

4. **Hold cross-tool-call locks with a background holder process.** Each Bash tool call is a *new shell*, so a normal fd-based `flock` releases the instant that call returns — giving no mutual exclusion across the orchestrator's separate bash calls. Spawn a background process that holds the lock for the life of the run, store its PID, and kill it at cleanup. Never delete the lock file (deleting it created a TOCTOU race where two ticks flock different inodes).

5. **Know what your delegated tool actually reads before deciding what local state to maintain.** Reading `/code-review`'s own definition revealed that it pulls PR *content* from the GitHub API (`gh pr diff`/`gh pr view`), but its spawned reviewer sub-agents read the *local filesystem* for ambient context (CLAUDE.md, neighbouring code, git blame). So the bot must keep a local checkout and refresh it to **`main`**, not the PR branch (the PR delta comes from `gh`; the base context comes from the tree). Log refresh failures; don't `|| true`-swallow them, because a stale tree silently degrades every review. (How to refresh robustly → guidance #13.)

6. **Save success state only after the external action succeeds, so failures retry.** Persist the reviewed commit/tree SHA *only* on a successful post. A no-body or failed-post run then naturally retries next tick instead of silently marking the PR done.

7. **Make cleanup independent of the agent.** Fold the stale-file purge into `init`, and have `init` self-release the lock on NO_WORK / LOCKED, so the common no-work tick is a single bash call and the run never depends on the agent remembering a final cleanup step. The holder's timeout backstops a skipped release.

8. **Process sequentially when sub-agents share mutable state.** PRs share one checkout dir, so parallel branch operations conflict — process one sub-agent at a time.

9. **Auto-detect identity from cwd.** `REPO_DIR=$(git rev-parse --show-toplevel)`, `REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)`. Run from a dedicated throwaway clone; bail (logged, lock released) if the repo can't be detected. No hardcoded repo means the same bot reviews whatever clone it is launched in.

10. **Choose safe defaults for the side effect.** `DECISION: APPROVE|COMMENT` sentinel on the last line; missing/malformed → COMMENT (the safe default); never `REQUEST_CHANGES` (reserved for humans). Tree-SHA dedup so pure rebases don't re-trigger; re-request detection compares the `review_requested` event timestamp against the state-file mtime. Delta mode reconciles prior findings as RESOLVED / STILL OPEN / REINTRODUCED.

11. **Keep living docs, delete stale ones.** Delete the brainstorm spec/plan once the implementation diverges; keep the plugin README + this doc as the single source of truth, and revise them when the design moves (as this doc was when the bot became a plugin and gained per-repo namespacing).

12. **Namespace per-repo identity in every shared path.** The first design used one lock and flat, PR-number-keyed state (`review-prs.lock`, `state/prior-<pr>.txt`). The moment you run the bot against more than one remote — one `/loop` per clone — those collide: the single lock serialises unrelated repos, and `owner-a/repo` PR #5 clobbers `owner-b/repo` PR #5's tree-SHA/findings/body. Derive a slug from the repo (`owner/name` → `owner-name`) and fold it into the lock, holder, log, and a `state/<slug>/` subdir. Because the slug comes from cwd (`gh repo view`) and the sub-agent runs in its own context, the orchestrator must **resolve the namespaced paths and inject them** into the sub-agent prompt — the sub-agent must not rebuild them from the bare PR number, or it writes to the wrong (flat) location and the orchestrator's read silently finds nothing.

13. **Force-reset the throwaway clone; never `pull`.** The review clone is disposable, and the sub-agent's `gh pr checkout <PR>` leaves it on the PR branch — files the PR *added* are then stranded as untracked when you return to `main`, and a plain `git checkout main` aborts on the dirty tree, silently degrading the baseline. Refresh by making the tree match the remote *exactly*: `git fetch origin main` → `git checkout -f main` → `git reset --hard origin/main` → `git clean -fd`. Use `reset --hard`, not `pull`: `pull` is a merge that can create a merge commit or abort on a force-pushed/rewritten remote `main`, whereas hard-reset is immune to local divergence and history rewrites. Omit `-x` from `clean` so gitignored build caches (`bin/obj`, `node_modules`) survive — only stray untracked source and tracked mods get wiped. Run it both at tick start *and* after each PR, so sequential sub-agents never inherit the prior PR's branch.

14. **Persist every cross-step value to disk, so a mid-tick compaction loses nothing.** In a same-session loop the orchestrator's context grows across ticks and *will* eventually compact — possibly right after a sub-agent returns, before the post step runs. Any value carried in context across that boundary is at risk. The original design carried three: the `DECISION` (parsed from the sub-agent's reply) and the `commit`/`tree` (printed by pre-flight, "held" by the model for the post call). Move all three to disk: pre-flight writes `pending-<pr>` (commit + tree); the sub-agent writes its decision to a `decision-<pr>.txt` sidecar **and** as a `<!-- DECISION: X -->` header on the body's first line (belt-and-suspenders); `pr_review_finish <pr>` then takes **only the PR number** and recovers commit/tree/decision/body entirely from disk. The post step becomes reconstructable from disk alone, so a compaction between pre-flight and post is a no-op. Pre-flight also clears the prior tick's body/decision before dispatch so a half-finished earlier run can't leave a stale decision to be read; decision resolution is sidecar → header → `COMMENT` (the safe default from #10). Combined with #6 (state saved only on a successful post), the worst case degrades to a redundant re-review next tick — never a lost or wrong post.

## Why This Matters

- **Context bloat (thin orchestrator).** In a shared-session `/loop`, anything the orchestrator reads stays in context across every future tick. Pull diffs and findings into the orchestrator and you march toward compaction and rising per-tick cost on every iteration. Isolation that was free under cron must be deliberately rebuilt.
- **Model-driven external actions (deterministic posting).** The 72-tool-use run that posted nothing is the cautionary tale: a large delegated command can consume the model's "finish the turn" budget, and the genuinely important side effect (the GitHub review) silently never happens. Determinism in bash removes the model's discretion over whether the irreversible step runs.
- **fd-flock (background holder).** Without a holder process, the "lock" releases the moment each bash call returns, so two overlapping ticks both think they hold it — no real mutual exclusion, concurrent checkouts corrupting the shared tree.
- **Swallowed pull failure (logged, not `|| true`).** A `|| true`'d pull leaves a stale local tree. Since `/code-review`'s reviewers read that tree for ambient context, every subsequent review is quietly degraded with no error anywhere — the worst kind of failure, invisible.
- **State-before-success.** Saving the reviewed SHA before a confirmed post means a failed/empty run marks the PR done anyway and never retries — a permanent silent miss.
- **Per-repo namespacing.** A single global lock + flat PR-number-keyed state looks fine with one repo and breaks the instant a second loop starts: unrelated remotes serialise on one lock, and identical PR numbers across repos overwrite each other's review state. The failure is silent — a real review skipped because another repo's PR #5 already "claimed" the slot.

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
# LOCK_FILE / HOLDER_FILE are namespaced per repo (see #12), e.g.
#   LOCK_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock"
( flock -n 9 || exit 1; sleep 7200 ) 9>"$LOCK_FILE" &
HOLDER_PID=$!
echo "$HOLDER_PID" > "$HOLDER_FILE"
# The 7200s sleep is a timeout backstop. Never rm the lock file
# (deleting it races two ticks onto different inodes).
```

### File handoff + deterministic post

```bash
# STATE_DIR is namespaced per repo (see #12): "$BASE_DIR/state/$REPO_SLUG".
# Pre-flight: pre-write prior findings AND persist the reviewed commit/tree to
# disk (pending-<pr>), so the post step never needs them from context (see #14).
fetch_prior_findings "$PR" > "$STATE_DIR/prior-${PR}.txt"
rm -f "$STATE_DIR/review-body-${PR}.md" "$STATE_DIR/decision-${PR}.txt"  # clear stale
write_pending "$PR" "$commit" "$tree"

# The sub-agent runs /code-review as a data-gathering substep, then MUST write to
# the paths passed to it (it must NOT rebuild flat paths from the bare PR number):
#   - BODY_FILE: a "<!-- DECISION: X -->" header line, then the review body
#   - DECISION_FILE: the bare APPROVE|COMMENT token (authoritative; header is backup)
# (Instruction to sub-agent: "do NOT stop after /code-review.")

# Orchestrator posts — deterministically, in bash, NOT the model. Takes ONLY $PR;
# everything else is read from disk, so a compaction after the sub-agent returns
# loses nothing.
pr_review_finish "$PR"
#   - body from review-body-<pr>.md (header line stripped before posting)
#   - decision from decision-<pr>.txt -> body header -> COMMENT (#10 safe default)
#   - commit/tree from pending-<pr> (re-derived from live head only if missing)
#   - save_review_state ONLY on a successful post (#6) -> failures retry next tick
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

- Authoritative implementation: the `fu-review-prs` plugin in the `fu-claude-plugins` marketplace — `commands/review-prs.md` (orchestrator), `scripts/lib.sh` (helpers), `review-task.md` (sub-agent spec), and the plugin `README.md`. Resolved via `${CLAUDE_PLUGIN_ROOT}`; runtime state under `~/.claude/pr-review/`.
- Originally lived in a standalone `pr-review-bot` repo (now deleted); this doc was rescued and updated when the bot was folded into the plugin.
