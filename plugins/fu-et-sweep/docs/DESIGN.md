# Datadog Error Tracking → GitHub Issue Sweep Loop — Design

**Date:** 2026-06-15
**Status:** Implemented as a user-level tool
**Author:** fu + Claude

> **Relocation note (post-design):** this tool was pulled out of the EntityPlatform
> repo and now lives at user level under `~/.claude/` (command, agents, scripts) —
> it is generic, with `--service` / `--env` / `--repo` as arguments (defaults:
> `entityplatform-api` / `prod` / `InfoTrackGlobal/EntityPlatform`). Paths below that
> say `.claude/commands/`, `api-dotnet/`, or `docs/superpowers/...` map to
> `~/.claude/commands/`, the target service's own source, and `~/.claude/scripts/et-sweep/`.
> See `README.md` for live usage. The issue-body template below is current.

## Problem

`entityplatform-api` (prod) accrues Datadog Error Tracking issues. Today they are
triaged manually, ad hoc. We want a self-paced loop that watches Error Tracking,
files a GitHub issue with a drafted root-cause writeup for genuinely actionable
errors, de-dups carefully so the same Datadog issue never produces two GitHub
issues, and keeps token/context usage tight enough to run unattended in a long
`/loop` session.

## Goals

- File a GitHub issue (with root-cause writeup) for new/regressed, actionable prod errors.
- Never double-file: one Datadog `issue_id` ⇒ at most one GitHub issue, ever.
- Reopen + comment on regressions instead of filing fresh.
- Keep the main loop context small and flat across many ticks.
- Start in an observation phase to calibrate noise before filing anything.

## Non-goals

- Writing Datadog issue state back (IGNORE/RESOLVE) — out of scope for v1.
- Auto-fixing / opening PRs — the writeup is a draft, not a verdict.
- Covering `entityplatform-ui` browser errors — api/prod only for v1 (extensible later).
- Unattended cloud/cron execution — v1 runs in a live `/loop` session where
  `pup` (Datadog) and the `gh` CLI are authenticated.

## Execution model

- A slash command `/et-sweep` holds the per-tick procedure, run via `/loop`
  (self-paced) or one-shot. Lives in `.claude/commands/`.
- Runs in a live Claude Code session so the `pup` Datadog CLI (`pup auth login`)
  and the `gh` CLI are authenticated. Datadog access is `pup` via Bash — no MCP
  server. Headless cron is possible if `pup`/`gh` carry valid tokens, but a `401`
  needs an interactive `pup auth login`, so a live session is the default.

## Architecture

Components:

- **Loop driver** — the `/et-sweep` command; orchestrates a tick, stays thin.
- **Tick procedure** (main context) — search, cheap filter, dedup classification,
  fan-out, receipt collection. Never reads stack traces or drafts prose itself.
- **Triage-gate subagent** — metadata in, `{actionable, reason, suspected_severity}`
  out. No Datadog reads.
- **Investigation subagent** — `issue_id` in; runs `pup error-tracking issues get`
  + a `pup traces/logs search '@issue.id:<id>'` for the sample stack + codegraph
  trace, drafts the writeup, files/reopens the GitHub issue, returns a one-line
  receipt. The writeup goes into the GitHub issue, not back to the loop.
- **GitHub** — both the de-dup store and the output sink. No separate database.
- **State file** (gitignored, outside the tracked tree) — `{ last_successful_tick,
  baseline_done }`. Dedup needs no state; this only fixes the window-gap problem.

### Data flow per tick

```
1. pup error-tracking issues search  (THIN: returns issue_id + total_count only)
     --query "service:(...) env:prod"  --track trace
     --from window_start (see Window)  --to now
     --order-by TOTAL_COUNT  --limit 50
        │   → candidate list [{issueId, totalCount}]
2. count-prune (main ctx, no tool calls): keep total_count ≥ COUNT_THRESHOLD
        │
3. dedup classification (main ctx) — the regression authority:
     gh issue list --state all --search "<issue_id>"
       no match       → NEW
       match, open     → ALREADY-OPEN (skip)
       match, closed   → REGRESSION-of-#N   (sets is_regression)
     sort by total_count desc; cap N=10 (log dropped) → bounds the gets below
        │
4. hydrate + recency filter (survivors ≤10):
     pup error-tracking issues get "<issue_id>"  → first_seen, error_type/message,
       version, function_name, platform, datadog_url
     keep if (first_seen ≥ window_start OR is_regression)   [BASELINE skips this]
        │
5. fan out survivors:
     ├─ triage-gate subagent  → actionable? ──no──> drop (shown in observe)
     └─ investigation subagent (actionable only):
            pup get + pup traces/logs search '@issue.id' + codegraph → writeup
            NEW         → gh issue create (+marker +labels)   [live]
            REGRESSION  → gh issue reopen #N + comment        [live]
            (observe mode: draft only, file nothing)
        │
6. collect one-line receipts → summarise → advance last_successful_tick
   → ScheduleWakeup (self-paced)
```

