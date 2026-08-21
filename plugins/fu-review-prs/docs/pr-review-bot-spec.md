---
title: "Portable specification for an LLM-driven PR-review bot"
version: 1.0
date: 2026-07-31
status: stable
applies_to: "any OS, any implementation language, any code-review forge"
derived_from: "fu-review-prs (bash + Claude Code reference implementation)"
---

# Portable specification — LLM-driven PR-review bot

A conformance spec for a bot that watches a code-hosting platform for review
requests aimed at its own identity, has an LLM agent review each requested
change, and posts the result back as a review — **exactly once per distinct
content state**, with no silent misses.

This document is deliberately free of any OS, language, shell, forge, or
agent-runtime dependency. Every such dependency is isolated behind a **port**
(§6), and each port has one or more **bindings** (§10). The requirements in §7
are the design's actual content: they are the failure modes a working
implementation had to survive, stated as testable rules.

## 0. How to read this

- **MUST / MUST NOT / SHOULD / MAY** are used in the RFC 2119 sense.
- **Core profile** — R1–R26. A conforming bot implements all of them.
- **Extended profile** — R27–R32 (notifications, delta review, scope check, blocker counting).
  Optional, but if implemented, must be implemented as specified.
- Every requirement carries a **failure mode**: what breaks, *silently*, when
  it is skipped. The failure modes are the reason the rule exists; a reviewer
  of an implementation should be able to check the rule by provoking the mode.
- Code in this document is pseudocode. It is not any real language, and the
  absence of error handling in it is not permission to omit error handling.

## 1. Scope

### In scope

A single-tenant, single-repository review bot with this loop:

1. Ask the forge which open changes have a review requested from **this bot's
   own identity**.
2. Decide which of those are *unreviewed at their current content state*.
3. For each, run an LLM review in an isolated context and collect its findings.
4. Post one review per change, with a deterministic decision (comment by
   default; approval only when explicitly enabled for that run).
5. Persist enough state that a crash, restart, or context loss anywhere in the
   loop degrades to *a redundant re-review*, never to a lost or wrong post.

### Out of scope (non-goals)

- **Review quality / prompt engineering.** The spec fixes only the finding
  *contract* (severity taxonomy, decision derivation, body shape). What makes a
  good finding is the agent's business.
- **Merging, CI orchestration, branch protection administration.**
- **Multi-repository scheduling.** One bot instance serves one repository; run
  N instances for N repositories. The spec's namespacing rules (R17) exist
  precisely so N instances can share one host and one state root safely.
- **Authoring code fixes.** The reviewer is read-only (R25).

### Portability targets

An implementation is conforming if it runs unchanged in behaviour on any host
providing: a hierarchical filesystem with atomic replace-by-rename, a process
model with argv-style spawn and timeouts, a monotonic-enough UTC clock, an HTTP
client, and a JSON codec. Notably it must NOT require: a POSIX shell, advisory
`flock`, `fork`, signals, case-sensitive paths, sub-second file mtimes, or any
particular text-processing utility.

## 2. Terms

| Term | Meaning |
|---|---|
| **Forge** | The code-hosting platform (GitHub, GitLab, Azure DevOps, Gitea…). |
| **Change** | A pull request / merge request. Called *PR* below for brevity. |
| **Identity** | The forge account the bot authenticates as. |
| **Tick** | One complete pass of the loop. Ticks may be scheduled by cron, a timer, an agent-session loop, or run manually. |
| **Run** | The execution of one tick. A run holds the lease (§6.4) for its lifetime. |
| **Content key** | An identifier of the *reviewable content* of a PR head — not of the commit. See R19. |
| **Reviewer agent** | The LLM invocation that produces findings for one PR, in its own isolated context. |
| **Orchestrator** | The deterministic, non-LLM control flow around the reviewer agent. Owns every irreversible effect. |
| **Store** | Durable key/value space for bot state, outside any cache or temp dir. |
| **Workspace** | A dedicated, disposable checkout of the repository, used as ambient context for the reviewer. |
| **Decision** | `APPROVE` or `COMMENT`. The review event the bot posts. |
| **Blocker** | A finding severe enough to withhold approval. See R23. |

## 3. Architecture

```
                          ┌──────────────────────────────┐
   scheduler ── tick ────▶ │        ORCHESTRATOR          │
                          │  deterministic; no LLM       │
                          │                              │
                          │  1 acquire lease             │──▶ Lease port
                          │  2 resolve identity + repo   │──▶ Forge port
                          │  3 reset workspace           │──▶ Workspace port
                          │  4 purge stale state         │──▶ Store port
                          │  5 detect queue              │──▶ Forge port
                          │  6 per PR: pre-flight        │──▶ Store + Forge
                          │  7 per PR: dispatch ─────────┼──▶ Agent port ─┐
                          │  8 per PR: post + save       │──▶ Forge + Store│
                          │  9 per PR: notify            │──▶ Notifier     │
                          │ 10 reset workspace           │                 │
                          │ 11 release lease             │                 │
                          └──────────────────────────────┘                 │
                                       ▲                                   │
                                       │  files only (never return values) │
                                       └───────────────────────────────────┘
                                                  REVIEWER AGENT
                                          isolated context; read-only;
                                          writes body + decision to Store
```

Two structural rules generate most of §7:

- **All irreversible or outward-facing effects live in the orchestrator.** The
  agent produces *content*; the orchestrator performs *effects*. (R5)
- **All communication between them is durable state, not return values.** The
  agent's transcript is a human trace, never a control channel. (R8)

