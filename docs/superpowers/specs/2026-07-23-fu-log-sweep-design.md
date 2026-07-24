# fu-log-sweep — Datadog Logs → GitHub Issue Sweep Loop — Design

**Date:** 2026-07-23
**Status:** Design approved; implementation pending
**Author:** fu + Claude

## Problem

`fu-et-sweep` turns Datadog **Error Tracking** issues into de-duped GitHub
issues with root-cause writeups, run as a self-paced `/loop`. Error Tracking is
not the only place dotnet errors surface: error-level **logs** (`status:error`
— handled/logged exceptions via Serilog) frequently never become an ET issue,
and some services may not have ET enabled at all. We want the same
watch → de-dup → file-GitHub-issue → track pipeline, sourced from **Datadog
Logs** instead of Error Tracking.

The one genuinely new problem: Error Tracking pre-groups events server-side into
issues with a stable `issue_id`, which is et-sweep's entire dedup spine. **Raw
logs are not pre-grouped.** So a logs sweep must compute its own stable error
**signature** (fingerprint) to dedup on. Everything else reuses et-sweep.

## Goals

- File a GitHub issue (with root-cause writeup) for new/regressed, actionable
  `status:error` logs, sourced from Datadog Logs (not Error Tracking).
- Compute a stable, refactor-tolerant signature per distinct error so the same
  bug never produces two GitHub issues.
- Reopen + comment on regressions instead of filing fresh (GitHub is authority).
- Keep the main loop context small and flat across many ticks (subagent
  isolation, same as et-sweep).
- Start in an observation phase to calibrate noise + verify Datadog facet names
  before filing anything.

## Non-goals

- Replacing or modifying `fu-et-sweep` — this is a **sibling plugin**; et-sweep
  stays stable and untouched.
- Writing Datadog state back (archive/exclude a log pattern) — out of scope v1.
- Auto-fixing / opening PRs — the writeup is a draft, not a verdict.
- APM error spans as a source — v1 is logs only (spans deferred; the fingerprint
  core is source-shaped so a span source could be added later).
- Unattended cloud/cron execution — v1 runs in a live `/loop` session where
  `pup` (Datadog) and `gh` are authenticated.

## Decisions (from brainstorming)

1. **Source:** Datadog **Logs** (`status:error`). Broadest net; catches
   handled/logged errors ET never surfaced.
2. **Fingerprint:** **hybrid** — Datadog does the cheap server-side fan-in
   (`logs aggregate` by `@error.kind` + `service` → a handful of buckets +
   counts, zero client parsing); we then fetch one sample per surviving bucket
   and compute a `type + top-app-frame` signature client-side. Datadog does the
   million-log heavy lifting; we parse a handful of stacks.
3. **Packaging:** **new sibling plugin `fu-log-sweep`**. Own
   command/agents/scripts. Copies et-sweep's small pure-lib helpers (window,
   classify, marker, title, config) and adds the net-new fingerprint core. Own
   version, own marker (`dd-log-sig`), own labels. YAGNI on a shared abstraction
   until a third consumer exists.

## Execution model

- A slash command `/log-sweep` holds the per-tick procedure, run via `/loop`
  (self-paced) or one-shot. Thin orchestrator; never reads stacks or drafts
  prose itself.
- Runs in a live Claude Code session so the `pup` Datadog CLI (`pup auth login`)
  and `gh` are authenticated. Datadog access is `pup` via Bash — no MCP server.
  A `401` needs an interactive `pup auth login`.

## Architecture

Components (reuse map):

| Component | Provenance |
|---|---|
| **Loop driver** — `/log-sweep` command, thin | copy et-sweep command shape |
| **Pure-logic lib** — `log-sweep-lib.mjs` | copy window/classify/marker/title/config from `sweep-lib.mjs` + **net-new fingerprint core**; `node:test`-covered |
| **Triage-gate subagent** — `log-triage-gate` (metadata → `{actionable, reason, suspected_severity}`, no Datadog reads) | copy `et-triage-gate` |
| **Investigation subagent** — `log-investigator` (signature in; `pup logs search` sample stack + codegraph trace → writeup → gh create/reopen; one-line receipt out) | copy `et-investigator`, swap the fetch |
| **GitHub** — dedup store + output sink | marker `<!-- dd-log-sig: <hash> -->` |
| **State file** — `{ last_successful_tick, baseline_done }` (epoch ms), gitignored, `$HOME/.claude/log-sweep-state-<repoKey>.json` | same gap-safe window as et-sweep |

### Data flow per tick