Main context per tick holds only: capped search list, candidate tags, receipts.
Everything heavy is subagent-scoped and dies with the subagent.

## Window (gap-safe)

Fixed `now-24h` would miss issues first seen during a tick gap longer than 24h
(quiet self-paced stretch, or session closed then reopened later). Therefore:

- `window_start = max(now-30d, min(last_successful_tick, now-24h))`
  i.e. always cover at least the last 24h, never reach back further than 30d, and
  otherwise extend exactly back to the last completed tick. (On first run, with no
  `last_successful_tick`, treat it as `now-24h`.)
- `last_successful_tick` is persisted to the state file and advances only when a
  tick completes (even if some candidates were skipped). A hard-aborted tick
  leaves it unchanged, so the next run re-covers the window.
- **Newness is decided by GitHub dedup, not by `first_seen`.** The window only
  bounds the candidate set; an over-wide window cannot double-file because the
  marker search catches anything already filed. `first_seen` is downgraded to
  informational (issue body) and `new vs regression` labeling.

## Decision logic

### Stage 1 — cheap filter

```
candidate  ⟺  (first_seen ≥ window_start OR is_regression == true)
              AND total_count ≥ COUNT_THRESHOLD
```

Long-standing-but-active issues (old `first_seen`, not regressed) are excluded —
they are backlog, handled once via `--baseline`, not re-surfaced every tick.

Ordering note (pup): `pup`'s ET search returns only `issue_id`+`total_count`, so
`first_seen` is not known until a per-issue `get`. The tick therefore count-prunes
and dedups (cheap) FIRST to bound the candidate set ≤10, then hydrates via `get`
and applies this recency check. The criterion is unchanged — only its position in
the pipeline moved (was: filter-then-dedup; now: prune+dedup-then-hydrate+filter).

### Stage 2 — dedup classification

For each candidate: `gh issue list --state all --search "<issue_id>"`.

| GitHub result   | Classification     | Downstream action      |
|-----------------|--------------------|------------------------|
| no match        | `NEW`              | create                 |
| match, open     | `ALREADY-OPEN`     | skip (no churn)        |
| match, closed   | `REGRESSION-of-#N` | reopen + comment       |

A closed-GH match routes to reopen and sets `is_regression` for the survivor
(`pup` has no Datadog regression flag, so GitHub state is the sole regression
authority — and is authoritative for the action taken).

### Stage 3 — triage-gate subagent (metadata only)

- Input: `{issue_id, error_type, error_message, total_count, first_seen,
  last_seen, function_name, service, platform}`. No Datadog reads.
- Output: `{actionable: bool, reason: string, suspected_severity: low|med|high}`.
- Heuristic: drop transient/infra noise (client-cancel `TaskCanceledException` /
  `OperationCanceledException` at `HttpConnection.SendAsync`, DNS blips, upstream
  5xx passthrough); keep app-logic errors (NREs, unhandled domain exceptions,
  EF/Npgsql failures originating in EP code).
- `actionable:false` → drop. In observe mode the dropped candidate is still
  printed with its reason.

### Stage 4 — investigation subagent (actionable only)

- `pup error-tracking issues get <id>` for the issue summary, then a
  `pup traces search '@issue.id:<id>'` (fallback `pup logs search`) for a sample
  event's stack frames; optional `pup logs aggregate --group-by version` for spread.
- codegraph trace from the failing frame into `entityplatform-api` source
  (EP-owned frames only; skip BCL/framework frames).
- Drafts root-cause writeup (see Issue format).
- Live mode: `NEW` → `gh issue create`; `REGRESSION` → `gh issue reopen #N` +
  comment. Observe mode: returns the draft, files nothing.
- Returns one-line receipt: `#1234 created (high)` / `#988 reopened` /
  `observed: would-create (med)` / `skipped: <reason>`.

## GitHub issue format

**Title:** `[Datadog] <error_type>: <message truncated ~80 chars>`
Example: `[Datadog] NullReferenceException: Object reference not set in CompanyDetailProjector`