## 4. Data model

### 4.1 Store namespacing

The store root MUST be outside any directory that an install, upgrade, or cache
eviction can wipe, and outside the system temp directory (R17, R9).

```
<store_root>/
  <forge_id>/<repo_slug>/
    lease                      # lease record (§4.7)
    log                        # append-only, size-rotated
    log.1                      # rotated predecessor
    mode                       # run-scoped policy record (§4.6)
    reviewed/<pr>              # durable: last posted review (§4.2)
    pending/<pr>               # transient: content being reviewed (§4.3)
    decision/<pr>              # transient: agent's decision (§4.4)
    body/<pr>                  # transient: agent's review body (§4.5)
    prior/<pr>                 # transient: previous findings, for delta mode
```

`<pr>` is the forge's change number/id, as an opaque string.

**Slug rules** (portability, R17). A slug MUST be derived from
`(forge_id, repo_owner, repo_name)` by: lowercasing; replacing every character
outside `[a-z0-9._-]` with `-`; collapsing runs of `-`; trimming leading and
trailing `-` and `.`; truncating to 48 characters and appending `-` plus the
first 8 hex characters of a digest of the original string if truncation or any
replacement occurred. Slugs MUST NOT equal a reserved device name (`con`,
`prn`, `aux`, `nul`, `com1`–`com9`, `lpt1`–`lpt9`) — append `-x` if they do.
Because some filesystems are case-insensitive, lowercasing is mandatory, not
cosmetic: `Owner/Repo` and `owner/repo` MUST NOT be able to produce two
distinct-looking-but-colliding namespaces.

Total store path length SHOULD stay under 200 characters so that a 260-character
platform limit is not reachable from a plausible `<store_root>`.

### 4.2 `reviewed/<pr>` — durable review state

```json
{
  "content_key": "<opaque string>",
  "commit": "<opaque string>",
  "reviewed_at": "2026-07-31T04:15:09Z",
  "decision": "COMMENT"
}
```

`reviewed_at` MUST be an explicit stored timestamp in UTC, ISO-8601 with a `Z`
suffix. Implementations MUST NOT substitute the record's file mtime: mtime
granularity, timezone handling, and preservation across copy/backup/restore all
vary by platform and would make re-request detection (R20) silently wrong.

Written **only** after a confirmed successful post (R10).

### 4.3 `pending/<pr>` — the content under review

```json
{ "content_key": "…", "commit": "…", "started_at": "…" }
```

Written by pre-flight, before the agent is dispatched. Read by the post step.
This is what makes the pre-flight → post handoff survive total loss of the
orchestrator's working memory (R8).

### 4.4 `decision/<pr>`

A single token: `APPROVE` or `COMMENT`. Case-insensitive on read; anything else
is treated as absent.

### 4.5 `body/<pr>` — the review body document

UTF-8, LF line endings. First line MUST be a decision header:

```
<!-- DECISION: APPROVE -->
### Code review — PR #42
Found 2 issues:
1. [BLOCKER] Unbounded read of request body — `src/api/upload.go:88`
2. [NIT] Dead parameter `retries` — `src/api/upload.go:12`
```

The header duplicates `decision/<pr>` deliberately (R11). The orchestrator
strips the header line before posting and appends the marker and footer itself.

### 4.6 `mode` — run-scoped policy

```json
{ "auto_approve": true, "run_id": "…", "declared_at": "…" }
```

Written by run start **after** the lease is held; deleted at run end. Every run
re-declares its mode, so a mode can never leak into a later run (R23).

### 4.7 `lease`

```json
{ "owner": "<unique run id>", "expires_at": "2026-07-31T06:15:09Z", "pid": 4711, "host": "…" }
```

See §6.4 for the acquire/renew/release/steal semantics. The lease *object* MUST
NOT be deleted on release (R13); release is a state transition inside it.

### 4.8 Transient hygiene

Pre-flight MUST delete `body/<pr>`, `decision/<pr>` before dispatching the
agent (R9). Run start MUST delete `pending/*`, `decision/*`, `body/*`,
`prior/*`, and every `reviewed/<pr>` whose PR is no longer open.

### 4.9 Atomic write rule

Every store write MUST be atomic with respect to a concurrent reader: write to
a temporary object in the *same* directory, flush, then atomically replace the
target. Readers MUST treat "absent", "empty", and "unparseable" identically —
as absent — and never crash a run on any of the three. Implementations MUST use
a replace primitive with defined overwrite semantics on the target platform
(e.g. `ReplaceFile`/`MoveFileEx` on Windows, `rename` on POSIX, or a
language-level `os.replace`-equivalent); a plain "rename that fails if the
target exists" is not sufficient.

## 5. Lifecycle

### 5.1 The tick

```
tick(args):
    lease = Lease.acquire(name="review", ttl=RUN_TTL)
    if lease is BUSY: return LOCKED            # another run owns it — do nothing

    try:
        log.rotate_if_large()
        identity = Forge.whoami()
        repo     = Workspace.identify()         # R16: derived from the workspace
        if repo is UNKNOWN:
            log.error("cannot identify repository from workspace")
            return NO_WORK                      # finally-block releases the lease

        Store.put("mode", parse_mode(args))     # R23: after the lease, on disk
        Workspace.reset_to_baseline()           # R21
        purge_stale(repo)

        queue = detect_queue(identity, repo)    # R19, R20, R22
        if queue is empty: return NO_WORK

        for (pr, reason) in queue:              # R14: strictly sequential
            if preflight(pr, reason) is SKIP: continue
            Agent.run(task_spec(pr))            # R2, R3, R4, R18
            finish(pr)                          # R5, R10, R11, R23, R27
            Workspace.reset_to_baseline()       # R21: also between PRs
    finally:
        Store.delete("mode")
        Lease.release(lease)                    # R15: on every exit path
```