```
1. pup logs aggregate  (Datadog groups server-side, cheap; NO client parsing)
     --query "service:(...) env:<env> status:error"
     --from <win_start> --to now
     --group-by @error.kind, service
        │   → buckets [{errorKind, service, count}]
2. count-prune (main ctx): drop buckets with count < COUNT_THRESHOLD;
     cap top-N buckets by count (~20) to bound the sample fetches below
        │
3. per surviving bucket: fetch ONE sample event
     pup logs search --query "... @error.kind:<k> service:<s>"
        --from <win_start> --to now --limit 1   (newest)
        │   → sample @error.stack, @error.message
4. compute signature (pure lib):
     topFrame = firstAppFrame(@error.stack, appNamespace)  # skip System.*/Microsoft.*
     sig = sha1(errorKind | service | normalizeFrame(topFrame)).slice(0,12)
        │   (fallback ladder below when no app frame / no stack)
5. dedup classification (main ctx) — regression authority, SAME as et-sweep:
     gh issue list --repo <repo> --state all --search "<sig>"
       no match     → NEW
       match, open   → ALREADY_OPEN (skip)
       match, closed → REGRESSION-of-#N (isRegression=true)
     sort by count desc; cap N=10 (log dropped)
        │
6. fan out survivors:
     ├─ triage-gate subagent  → actionable? ──no──> drop (shown in observe)
     └─ investigation subagent (actionable only):
            pup logs search <sig-bucket query> for richer sample + codegraph → writeup
            NEW        → gh issue create (+marker +labels)   [live]
            REGRESSION → gh issue reopen #N + comment        [live]
            (observe mode: draft only, file nothing)
        │
7. collect one-line receipts → summarise → advance last_successful_tick
   → ScheduleWakeup (self-paced)
```

**Key reorder vs et-sweep.** et-sweep dedups *before* hydrate because the
`issue_id` dedup key is free from search. Here the dedup key **is** the computed
fingerprint, which needs a sample event — so **fingerprint (steps 3-4) comes
before dedup (step 5)**. Cost stays bounded: `aggregate` collapses millions of
logs into a few buckets, count-prune + top-N cap trims them, and each survivor
costs one cheap `logs search --limit 1`. Main context per tick holds only the
bucket list, signatures, candidate tags, and receipts — everything heavy is
subagent-scoped.

## Fingerprint core (the crux — pure, testable)

New functions in `log-sweep-lib.mjs` (dependency-free except `node:crypto`,
which is deterministic and stdlib — preserves the no-I/O, unit-testable split):

- `firstAppFrame(stackText, appNsPrefixes)` → the `Namespace.Class.Method` of
  the first stack frame whose namespace matches an app prefix, skipping
  `System.`, `Microsoft.`, `System.Private.`, and compiler-generated frames.
  Returns `null` if none match.
- `normalizeFrame(frame)` → strip file path + line number, generic arity, and
  async state-machine wrappers (`MoveNext`, `<Method>d__12`, lambda display
  classes) so the frame is stable across recompiles/line moves.
- `computeSignature(errorKind, service, topFrameOrFallback)` → `sha1` hex,
  first 12 chars. Deterministic.
- **Fallback ladder** (each step logs lower confidence, recorded in issue body):
  1. app frame found → `type | service | normalize(appFrame)`
  2. no app frame, stack present → `type | service | normalize(firstFrame)`
  3. no stack → `type | service | normalizeMessage(message).slice(0,80)`
- `appNamespace` = config knob (`log-sweep.app_namespace`), default derived from
  the resolved service/app name (the application's root namespace prefix).
  Mirrors how the et-sweep investigator restricts its codegraph trace to
  app-owned frames.

## Dedup / tracking / regression

Identical to et-sweep. The hidden marker `<!-- dd-log-sig: <hash> -->` is the
dedup anchor — searched via `gh issue list --search`, never rendered. GitHub is
the sole regression authority: a closed-issue match routes to reopen+comment and
flags the survivor as a regression. No separate database; GitHub is the store.

| GitHub result | Classification | Action |
|---|---|---|
| no match | `NEW` | create |
| match, open | `ALREADY_OPEN` | skip |
| match, closed | `REGRESSION-of-#N` | reopen + comment |

`classify()` is copied verbatim from `sweep-lib.mjs` (open wins over closed).

## Window (gap-safe)

Copied verbatim from et-sweep (`windowStartMs`):
`window_start = max(now-30d, min(last_successful_tick, now-24h))` — always cover
≥24h, never reach >30d back, otherwise extend to the last completed tick.
`last_successful_tick` advances only on tick completion; a hard abort re-covers
the window next run (dedup prevents double-file). Newness is decided by GitHub
dedup, not by timestamps — the window only bounds the candidate set.

## GitHub issue format

**Title:** `[Datadog] <errorKind>: <topFrame | message truncated ~80 chars>`
(reuses `buildTitle`, but prefers the top app frame over the raw message when a
frame was resolved, since the message is noisy).

**Labels:** `datadog-logs` (dedup/filter scope), `auto-filed`,
`sev:low|med|high`. Baseline run also adds `log-baseline`.

**Body** (no `#` headers — bold labels, per repo prose convention):

```markdown
<!-- dd-log-sig: <hash> -->

**Datadog:** <Logs Explorer URL for this query+window>

**Error**
- Type: `<errorKind>`
- Message: <errorMessage>
- Service: `<service>` · env `<env>`
- Failing frame: `<topFrame>`   (or "unresolved — signature via <fallback level>")

**Occurrence**
- Count (window): <count>
- First seen / last seen: <from aggregate timeseries, else sample ts>

**Suspected root cause** *(drafted, verify before acting)*
<LLM writeup — 1-3 short paras: what throws, why, the traced code path>

**Suspected code location**
- `<path>:<line>` (codegraph trace)

---
*Auto-filed by /log-sweep. Regressions reopen this issue rather than filing a
new one. The root-cause section is a draft, not a verdict.*
```

The **Datadog link** is a Logs Explorer query URL (there is no ET issue page).
Its exact shape (base host + query param encoding) is confirmed against the
resolved Datadog site in the config, mirroring et-sweep's `issueUrlBase`.

**Regression comment** — same shape as et-sweep's (recurred after close; seen
again; count this window; Datadog link; one-line note if root cause shifted).