**Labels:** `datadog-error-tracking` (dedup/filter scope), `auto-filed`,
`sev:low|med|high`. Baseline run also adds `et-baseline`.

**Body** (no `#` headers — bold labels, per repo prose convention):

```markdown
<!-- dd-et-issue: <issue_id> -->

**Datadog:** https://ap2.datadoghq.com/error-tracking/issue/<issue_id>

**Error**
- Type: `<error_type>`
- Message: <error_message>
- Service: `entityplatform-api` · env `prod` · <platform>
- Failing frame: `<function_name>`

**Occurrence**
- Count (window): <total_count>
- First seen: <first_seen> · <first_seen_version>
- Last seen: <last_seen> · <last_seen_version>

**Suspected root cause** *(drafted, verify before acting)*
<LLM writeup — 1-3 short paras: what throws, why, the traced code path>

**Suspected code location**
- `<path>:<line>` (codegraph trace)

---
*Auto-filed by /et-sweep. Regressions reopen this issue rather than filing a new
one. The root-cause section is a draft, not a verdict.*
```

The hidden marker `<!-- dd-et-issue: <issue_id> -->` is the dedup anchor:
searched, never rendered. `issue_id` is the join key end to end.

**Regression comment** (when reopening a closed issue):

```markdown
**Regressed** — recurred after close.
- Seen again: <last_seen> · <last_seen_version>
- Count this window: <total_count>
- Datadog: <link>
<one-line note if the suspected root cause shifted vs the original>
```

## Token / context budget

- Main loop ctx per tick holds only: capped `search` result, candidate tags,
  one-line receipts. Target well under a few k tokens/tick regardless of volume.
- `search`: tight query, explicit `max_tokens`, `order_by: TOTAL_COUNT`. If the
  result is truncated, process what returned and log the remaining count.
- Subagent isolation: `get`/`analyze` payloads and codegraph reads live only in
  subagent context and return ≤1 line to the loop — this is what prevents
  per-tick context growth across a long `/loop`.
- Two-stage gate: the metadata-only triage gate kills noise before the expensive
  `get` + `analyze` + codegraph subagent runs.

## Resilience

- Per-candidate scope: any `search`/`get`/`gh`/subagent failure → log that
  `issue_id` + reason, skip, continue the tick. One bad issue never kills a sweep.
- `last_successful_tick` advances only on tick completion. A hard abort leaves it
  unchanged; the next run re-covers the window (dedup prevents double-file).
- `gh` create/reopen failure after a writeup is drafted → log the full writeup to
  tick output so it is not lost; retry next tick (still NEW in dedup).
- Self-pace: `ScheduleWakeup` ~24h baseline; shorten when a tick filed something
  (active period), lengthen when quiet. Runtime clamps the delay.

## Rollout (two phase)

1. **Observe** — `/et-sweep --observe`, `COUNT_THRESHOLD = 1`. Runs
   search → filter → dedup → triage gate, prints a table (issue_id, type, count,
   triage verdict + reason, would-be action), files nothing. Run a few ticks,
   watch what the gate keeps vs drops, tune `COUNT_THRESHOLD` and the triage
   prompt.
2. **Live** — `/et-sweep`, calibrated threshold. Files/reopens for real.

First live (or baseline) run guard: nothing is filed yet, so every active issue
above threshold is a candidate. Bounded by the per-tick cap (N=10, log
truncation) plus an optional one-time `--baseline` mode that records existing
`issue_id`s as known (label `et-baseline`) without drafting writeups.

## Configuration

| Knob              | Default (observe) | Notes                                   |
|-------------------|-------------------|-----------------------------------------|
| `mode`            | `observe`         | `observe` \| `live` \| `baseline`       |
| `COUNT_THRESHOLD` | `1`               | raise after calibration                 |
| window floor      | `24h`             | minimum lookback                        |
| window cap        | `30d`             | maximum lookback                        |
| per-tick cap `N`  | `10`              | top-N by `total_count`; log dropped     |
| service / env     | `entityplatform-api` / `prod` | v1 scope                    |
| cadence           | self-paced ~24h   | shorten on activity, lengthen when quiet|

## Open questions / future

- v2: extend scope to `entityplatform-ui` (browser platform) and/or stage.
- v2: optionally write Datadog state (mark IGNORED) when the gate drops noise,
  closing the loop on housekeeping.
- Assignee routing (CODEOWNERS-based) is deferred — v1 leaves issues unassigned.