### 5.2 Queue detection

```
detect_queue(identity, repo):
    for pr in Forge.open_prs_with_review_requested_for(identity):
        state = Store.get("reviewed/" + pr)

        if state is absent:
            # State may be genuinely new, or lost (fresh host, wiped store).
            # The forge is the fallback source of truth (R22).
            last = Forge.last_review_by(identity, pr, marker=MARKER)
            if last is absent: yield (pr, FIRST)
            else if re_request_after(pr, identity, last.submitted_at):
                yield (pr, RE_REQUESTED)
            continue

        if re_request_after(pr, identity, state.reviewed_at):
            yield (pr, RE_REQUESTED)
        else if Forge.content_key(pr) != state.content_key:
            yield (pr, CHANGED)
```

`re_request_after(pr, identity, t)` compares the timestamp of the newest
"review requested from *identity*" event against `t`, using forge-supplied
timestamps on both sides where possible, and never a local clock reading for
the stored side (R20).

### 5.3 Pre-flight

```
preflight(pr, reason):
    info = Forge.get_pr(pr)
    if info is absent or info.state != OPEN: return SKIP

    Forge.acknowledge(pr)                       # optional, best-effort (R31)

    head = Forge.head(pr)                       # {commit, content_key}
    if head is absent: return SKIP

    state = Store.get("reviewed/" + pr)
    if state exists and state.content_key == head.content_key
                    and reason != RE_REQUESTED:
        Store.put("reviewed/" + pr, state with commit=head.commit)   # refresh only
        return SKIP                             # R19: rebase/no-op push

    Store.put("prior/" + pr, Forge.previous_findings(pr, MARKER))    # R30
    Store.delete("body/" + pr); Store.delete("decision/" + pr)       # R9
    Store.put("pending/" + pr, {head.commit, head.content_key})      # R8
    return PROCEED
```

### 5.4 Finish (the only place effects happen)

```
finish(pr):
    body_doc = Store.get("body/" + pr)
    if body_doc is empty:
        log("no body produced — not posting, not saving state")
        Notifier.send(NO_BODY, pr)              # R27: failure paths notify too
        cleanup_transients(pr); return

    pending  = Store.get("pending/" + pr) or Forge.head(pr)          # R8
    decision = Store.get("decision/" + pr)
               or header_decision(body_doc)
               or COMMENT                       # R11: safe default
    if decision == APPROVE and not Store.get("mode").auto_approve:
        decision = COMMENT                      # R23: deterministic gate
        footer_note = "no blockers found; posted as a comment"

    body     = MARKER + "\n" + strip_header(body_doc) + "\n---\n" + footer
    blockers = count_blockers(body_doc)

    if Forge.post_review(pr, decision, body) succeeded:
        if pending has content_key:
            Store.put("reviewed/" + pr, {pending.content_key, pending.commit,
                                         now(), decision})            # R10
        Notifier.send(blockers > 0 ? BLOCKERS : CLEAN, pr, blockers, decision)
    else:
        log("post FAILED — not saving state; retries next tick")
        Notifier.send(POST_FAILED, pr, blockers, decision)            # R27

    cleanup_transients(pr)
```

### 5.5 Idempotency / crash-recovery table

| Crash point | Effect on next tick |
|---|---|
| Before lease acquire | Nothing happened. |
| Holding lease, process dies | Lease expires by TTL and is stealable (R12). |
| After pre-flight, before agent | `pending` is stale but harmless; overwritten. |
| After agent, before post | Body + decision are on disk; **post is fully reconstructable from the store** (R8). Even a total loss of orchestrator memory re-runs `finish(pr)` correctly. |
| After post, before `reviewed/<pr>` write | PR is re-reviewed next tick → one duplicate review. Accepted cost of never losing a review (R10). |
| After `reviewed/<pr>` write | Steady state. |

The worst permitted outcome is a **redundant review**. A *missing* review or a
*wrong decision* is a conformance failure.

## 6. Ports

Signatures are language-neutral. Every operation that crosses a process or
network boundary MUST be time-bounded, and MUST distinguish three outcomes:
success, definite failure, and *indeterminate* (timeout). Indeterminate MUST be
treated as failure for state-saving purposes (R10) — never as success.

### 6.1 Forge port

| Operation | Returns / semantics |
|---|---|
| `whoami()` | The bot's own identity. Required for R22 and queue detection. |
| `open_prs_with_review_requested_for(identity)` | PR ids where a review is currently requested from `identity`. |
| `get_pr(pr)` | `{state, author, title, url, base_ref, head_ref}`. |
| `head(pr)` | `{commit, content_key}` — see R19 for `content_key`. |
| `review_request_events(pr, identity)` | Timestamps of review-request events targeting `identity`, newest first. |
| `reviews(pr)` | Posted reviews with `{author, body, submitted_at}`. |
| `previous_findings(pr, marker)` | Body of the newest review by `identity` containing `marker`, with marker and footer stripped. |
| `post_review(pr, event, body)` | Posts one review. `event ∈ {APPROVE, COMMENT}`. MUST report success only on a confirmed 2xx-equivalent. |
| `changed_files(pr)` | Paths the PR touches relative to its base. (Extended: delta scoping.) |
| `compare(base, head)` | Paths changed between two refs. (Extended.) |
| `read_file(ref, path)` | File content at a ref, for verifying prior findings. (Extended.) |
| `acknowledge(pr)` | Optional visible "seen" signal (reaction/label). Best-effort. |