## Configuration (`fu-tools`, tool key `log-sweep`)

| Knob | Default | Notes |
|---|---|---|
| `mode` | `observe` | `observe` \| `live` \| `baseline` |
| `services` | auto-detect (k8_settings app_name) | comma-list override via `--service` |
| `env` | `prod` | `--env` |
| `repo` | auto-detect (git remote) | `--repo` |
| `status_query` | `status:error` | override to widen/narrow the base log query |
| `app_namespace` | derived from repo/app | app-frame detection prefix(es) |
| `count_threshold` | `1` | raise after calibration |
| bucket cap (pre-sample) | `20` | top-N buckets by count before sample-fetch |
| per-tick cap `N` | `10` | top-N survivors by count; log dropped |
| window floor / cap | `24h` / `30d` | reused from et-sweep |
| cadence | self-paced ~24h | shorten on activity, lengthen when quiet |

Env-var overrides accepted for the inline Bash tests, same convention as
et-sweep/dev-guards.

## Rollout (two phase)

1. **Observe** — `/log-sweep --observe`, `count_threshold = 1`. Runs
   aggregate → prune → sample+fingerprint → dedup → triage gate, prints a table
   `{sig, type, service, topFrame, count, classification, triage(actionable +
   reason), would-be-action}`, files nothing. Primary goals: **verify the
   Datadog facet names** (open question below) and calibrate noise / threshold /
   triage prompt.
2. **Live** — `/log-sweep`, calibrated. Files/reopens for real. Optional
   one-time `--baseline` records existing signatures as known stubs (label
   `log-baseline`, no writeup), bounded by the per-tick cap.

## Token / context budget

Same discipline as et-sweep: main loop ctx per tick holds only the capped bucket
list, signatures, candidate tags, one-line receipts. `aggregate` is one cheap
call; sample fetches are `--limit 1`; `get`/stack-read/codegraph payloads and
writeups live only in subagent context and return ≤1 line to the loop. Two-stage
gate (metadata triage before the investigator) kills noise before the expensive
subagent runs.

## Resilience

- Per-bucket scope: any aggregate/search/sample/fingerprint/gh/subagent failure
  → log the bucket (type+service) + reason, skip, continue the tick.
- `last_successful_tick` advances only on tick completion; hard abort re-covers
  the window (dedup prevents double-file).
- `gh` create/reopen failure after a writeup is drafted → log the full writeup
  to tick output so it is not lost; retry next tick (still NEW in dedup).
- Fingerprint fallback ladder ensures every candidate gets *some* stable key
  even when the stack is missing — low-confidence keys are labeled so they can
  be reviewed.

## Open questions (verify in observe phase, do NOT block design)

- **Datadog facet names for dotnet/Serilog logs:** `@error.kind` vs
  `@error.type`; is `@error.stack` reliably populated? Confirm against live logs
  on the first observe tick and pin the resolved names in config/lib.
- **`pup logs aggregate` interface:** confirm multi-facet `--group-by` +
  count metric shape (CLAUDE.md confirms `--group-by version` exists, so
  group-by is supported; confirm two facets + count).
- **first/last-seen per bucket:** from an aggregate timeseries if available,
  else derive from the fetched sample(s).
- **Datadog Logs Explorer URL shape** for the issue body link (host + query
  encoding) per resolved site.

## Future

- v2: APM error spans as an alternate/additional source (the fingerprint core is
  written source-shaped to allow it).
- v2: optionally extract the shared pure-logic (window/classify/marker/title)
  into a module shared with et-sweep once this is the third consumer.
- Assignee routing (CODEOWNERS) deferred — v1 leaves issues unassigned.