A forge binding that cannot supply `review_request_events` MUST substitute an
equivalent monotonic signal (§10) and MUST document it; silently degrading to
"re-review whenever the reviewer list contains us" is a conformance failure
because it re-reviews forever.

### 6.2 Agent port

```
Agent.run(task_spec) -> COMPLETED | FAILED
task_spec = {
    pr, repo, mode_hint,
    paths: { state, prior, body, decision },   # absolute, resolved by caller
    template_ref                               # location of the static task text
}
```

Requirements on any binding:

- The agent MUST run with a **fresh context per PR**, discarded afterwards (R2).
- The orchestrator MUST pass the *resolved absolute* store paths and MUST NOT
  let the agent reconstruct them (R18).
- The template MUST be a static document the agent *reads*, not text embedded
  in the dispatch prompt (R3).
- The orchestrator MUST NOT parse the agent's output for any control value
  (R8). `Agent.run` returning `COMPLETED` means only "the agent stopped".
- The agent MUST be given a read-only capability set (R25).

### 6.3 Store port

`get(key) -> bytes|absent`, `put(key, bytes)` (atomic, §4.9), `delete(key)`,
`list(prefix)`, `exists(key)`. No operation may depend on file metadata other
than existence and size.

### 6.4 Lease port

```
acquire(name, ttl) -> handle | BUSY
renew(handle, ttl)
release(handle)
```

Semantics (R12–R15):

- The lease MUST hold across every internal boundary of the implementation —
  separate processes, separate tool calls, separate HTTP handlers. An
  fd-scoped OS lock that releases when a callee returns does **not** satisfy
  this. This is why the spec mandates a record with an owner and an expiry
  rather than an OS lock primitive.
- `acquire` MUST be a compare-and-set on the lease record: succeed if the
  record is absent, released, or expired; otherwise `BUSY`.
- `release` MUST mark the record released. It MUST NOT delete it (R13).
- A run SHOULD `renew` periodically if its work can exceed `ttl`; `ttl` is the
  crash backstop, so it MUST be finite (a value on the order of one hour is
  reasonable for a bot reviewing a handful of PRs per tick).
- `acquire` MUST NOT block or queue. A busy tick is a no-op tick.

### 6.5 Clock port

`now() -> UTC instant`. All stored timestamps come from here. Comparisons
between a forge timestamp and a stored timestamp MUST be done on parsed
instants, not on strings, unless both are normalised to the same
lexicographically-comparable UTC format.

### 6.6 Notifier port (Extended)

`send(event)` where `event = {kind ∈ {CLEAN, BLOCKERS, POST_FAILED, NO_BODY},
repo, pr, title, url, decision, blockers, detail}`.

- Channels are **opt-in**. No configuration means silence (R27).
- Every send MUST be time-bounded and best-effort: a notifier that fails,
  hangs, or is misconfigured MUST be logged and stepped over, never allowed to
  fail a tick or block the next PR.
- Rendering MUST escape interpolated forge data (a PR title is attacker-
  controlled text; it MUST NOT be able to inject markup into a chat card).
- Delivery URLs and tokens MUST NOT appear in the log, in an error message, or
  in the notification payload (R28).

### 6.7 Config port

Layered, later wins:

```
CLI/run arguments  >  project config (nearest ancestor of the workspace)
                   >  auto-detected values  >  user config  >  defaults
```

Secrets (webhook URLs, forge tokens) MUST come only from the user layer or the
process environment, never from repository-tracked files. Where the OS supports
it, the user config MUST be readable only by its owner (`0600` on POSIX;
owner-only ACL on Windows).

### 6.8 Log port

`append(line)` with a UTC timestamp; size-based rotation to a single
predecessor. Logs MUST record: run start/end, identity and repository, each
queue decision with its reason, each skip with its reason, each post with its
decision, every workspace-refresh failure (R21), and every notifier failure.
Logs MUST NOT record secrets (R28).

### 6.9 Workspace port

`identify() -> {forge_id, owner, name, root} | UNKNOWN`
`reset_to_baseline()`

`reset_to_baseline` MUST make the working tree match the upstream default
branch **exactly**, discarding both tracked modifications and untracked files,
while preserving ignored build caches. It MUST NOT be implemented as a merge
(e.g. `git pull`): a merge can create a merge commit or abort outright against
a force-pushed upstream. It MUST also prune leftover local branches created by
per-PR checkouts. Failures MUST be logged, never swallowed (R21).

## 7. Normative requirements

### A. Context and cost isolation

**R1 — The orchestrator MUST stay thin.** Its per-tick and per-PR footprint
(prompt text, read file contents, retained output) MUST be bounded and MUST NOT
grow with PR size or finding count.
*Failure mode:* in any shared-session or long-lived-process design, everything
the orchestrator reads accumulates; cost per tick rises monotonically and the
loop eventually degrades or compacts mid-tick.

**R2 — Each PR MUST be reviewed in an isolated, discarded agent context.**
Diffs, file reads, and findings live and die there.
*Failure mode:* one large PR poisons every later tick.

**R3 — The agent's instructions MUST live in a static document the agent
reads.** Not inlined into the dispatch prompt.
*Failure mode:* the full template is re-paid on every dispatch and pollutes the
orchestrator.

**R4 — The agent MUST self-derive everything derivable.** Its own head commit,
content key, review mode, and delta base. The orchestrator passes only the PR
id and the paths the agent cannot safely reconstruct (R18).
*Failure mode:* the orchestrator becomes the transport for per-PR data — the
exact bloat R1 forbids. (In the reference implementation this cut per-PR
orchestrator cost from ~65 lines to ~1.)

### B. Determinism of effects

**R5 — Every irreversible or outward-facing action MUST be performed by
deterministic non-LLM code.** Posting the review, saving state, acquiring and
releasing the lease, and applying the approval policy.
*Failure mode:* measured, not hypothetical — a reviewer agent that ran a large
delegated review command (72 tool calls), returned findings, and then simply
never posted, emitting no decision. A silent no-op with no error anywhere.

**R6 — The agent's deliverable MUST be defined as "write these artifacts",
and any delegated sub-tool MUST be framed as a mere data-gathering substep.**
The task document MUST state explicitly that finishing the sub-tool is not
finishing the task.
*Failure mode:* as R5 — a large sub-tool consumes the agent's "finish the turn"
budget and the real deliverable never happens.

**R7 — The model MUST have no discretion over policy.** Where a policy exists
(approval gating, severity → decision mapping, retry), it MUST be enforced in
deterministic code even if the agent also reasons about it.
*Failure mode:* policy drifts per run and cannot be audited or tested.

### C. Durability

**R8 — Every value that crosses a step boundary MUST be persisted to the
store.** Specifically the reviewed commit and content key (written by
pre-flight) and the decision and body (written by the agent). The post step
MUST take **only the PR id** and recover everything else from the store.
*Failure mode:* any process restart, context compaction, or crash between the
agent returning and the post landing produces a wrong or missing post. Parsing
these values out of the agent's reply is the same fragility.

**R9 — Pre-flight MUST clear this PR's transient artifacts before dispatch.**
*Failure mode:* a half-finished earlier run leaves a stale decision or body that
the post step reads and posts — potentially an approval for content nobody
reviewed.

**R10 — Durable review state MUST be written only after a confirmed successful
post.** Indeterminate outcomes count as failure.
*Failure mode:* a failed or empty run marks the PR done; the review is silently
never posted and never retried.

**R11 — Decision resolution MUST be ordered, with a conservative default:**
sidecar record → body header → `COMMENT`. Any unrecognised token resolves to
`COMMENT`.
*Failure mode:* ambiguity resolving toward approval; the bot approves on
malformed output.

### D. Concurrency

**R12 — Mutual exclusion MUST hold for the whole run, across every internal
boundary,** and MUST be crash-safe via a finite TTL.
*Failure mode:* two overlapping runs share one workspace; concurrent checkouts
corrupt the tree and both reviews read a mixed baseline.

**R13 — The lease object MUST NOT be deleted on release.**
*Failure mode:* delete-on-release is a TOCTOU race — two runs create and lock
two different objects for the same name and both believe they hold the lease.

**R14 — PRs MUST be processed sequentially while they share a mutable
workspace.**
*Failure mode:* parallel branch operations in one checkout conflict.

**R15 — The lease MUST be released on every exit path,** including the
no-work and cannot-identify-repository paths, and cleanup MUST NOT depend on
the agent doing anything.
*Failure mode:* the common no-work tick strands the lease and the bot is dead
until the TTL expires.

### E. Identity and namespacing

**R16 — Repository identity MUST be derived from the workspace,** not
hardcoded. A run that cannot identify its repository MUST log, release, and
exit cleanly.
*Failure mode:* the bot silently reviews the wrong repository, or hangs the
scheduler.

**R17 — Every shared path MUST be namespaced by forge and repository** —
lease, log, mode, and all per-PR state.
*Failure mode:* silent and severe. One global lease serialises unrelated
repositories; flat PR-number keys let `owner-a/repo#5` overwrite
`owner-b/repo#5`'s state, so a real review is skipped because another
repository's PR "claimed" the slot.

**R18 — The orchestrator MUST resolve namespaced paths and inject them into
the agent.** The agent MUST use them verbatim.
*Failure mode:* the agent writes to a plausible-but-wrong path; the
orchestrator's read finds nothing and the tick silently produces no review.

### F. Triggering and deduplication

**R19 — Deduplication MUST key on reviewable content, not on the commit id.**
The content key MUST be stable across operations that rewrite commits without
changing content (rebase, amend, empty push, merge-base update). Where the
forge exposes a tree digest, use it. Where it does not, the binding MUST
compute one — e.g. a digest over the sorted `(path, blob-digest)` pairs of the
PR's changed files, or the forge's own iteration/patch-set id.
*Failure mode:* every rebase re-triggers a full review; the bot spams PRs and
burns budget on identical content.

**R20 — A re-review MUST be triggered by an explicit re-request whose
timestamp is newer than the recorded `reviewed_at`,** compared as instants, and
never using a filesystem mtime as the stored side.
*Failure mode:* either the bot never honours "please look again" (a human
request silently ignored), or it re-reviews on every tick forever.

**R21 — The workspace MUST be force-reset to the upstream baseline at run
start and after each PR, and failures MUST be logged, not swallowed.** Reset
MUST be exact-match, not a merge (§6.9).
*Failure mode:* the deepest silent failure in the system. If the reviewer reads
ambient repository context from the local tree (conventions files, neighbouring
code, history), a stale or dirty tree degrades *every* review with no error
anywhere. A per-PR checkout also strands PR-added files as untracked, which
makes a non-forced switch back to the baseline abort.

**R22 — Every posted review body MUST carry a stable machine marker,** and
lost-store recovery MUST use it to find the bot's own prior review on the
forge.
*Failure mode:* a wiped store re-reviews every open PR from scratch, posting
duplicates.

### G. Policy and safety

**R23 — Comment MUST be the default; approval MUST be opt-in per run, and the
opt-in MUST be recorded in the store before any PR is processed.** The agent's
`APPROVE` means exactly "I found zero blockers" — it is a finding summary, not
an instruction to approve.
*Rationale:* an approval is durable, outward-facing, and can satisfy branch
protection and unblock a merge. It is the one decision worth making
unavailable by default.
*Failure mode:* a context loss or a stale flag turns a comment-only run into an
approving one, and an LLM's judgement silently becomes a merge gate.

**R24 — The bot MUST NOT post a change-request-style blocking review.** That
event is reserved for humans.
*Failure mode:* a bot false positive hard-blocks a merge with no human in the
loop.

**R25 — The reviewer agent MUST be read-only.** No commit, push, patch
application, cherry-pick, force operation, or forge write. Checking out a PR to
read files at its head is permitted precisely because R21 cleans up after it.
*Failure mode:* a review mutates the repository under review.

**R26 — Findings MUST be posted regardless of the decision.** The safe
direction (downgrade to comment) MUST also be the lossless one.
*Failure mode:* policy changes suppress review content, and the bot appears
broken rather than conservative.

### H. Observability (Extended)

**R27 — The bot MUST be able to signal outcomes out of band, from the same
deterministic point as the effect, and MUST signal the failure paths too** —
a review that produced no body, and a post that failed.
*Rationale:* the bot authenticates as a human identity, and forges do not
notify you about your own actions. A posted review is therefore invisible; the
only trace is a log nobody reads. Worse, R10's retry logic makes failures look
like nothing happened.
*Failure mode:* silent misses. The bot appears healthy while posting nothing.

**R28 — Credentials MUST never reach the log, an error message, or a
notification payload,** and this MUST be asserted by a test.
*Failure mode:* a webhook URL is a bearer credential; leaking it into a
rotated log file hands the channel to anyone who reads it.

**R29 — Every skip and every queue decision MUST be logged with its reason.**
*Failure mode:* "why did it not review my PR" is unanswerable, and the
dedup/re-request logic cannot be debugged.

### I. Review content contract (Extended)

**R30 — Delta review MUST be scoped to the intersection of "files the PR
touches relative to its base" and "files changed since the last reviewed
commit".** Prior findings MUST be reconciled as resolved / still open /
reintroduced, and a still-open or reintroduced blocker MUST count as a current
blocker.
*Failure mode:* reviewing the raw old-head → new-head diff includes commits
pulled in by a rebase, so the bot reviews unrelated upstream code and reports
findings the author cannot act on.

**R31 — Findings MUST be classified into exactly two severities** —
blocker (security, correctness, data loss, breaking interface change,
documented-rule violation) and nit (everything else) — and the decision MUST
be a pure function of the blocker count. Nits MUST be reported even when the
count is zero.
*Failure mode:* a graded severity scale makes the decision judgement-dependent
and untestable.

**R32 — `count_blockers(body_doc)` MUST count only CURRENT blockers, and the
decision MUST win when the two disagree.** A delta review's prior-findings block
restates each prior finding's original severity alongside its new status, so the
blocker marker appears on findings that are already fixed. The counter MUST
therefore be defined against a **pinned prior-findings line shape** — status
before severity marker, on one line — and that shape MUST be stated in the
review-agent contract (§7 R30), not only in the counter. A finding whose status
is *resolved* MUST NOT count; *still open* and *reintroduced* MUST count (R30).
Where the count disagrees with the decision, the decision governs: a decision of
approve means exactly zero blockers, so the reported count MUST be zero — and the
discrepancy MUST be surfaced on the notification itself, not only logged (R27).
*Failure mode:* counting raw markers reports fixed findings as live ones, so the
notification contradicts the review body it links to — the reader's only
cross-check — and trust in every later notification goes with it. Defining the
counter without pinning the producer's line shape is the same bug one level up:
the parser and the review agent drift, and the regression returns silently.
Overriding the count without surfacing the disagreement converts a loud
inconsistency into a silent one.

## 8. OS portability rules

| Concern | Rule |
|---|---|
| **Shell** | MUST NOT construct command lines as strings. Spawn with an argv array. No dependence on a shell being present, nor on any text utility (`sed`, `find`, `stat`, `grep`, `xargs`). |
| **Paths** | Build with the platform's path API. Assume case-insensitive collision is possible (§4.1). Keep store paths short (§4.1). |
| **Atomic replace** | Use a documented overwrite-replace primitive (§4.9). Do not assume POSIX `rename` semantics are available everywhere. |
| **Locking** | MUST NOT rely on advisory `flock`, fd inheritance, or lock-file deletion. Use the record lease (§6.4). |
| **Processes** | No `fork`, no signal-based cleanup, no orphan holder processes. Crash-safety comes from the lease TTL, not from a supervisor. |
| **Time** | UTC everywhere; ISO-8601 with `Z`; no local timezone in stored data; no reliance on file mtime (§4.2); no reliance on sub-second resolution. |
| **Text** | Store documents as UTF-8 with LF. Normalise CRLF on read. Do not let the platform's default encoding decide. |
| **Networking** | Every call time-bounded; retries bounded and idempotent; timeout classified as indeterminate, not success (§6). |
| **Environment** | No dependence on `$HOME` specifically — resolve the store root from the platform's user-data location, overridable by configuration. |
| **Exit** | Cleanup MUST be in a `finally`-equivalent, and MUST be safe to run twice. |

## 9. Language capability checklist

An implementation language must provide: an HTTP client with per-request
timeouts; JSON encode/decode; atomic file replace; directory listing; process
spawn with argv and a timeout; a UTC clock; a cryptographic digest (for slugs
and computed content keys); and a way to run the agent (an SDK, a subprocess, or
an HTTP API). Nothing else is required — no shell, no concurrency primitives
beyond sequential execution, no long-lived daemon.

## 10. Forge bindings

`content_key` is the load-bearing binding decision (R19).

| Abstract op | GitHub (reference) | GitLab | Azure DevOps |
|---|---|---|---|
| `whoami` | `GET /user` | `GET /user` | `GET /connectionData` |
| requested-from-me | `pulls` list, filter `requested_reviewers` | MR list `reviewer_username=me` | PR list, filter `reviewers` |
| `head` | `pulls/{n}.head.sha` | MR `sha` | PR `lastMergeSourceCommit` |
| **`content_key`** | commit's **tree SHA** | MR **diff/version id** (`/versions`) | PR **iteration id** (`/iterations`) |
| `review_request_events` | `issues/{n}/events`, `event=review_requested`, `requested_reviewer=me` | MR **resource state / reviewer events** (`/resource_state_events`, notes) | PR **reviewer vote reset / update** timestamps |
| `reviews` | `pulls/{n}/reviews` | MR notes + approvals | PR threads |
| `post_review(APPROVE)` | `POST pulls/{n}/reviews` `event=APPROVE` | `POST /approve` + a note | reviewer vote `+10` + a thread |
| `post_review(COMMENT)` | `event=COMMENT` | MR note | PR thread comment |
| forbidden event (R24) | `REQUEST_CHANGES` | `unapprove`/blocking discussion | vote `-10` (rejected) |
| `changed_files` | `pulls/{n}/files` | MR `/diffs` | PR iteration changes |
| `acknowledge` | issue reaction `eyes` | award emoji | thread comment |

Binding notes:

- **GitLab / Azure DevOps have no exact analogue of "review requested from
  user X at time T".** A binding MUST pick a monotonic substitute (a reviewer
  added event, a vote reset, a note with an agreed trigger phrase) and document
  it. It MUST NOT fall back to "reviewer list contains me", which has no
  timestamp and re-triggers forever (R20).
- **Azure DevOps iteration ids are a better content key than any digest** —
  they increment only on a real push and are stable across the base branch
  moving. GitLab diff versions behave similarly. Prefer them over a computed
  digest where available.
- A forge with no distinct approve/comment review event MUST still keep the two
  paths distinguishable, because R23's gate is a change of *event*, not of
  content.

## 11. Conformance test suite

All tests MUST be hermetic: a fake forge, a temporary store root, an injected
clock, and a stubbed agent. No test may reach a real forge or notification
endpoint. Each test states the requirement it pins.

| # | Given | When | Then | Pins |
|---|---|---|---|---|
| 1 | No prior state, review requested | tick | one review posted, `reviewed/<pr>` written | R5, R10 |
| 2 | State with matching content key, no re-request | tick | no post; commit refreshed only | R19 |
| 3 | State whose content key differs only by rebase (same tree) | tick | no post | R19 |
| 4 | State + re-request newer than `reviewed_at` | tick | full re-review posted | R20 |
| 5 | State + re-request **older** than `reviewed_at` | tick | no post | R20 |
| 6 | Agent writes body + `APPROVE`, no opt-in | tick | posted event is `COMMENT`; body still contains the findings; footer notes the downgrade | R23, R26 |
| 7 | Same, with opt-in for this run | tick | posted event is `APPROVE` | R23 |
| 8 | Run 1 with opt-in completes; run 2 without | run 2 | run 2 posts `COMMENT` | R23 |
| 9 | Agent writes body, no decision record, header says `APPROVE`, no opt-in | tick | `COMMENT` posted | R11, R23 |
| 10 | Agent writes body with no header and no record | tick | `COMMENT` posted | R11 |
| 11 | Agent writes nothing | tick | no post, no state write, failure notification | R10, R27 |
| 12 | Forge post returns an error | tick | no state write; next tick retries | R10 |
| 13 | Forge post times out | tick | treated as failure; no state write | §6, R10 |
| 14 | Orchestrator state discarded between agent completion and post | resume at post with only the PR id | correct body and decision posted | R8 |
| 15 | Stale body/decision from an abandoned earlier run present | tick | pre-flight clears them; the new review is posted | R9 |
| 16 | Lease held by a live owner | tick | second tick is a no-op, posts nothing, does not touch state | R12 |
| 17 | Lease owner crashed, TTL expired | tick | lease stolen; run proceeds | R12 |
| 18 | Lease released | inspect store | lease record still exists | R13 |
| 19 | No work | tick | lease released before return | R15 |
| 20 | Repository cannot be identified | tick | logged, lease released, clean exit, no forge writes | R16 |
| 21 | Two repositories with the same PR number | ticks in both | independent state; both reviewed | R17 |
| 22 | Repo names differing only in case | ticks in both | one namespace or two distinct ones — never a silent collision | §4.1 |
| 23 | Store wiped, marker review exists on the forge | tick | no duplicate review unless re-requested | R22 |
| 24 | Workspace left on a PR branch with untracked PR files | tick | workspace exactly matches the baseline before dispatch | R21 |
| 25 | Baseline fetch fails | tick | failure is logged (not swallowed) | R21 |
| 26 | No notification channel configured | tick | no notification attempted; tick unaffected | R27 |
| 27 | Notification endpoint hangs past the timeout | tick | logged, tick completes, next PR processed | §6.6 |
| 28 | Notification configured with a secret URL | tick | the URL appears in no log line and no payload | R28 |
| 29 | PR title contains markup / control characters | notification rendered | escaped; no injection | §6.6 |
| 30 | Delta review with a prior blocker still present | tick | it counts as a current blocker; decision is `COMMENT` | R30, R31 |
| 31 | Delta review after a rebase pulled in upstream files | tick | reviewed set excludes files the PR did not touch | R30 |
| 32 | PR is closed between queueing and pre-flight | tick | skipped, logged, no post | §5.3 |
| 33 | Delta review whose only blocker is a *resolved* prior finding | tick | reported count is 0; notification reads clean | R32 |
| 34 | Body carries blocker markers but the decision is approve | tick | reported count is 0 **and** the discrepancy appears on the notification | R32, R27 |

## 12. Reference implementation map

The reference implementation is the `fu-review-prs` plugin in this repository:
bash + the Claude Code agent runtime, bound to GitHub via the `gh` CLI. It
predates this spec and satisfies the Core profile with the deviations noted.

| Spec element | Reference artifact |
|---|---|
| Orchestrator (§5.1) | `commands/review-prs.md` (thin; steps 1–3) |
| Deterministic effects (R5) | `scripts/lib.sh` — `pr_review_init`, `pr_review_preflight`, `pr_review_finish`, `pr_review_cleanup` |
| Agent task template (R3) | `review-task.md` (read by the agent, not inlined) |
| Store (§4) | `~/.claude/pr-review/state/<slug>/` — `last-reviewed-<pr>`, `pending-<pr>`, `decision-<pr>.txt`, `review-body-<pr>.md`, `prior-<pr>.txt`, `auto-approve` |
| Lease (§6.4) | background `flock` holder process + `HOLDER_FILE` |
| Content key (R19) | GitHub commit tree SHA |
| Policy gate (R23) | `pr_review_finish` + `auto-approve` on disk; `test/auto-approve.test.sh` |
| Notifier (R27) | `pr_review_notify` / `notify_teams`; `test/notify.test.sh` |
| Workspace reset (R21) | `pr_review_reset_tree` (fetch → checkout -f → reset --hard → clean -fd → prune branches) |
| Design rationale | `docs/orchestrator-subagent-pr-review-bot.md` |

**Known deviations from this spec** (each is a portability gap, not a
correctness bug in its own environment):

1. **Lease** uses a background `flock` holder process rather than a record with
   an owner and expiry (§6.4). Correct on POSIX; the holder process and `flock`
   are both unavailable as specified on Windows, and the sleep-based TTL is a
   process, not a stored deadline.
2. **Re-request comparison** uses the state file's mtime as the stored side
   rather than a recorded `reviewed_at` (R20, §4.2).
3. **Shell utilities** (`sed`, `find`, `stat`, `xargs`, `tr`) are hard
   dependencies (§8), as is `jq`.
4. **Store writes** are direct redirections, not write-temp-then-replace
   (§4.9). A reader concurrent with a write could observe a partial document —
   bounded in practice by R14's sequential processing and the single lease.
5. `pending-<pr>` and `last-reviewed-<pr>` are two-line text records rather than
   JSON, so they carry no `reviewed_at` and no schema version.
6. **Slug** is `owner/name` with `/` → `-` only (§4.1): not lowercased, not
   sanitised against reserved names, not forge-qualified. Two remotes differing
   only in case would collide on a case-insensitive filesystem.

A port of the bot to another language or OS SHOULD close 1–4 rather than
reproduce them.

## 13. Appendix — minimal end-to-end pseudocode

```
main(args):
    cfg   = Config.load(args)
    store = Store.open(cfg.store_root)
    forge = Forge.bind(cfg.forge)
    lease = Lease.open(store, "review")

    handle = lease.acquire(ttl=cfg.run_ttl)
    if handle is BUSY: return

    try:
        repo = Workspace.identify(cfg.workspace) or fail_clean("no repo")
        ns   = store.namespace(repo.forge_id, slug(repo))
        ns.put("mode", {auto_approve: args.auto_approve, run_id: handle.owner,
                        declared_at: Clock.now()})
        Workspace.reset_to_baseline(cfg.workspace)
        purge_stale(ns, forge.open_prs())

        for (pr, reason) in detect_queue(forge, forge.whoami(), ns):
            if preflight(forge, ns, pr, reason) is SKIP: continue
            Agent.run({pr, paths: ns.paths_for(pr), template: cfg.template})
            finish(forge, ns, pr)
            Workspace.reset_to_baseline(cfg.workspace)
    finally:
        ns.delete("mode")
        lease.release(handle)
```

Every requirement in §7 is visible in these twenty lines as either a call
ordering, a `finally`, or a value that goes through `ns` (the store) instead of
through a variable. That is the whole design: **effects are deterministic and
ordered; state is durable and namespaced; the model only writes content.**
