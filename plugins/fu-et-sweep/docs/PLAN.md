# Datadog Error Tracking Sweep Loop — Implementation Plan

> **Historical artifact.** This is the original (executed) plan. Since v0.2.0 the
> Datadog access layer was switched from the bundled `au-datadog-mcp` MCP server to
> the `pup` Datadog CLI (run via Bash). Wherever this doc says `mcp__au-datadog-mcp__*`
> / `search`/`get`/`analyze` MCP tools, the live design uses `pup error-tracking
> issues search|get` + `pup traces/logs search '@issue.id:<id>'`. See `DESIGN.md`
> (current) and the `datadog-pup` skill. Left unedited below to preserve history.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `/et-sweep` slash command (run via `/loop`) that sweeps `entityplatform-api` prod Datadog Error Tracking, de-dups against GitHub, drafts root-cause writeups in token-isolated subagents, and files/reopens GitHub issues.

**Architecture:** Deterministic, bug-prone logic (window clamp, filter, dedup classification, title/marker) lives in a pure, unit-tested Node ES module (`scripts/et-sweep/sweep-lib.mjs`) with a thin CLI wrapper (`sweep.mjs`). Judgement lives in two custom subagents (`et-triage-gate`, `et-investigator`) whose large context never returns to the orchestrator. The `/et-sweep` command orchestrates and stays context-thin. GitHub is the dedup store; a gitignored state file fixes the window-gap problem.

**Tech Stack:** Node 26 ESM + `node:test` (no new deps), Claude Code slash command + custom agents, `gh` CLI, `mcp__au-datadog-mcp__*` Error Tracking tools, codegraph.

**Spec:** `docs/superpowers/specs/2026-06-15-datadog-error-tracking-sweep-loop-design.md`

**Conventions for every commit:** conventional-commit format (repo enforces `commit-lint`); end messages with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer. Implementation commits are fine; do NOT commit the spec or plan files.

---

## File Structure

- Create `scripts/et-sweep/sweep-lib.mjs` — pure functions: `windowStartMs`, `passesFilter`, `classify`, `buildMarker`, `extractIssueId`, `buildTitle`. No I/O.
- Create `scripts/et-sweep/sweep-lib.test.mjs` — `node:test` unit tests for the above.
- Create `scripts/et-sweep/sweep.mjs` — thin CLI: `window`, `filter-batch`, `classify`, `title`, `marker`. Converts ISO↔ms; delegates to the lib.
- Create `.claude/agents/et-triage-gate.md` — metadata-only triage subagent (no tools).
- Create `.claude/agents/et-investigator.md` — deep-dive + file/reopen subagent.
- Create `.claude/commands/et-sweep.md` — the per-tick orchestrator.
- Runtime state (not created by a task; written by the command): `/home/fu/.claude/entityplatform-et-sweep-state.json` — `{last_successful_tick, baseline_done}`. Outside the repo, so no gitignore edit and no write-guard conflict.

> **Worktree note:** `scripts/` is NOT exempt from the repo's main-dir write-guard. Execute this plan inside a worktree (superpowers:using-git-worktrees) — the guard exempts `.worktrees/`. `.claude/` and `docs/superpowers/` are already exempt.

---

## Task 1: Worktree + scaffold

**Files:**
- Create: `scripts/et-sweep/` (directory)

- [ ] **Step 1: Create the worktree**

Run (via EnterWorktree tool, name `feat/et-sweep`, or):
```bash
git worktree add .claude/worktrees/et-sweep -b feat/et-sweep
```
Then run the setup-worktree skill (copies `.env`). Work from the worktree root for all subsequent tasks.

- [ ] **Step 2: Create the script directory**

```bash
mkdir -p scripts/et-sweep
```
Expected: directory exists, `ls scripts/et-sweep` is empty.

---

## Task 2: Pure logic library (TDD)

**Files:**
- Create: `scripts/et-sweep/sweep-lib.test.mjs`
- Create: `scripts/et-sweep/sweep-lib.mjs`

- [ ] **Step 1: Write the failing tests**

Create `scripts/et-sweep/sweep-lib.test.mjs`:
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  windowStartMs, passesFilter, classify,
  buildMarker, extractIssueId, buildTitle,
} from './sweep-lib.mjs';

const DAY = 24 * 60 * 60 * 1000;
const NOW = 1_000_000_000_000;

test('windowStartMs: first run (no last tick) defaults to now-24h', () => {
  assert.equal(windowStartMs(null, NOW), NOW - DAY);
});

test('windowStartMs: recent tick clamps to the 24h floor', () => {
  assert.equal(windowStartMs(NOW - 60 * 60 * 1000, NOW), NOW - DAY);
});

test('windowStartMs: older tick extends back to that tick', () => {
  const lastTick = NOW - 5 * DAY;
  assert.equal(windowStartMs(lastTick, NOW), lastTick);
});

test('windowStartMs: very old tick is capped at 30d', () => {
  assert.equal(windowStartMs(NOW - 90 * DAY, NOW), NOW - 30 * DAY);
});

test('passesFilter: recent and above threshold passes', () => {
  assert.equal(passesFilter({ firstSeenMs: NOW - 2 * 60 * 60 * 1000, isRegression: false, totalCount: 5 }, NOW - DAY, 1), true);
});

test('passesFilter: old and not a regression fails', () => {
  assert.equal(passesFilter({ firstSeenMs: NOW - 10 * DAY, isRegression: false, totalCount: 100 }, NOW - DAY, 1), false);
});

test('passesFilter: old but a regression passes', () => {
  assert.equal(passesFilter({ firstSeenMs: NOW - 10 * DAY, isRegression: true, totalCount: 5 }, NOW - DAY, 1), true);
});

test('passesFilter: below the count threshold fails', () => {
  assert.equal(passesFilter({ firstSeenMs: NOW, isRegression: false, totalCount: 0 }, NOW - DAY, 1), false);
});

test('classify: no matches -> NEW', () => {
  assert.deepEqual(classify([]), { kind: 'NEW' });
});

test('classify: an open match -> ALREADY_OPEN', () => {
  assert.deepEqual(classify([{ number: 12, state: 'OPEN' }]), { kind: 'ALREADY_OPEN', number: 12 });
});

test('classify: a closed match -> REGRESSION', () => {
  assert.deepEqual(classify([{ number: 9, state: 'CLOSED' }]), { kind: 'REGRESSION', number: 9 });
});

test('classify: open wins over closed', () => {
  assert.deepEqual(
    classify([{ number: 9, state: 'CLOSED' }, { number: 12, state: 'OPEN' }]),
    { kind: 'ALREADY_OPEN', number: 12 },
  );
});

test('marker round-trips through extractIssueId', () => {
  const id = 'a3d45410-38d4-11f1-b7c1-da7ad0900000';
  assert.equal(extractIssueId(buildMarker(id)), id);
});

test('extractIssueId: no marker -> null', () => {
  assert.equal(extractIssueId('no marker here'), null);
});

test('buildTitle: short message kept whole, dotted type shortened', () => {
  assert.equal(buildTitle('System.NullReferenceException', 'boom'), '[Datadog] NullReferenceException: boom');
});

test('buildTitle: long message truncated, title stays <= 80 chars', () => {
  const t = buildTitle('System.Exception', 'x'.repeat(200));
  assert.ok(t.length <= 80, `len ${t.length}`);
  assert.ok(t.endsWith('…'));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test scripts/et-sweep/sweep-lib.test.mjs`
Expected: FAIL — cannot resolve `./sweep-lib.mjs` (module not found).

- [ ] **Step 3: Write the implementation**

Create `scripts/et-sweep/sweep-lib.mjs`:
```js
// Pure, dependency-free helpers for the /et-sweep loop.
// No I/O, no network, no Date.now() — fully unit-testable.

const DAY_MS = 24 * 60 * 60 * 1000;

// Search window start (epoch ms). Always covers >= 24h, never reaches > 30d
// back, otherwise extends back to the last completed tick. First run => now-24h.
export function windowStartMs(lastTickMs, nowMs) {
  const floor = nowMs - DAY_MS;       // newest allowed start (guarantees 24h)
  const cap = nowMs - 30 * DAY_MS;    // oldest allowed start (caps at 30d)
  if (!lastTickMs) return floor;
  return Math.max(cap, Math.min(lastTickMs, floor));
}

// Cheap candidate filter. issue: {firstSeenMs, isRegression, totalCount}.
export function passesFilter(issue, windowStart, countThreshold) {
  const recentOrRegressed = issue.firstSeenMs >= windowStart || issue.isRegression === true;
  return recentOrRegressed && issue.totalCount >= countThreshold;
}

// Classify a candidate from its GitHub marker-search matches.
// matches: [{number, state:'OPEN'|'CLOSED'}]. Open wins over closed (no churn).
export function classify(matches) {
  if (!matches || matches.length === 0) return { kind: 'NEW' };
  const open = matches.find((m) => m.state === 'OPEN');
  if (open) return { kind: 'ALREADY_OPEN', number: open.number };
  return { kind: 'REGRESSION', number: matches[0].number };
}

const MARKER_RE = /<!--\s*dd-et-issue:\s*([0-9a-f-]+)\s*-->/i;

export function buildMarker(issueId) {
  return `<!-- dd-et-issue: ${issueId} -->`;
}

export function extractIssueId(body) {
  const m = (body || '').match(MARKER_RE);
  return m ? m[1] : null;
}

// GitHub issue title; truncates the message so the title stays around 80 chars.
export function buildTitle(errorType, message) {
  const shortType = errorType.includes('.') ? errorType.split('.').pop() : errorType;
  const prefix = `[Datadog] ${shortType}: `;
  const budget = Math.max(20, 80 - prefix.length);
  const oneLine = (message || '').replace(/\s+/g, ' ').trim();
  const msg = oneLine.length > budget ? `${oneLine.slice(0, budget - 1).trimEnd()}…` : oneLine;
  return prefix + msg;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test scripts/et-sweep/sweep-lib.test.mjs`
Expected: PASS — all tests pass (0 fail).

- [ ] **Step 5: Commit**

```bash
git add scripts/et-sweep/sweep-lib.mjs scripts/et-sweep/sweep-lib.test.mjs
git commit -m "feat(et-sweep): add tested pure-logic library for window/filter/dedup"
```

---

## Task 3: CLI wrapper

**Files:**
- Create: `scripts/et-sweep/sweep.mjs`

- [ ] **Step 1: Write the CLI**

Create `scripts/et-sweep/sweep.mjs`:
```js
#!/usr/bin/env node
// Thin CLI over sweep-lib. Converts ISO<->ms; prints JSON or strings to stdout.
// Usage:
//   node sweep.mjs window [lastTickMs|null]
//   node sweep.mjs filter-batch '<issuesJson>' <windowStartMs> <threshold>
//   node sweep.mjs classify '<matchesJson>'
//   node sweep.mjs title '<errorType>' '<message>'
//   node sweep.mjs marker '<issueId>'
import {
  windowStartMs, passesFilter, classify, buildTitle, buildMarker,
} from './sweep-lib.mjs';

const [, , cmd, ...args] = process.argv;

function out(v) {
  process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
  process.stdout.write('\n');
}

switch (cmd) {
  case 'window': {
    const lastTick = args[0] && args[0] !== 'null' ? Number(args[0]) : null;
    const now = Date.now();
    const startMs = windowStartMs(lastTick, now);
    out({ startMs, startIso: new Date(startMs).toISOString(), nowMs: now });
    break;
  }
  case 'filter-batch': {
    // issues: [{issueId, errorType, errorMessage, firstSeenIso, isRegression, totalCount, ...}]
    const issues = JSON.parse(args[0]);
    const windowStart = Number(args[1]);
    const threshold = Number(args[2]);
    const passers = issues.filter((i) =>
      passesFilter(
        { firstSeenMs: Date.parse(i.firstSeenIso), isRegression: !!i.isRegression, totalCount: Number(i.totalCount) },
        windowStart,
        threshold,
      ));
    out(passers);
    break;
  }
  case 'classify': {
    out(classify(JSON.parse(args[0])));
    break;
  }
  case 'title': {
    out(buildTitle(args[0], args[1]));
    break;
  }
  case 'marker': {
    out(buildMarker(args[0]));
    break;
  }
  default:
    process.stderr.write(`unknown command: ${cmd}\n`);
    process.exit(1);
}
```

- [ ] **Step 2: Smoke-test each subcommand**

Run:
```bash
node scripts/et-sweep/sweep.mjs window null
node scripts/et-sweep/sweep.mjs classify '[{"number":7,"state":"CLOSED"}]'
node scripts/et-sweep/sweep.mjs title 'System.NullReferenceException' 'Object reference not set'
node scripts/et-sweep/sweep.mjs marker 'a3d45410-38d4-11f1-b7c1-da7ad0900000'
node scripts/et-sweep/sweep.mjs filter-batch '[{"issueId":"x","firstSeenIso":"2099-01-01T00:00:00Z","isRegression":false,"totalCount":5}]' 0 1
```
Expected, respectively: a JSON object with `startMs/startIso/nowMs`; `{"kind":"REGRESSION","number":7}`; `[Datadog] NullReferenceException: Object reference not set`; `<!-- dd-et-issue: a3d45410-38d4-11f1-b7c1-da7ad0900000 -->`; a one-element JSON array.

- [ ] **Step 3: Commit**

```bash
git add scripts/et-sweep/sweep.mjs
git commit -m "feat(et-sweep): add CLI wrapper over the pure logic library"
```

---

## Task 4: Subagent definitions

**Files:**
- Create: `.claude/agents/et-triage-gate.md`
- Create: `.claude/agents/et-investigator.md`

- [ ] **Step 1: Create the triage-gate agent**

Create `.claude/agents/et-triage-gate.md`:
```markdown
---
name: et-triage-gate
description: Metadata-only triage of one Datadog Error Tracking issue — decides if it is actionable enough to warrant a GitHub issue. Makes no tool calls.
tools: []
---

You judge ONE Datadog Error Tracking issue from its metadata alone. Make NO tool calls. Return ONLY a JSON object — no prose, no code fences.

Decide: is this a genuine, application-level, actionable error worth a GitHub issue?

DROP (actionable=false) when it is transient/infra noise:
- Client-cancelled requests: TaskCanceledException / OperationCanceledException whose frame is HttpConnection.SendAsync or TaskCompletionSourceWithCancellation — the caller hung up.
- Transient DNS / connectivity: "Name or service not known", "Connection refused", SocketException at ConnectToTcpHostAsync, to an external host.
- Upstream 5xx passthrough with no EP-owned frame.

KEEP (actionable=true) when it points at EP application logic:
- NullReferenceException, ArgumentException, InvalidOperationException with an EP frame.
- Unhandled domain exceptions thrown from api-dotnet code.
- EF Core / Npgsql failures originating in an EP query/command (not a plain user-cancel).
- Anything you cannot confidently call noise — default to KEEP so a human sees it.

suspected_severity: high (data loss / crash / auth break), med (a feature broken for some users), low (degraded / cosmetic / rare).

Return exactly this shape:
{"actionable": true, "reason": "<=15 words", "suspected_severity": "med"}
```

- [ ] **Step 2: Create the investigator agent**

Create `.claude/agents/et-investigator.md`:
```markdown
---
name: et-investigator
description: Deep-dives ONE actionable Datadog Error Tracking issue — fetches details, traces to entityplatform-api source via codegraph, drafts a root-cause writeup, and (live mode) files or reopens the GitHub issue. Returns a one-line receipt only.
tools: All tools
---

You investigate ONE Datadog Error Tracking issue end to end and return ONLY a one-line receipt. Your large working context (stack traces, analyze output, source) MUST stay with you — never echo it back to the caller; it belongs in the GitHub issue body.

You are given: issue_id, classification ("NEW", or "REGRESSION" with the existing gh issue number), mode ("observe" | "live"), and the issue metadata (error_type, error_message, service, platform, total_count, first_seen, first_seen_version, last_seen, last_seen_version, function_name).

Steps:
1. mcp__au-datadog-mcp__get_datadog_error_tracking_issue(issue_id) — full stack + attributes.
2. mcp__au-datadog-mcp__analyze_datadog_error_tracking_errors(issue_id) — sample events / pattern. Keep max_tokens modest (<= 4000).
3. From the top EP-owned stack frame (namespace InfoTrack*, file under api-dotnet/), use codegraph_trace / codegraph_node to locate the code path. Skip BCL/framework frames.
4. Draft a root-cause writeup: 1-3 short paragraphs — what throws, why, the traced path — plus the suspected `file:line`. Mark it explicitly as a draft.
5. Build the issue body exactly per the template in docs/superpowers/specs/2026-06-15-datadog-error-tracking-sweep-loop-design.md: the hidden marker first, then Datadog link, Error, Occurrence, Suspected root cause, Suspected code location, footer. Use bold labels, NOT '#' headers. Get the marker via `node scripts/et-sweep/sweep.mjs marker <issue_id>` and the title via `node scripts/et-sweep/sweep.mjs title '<error_type>' '<error_message>'`.

If mode == "observe": do NOT touch GitHub. Return: `observed: would-<create|reopen> (<sev>) — <title>`.

If mode == "live":
- NEW: `gh issue create --title "<title>" --label datadog-error-tracking,auto-filed,sev:<sev> --body "<body>"`. Return `#<n> created (<sev>)`.
- REGRESSION (existing #N): `gh issue reopen <N>`; then `gh issue comment <N> --body "<regression comment block>"`. Return `#<N> reopened (<sev>)`.
- On any gh failure: print the full drafted body so it is not lost, then return `FAILED <issue_id>: <reason>`.

Return ONLY the one-line receipt (plus the body dump on failure). Nothing else.
```

- [ ] **Step 3: Commit**

```bash
git add .claude/agents/et-triage-gate.md .claude/agents/et-investigator.md
git commit -m "feat(et-sweep): add triage-gate and investigator subagents"
```

---

## Task 5: Sweep command — observe mode

**Files:**
- Create: `.claude/commands/et-sweep.md`

- [ ] **Step 1: Create the command (observe path complete; live/baseline stubbed for Task 6)**

Create `.claude/commands/et-sweep.md`:
```markdown
---
description: One sweep of entityplatform-api prod Datadog Error Tracking -> GitHub issues (de-duped, root-caused). Run via /loop for a self-paced watch.
---

You are running ONE tick of the Error Tracking sweep. Keep YOUR context tiny: never read stack traces or draft writeups yourself — that is the investigator subagent's job. You only orchestrate.

Arguments: $ARGUMENTS
- mode: "--observe" (default), "--live", or "--baseline".
- optional "--count N" overrides the count threshold (default 1).
- STATE_FILE = /home/fu/.claude/entityplatform-et-sweep-state.json
- SERVICE_QUERY = service:entityplatform-api env:prod

Procedure:

1. Read state: `cat $STATE_FILE 2>/dev/null`. Parse {last_successful_tick, baseline_done} (epoch ms). Missing/empty = first run (last_successful_tick = null).

2. Compute window: `node scripts/et-sweep/sweep.mjs window <last_successful_tick|null>`. Capture startMs, startIso, nowMs.

3. Search: mcp__au-datadog-mcp__search_datadog_error_tracking_issues with query SERVICE_QUERY, from=startIso, to="now", order_by="TOTAL_COUNT", max_tokens=8000. If the result is truncated, remember remaining_items for the summary.

4. Map each returned issue to {issueId, errorType, errorMessage, firstSeenIso, isRegression, totalCount, firstSeenVersion, lastSeenIso, lastSeenVersion, functionName, platform}. Then filter: `node scripts/et-sweep/sweep.mjs filter-batch '<issuesJson>' <startMs> <threshold>`. Survivors = the printed array.

5. Dedup each survivor: `gh issue list --state all --search "<issueId>" --json number,state,title` then `node scripts/et-sweep/sweep.mjs classify '<matchesJson>'` (map gh `state` values OPEN/CLOSED). Drop survivors classified ALREADY_OPEN. Sort remaining by totalCount desc; if more than 10, keep the top 10 and record "dropped <k> over cap".

6. Triage: dispatch the `et-triage-gate` agent once per survivor, passing only the metadata. Keep survivors whose result has actionable=true; remember each verdict + reason.

7. Observe mode (this task): do NOT dispatch the investigator and do NOT touch GitHub. Print a table with columns: issue_id (short) | error_type | count | classification | triage (actionable + reason) | would-be-action (create / reopen #N / drop-noise). Then print the summary line (step 9). Do NOT write state in observe mode.

8. (Live / baseline modes — added in the next task.)

9. Summary line: counts {searched, candidates, deduped, actionable, would-file, dropped-over-cap, search-truncated-remaining}.
```

- [ ] **Step 2: Verify observe mode against real data**

In the session, run: `/et-sweep --observe`
Expected: a table containing the one known `entityplatform-api` issue (`TaskCanceledException` at `HttpConnection.SendAsync`, count 1 in window — note the default threshold is 1). Its classification should be `NEW` (no GitHub issue exists yet), triage verdict `actionable=false` (client-cancel noise), would-be-action `drop-noise`. Summary shows `would-file: 0`. No GitHub issue created, no state file written.

- [ ] **Step 3: Commit**

```bash
git add .claude/commands/et-sweep.md
git commit -m "feat(et-sweep): add sweep command observe mode"
```

---

## Task 6: Sweep command — live, baseline, state, cap

**Files:**
- Modify: `.claude/commands/et-sweep.md` (replace step 8 stub; extend steps 7 and the post-tick state write)

- [ ] **Step 1: Replace the step 8 stub with live + baseline logic**

In `.claude/commands/et-sweep.md`, replace the line:
```markdown
8. (Live / baseline modes — added in the next task.)
```
with:
```markdown
8. Mode handling:

   BASELINE mode: skip triage (step 6). For each survivor classified NEW, create a stub: title via `node scripts/et-sweep/sweep.mjs title '<error_type>' '<error_message>'`, then `gh issue create --title "<title>" --label datadog-error-tracking,et-baseline --body "<marker>\n\n**Datadog:** <issue url>"` (marker via `sweep.mjs marker <issueId>`; NO writeup). Survivors classified REGRESSION/ALREADY_OPEN are left untouched. Set baseline_done=true. Skip the investigator entirely.

   LIVE mode: for each actionable survivor (from step 6), dispatch the `et-investigator` agent with {issue_id, classification (+gh number if REGRESSION), mode="live", metadata}. Collect the one-line receipts. The investigator itself creates/reopens the GitHub issue.

   OBSERVE mode: for each actionable survivor, dispatch `et-investigator` with mode="observe" to get the drafted would-be-action receipt (it files nothing), OR keep the lightweight step-7 table if you want zero investigator spend. Default: lightweight table (no investigator) to minimise tokens.

   After mode handling, if the tick COMPLETED (even with per-candidate skips), write state: `echo '{"last_successful_tick": <nowMs from step 2>, "baseline_done": <bool>}' > $STATE_FILE`. Do NOT write state if the tick aborted before search returned. Observe mode does not write state.
```

- [ ] **Step 2: Add resilience + self-pace note at the end of the file**

Append to `.claude/commands/et-sweep.md`:
```markdown

Resilience:
- Wrap each per-candidate operation so one failing issue (search/get/gh/subagent error) is logged with its issue_id and skipped — never abort the whole tick.
- Per-tick cap is 10 (top by total_count); always log the dropped count, never truncate silently.

Self-pace (only when invoked under /loop):
- After the summary, schedule the next wake ~24h out. Shorten toward a few hours if this tick filed anything (active period); lengthen when quiet. The runtime clamps the delay.
```

- [ ] **Step 3: Verify the full create -> dedup -> reopen cycle (controlled, with cleanup)**

This exercises live mechanics deterministically using the one benign known issue, then cleans up.

Run the baseline path to create one real stub issue:
```
/et-sweep --baseline
```
Expected: one GitHub issue created titled `[Datadog] TaskCanceledException: ...`, labels `datadog-error-tracking,et-baseline`, body containing the marker `<!-- dd-et-issue: a3d45410-38d4-11f1-b7c1-da7ad0900000 -->`. State file now exists with `baseline_done: true`.

Verify dedup (idempotency):
```
/et-sweep --baseline
```
Expected: the same issue classifies `ALREADY_OPEN` and is left untouched — no second issue created.

Verify regression reopen:
```bash
gh issue close <the new number>
```
```
/et-sweep --baseline
```
Expected: classification `REGRESSION-of-#<n>`; in baseline mode it is left untouched (baseline only creates NEW). To verify the reopen path itself, instead run `/et-sweep --live --count 1` after closing — the investigator reopens `#<n>` and comments. (Triage will drop this specific noise issue, so to exercise reopen you may temporarily edit the triage agent to KEEP it, then revert.)

- [ ] **Step 4: Clean up the test artifact**

```bash
gh issue delete <the new number> --yes
rm -f /home/fu/.claude/entityplatform-et-sweep-state.json
```
Expected: test issue gone, state reset for a clean first real run.

- [ ] **Step 5: Commit**

```bash
git add .claude/commands/et-sweep.md
git commit -m "feat(et-sweep): add live, baseline, state persistence and per-tick cap"
```

---

## Task 7: Usage docs

**Files:**
- Create: `docs/error-tracking-sweep.md`
- Modify: `CLAUDE.md` (add one pointer line)

- [ ] **Step 1: Write the usage doc**

Create `docs/error-tracking-sweep.md`:
```markdown
# Error Tracking Sweep (/et-sweep)

`/et-sweep` watches `entityplatform-api` prod Datadog Error Tracking and files
de-duped GitHub issues with drafted root-cause writeups. Run it in a live Claude
Code session (the Datadog AU + GitHub MCPs must be authenticated).

## Modes

- `/et-sweep --observe` (default) — prints what it WOULD file; files nothing. Use
  this to calibrate noise and the count threshold.
- `/et-sweep --live` — files new issues and reopens regressions for real.
- `/et-sweep --baseline` — one-time: records existing issues as known stubs
  (label `et-baseline`) without writeups, so the first live run does not flood.
- `--count N` — override the occurrence threshold (default 1).

## Self-paced watch

Run under the loop: `/loop /et-sweep --live`. It self-paces ~daily, shortening
when a tick files something and lengthening when quiet.

## How de-dup works

Each filed issue carries a hidden marker `<!-- dd-et-issue: <id> -->` and the
`datadog-error-tracking` label. Before filing, the sweep searches all GitHub
issues for the Datadog `issue_id`: an open match is skipped, a closed match is
reopened + commented. One Datadog issue maps to at most one GitHub issue, ever.

## Pieces

- `.claude/commands/et-sweep.md` — the per-tick orchestrator.
- `.claude/agents/et-triage-gate.md` — metadata-only noise filter.
- `.claude/agents/et-investigator.md` — deep-dive + file/reopen (token-isolated).
- `scripts/et-sweep/sweep-lib.mjs` (+ tests) — pure window/filter/dedup logic.
- `scripts/et-sweep/sweep.mjs` — CLI wrapper used by the command.
- State: `~/.claude/entityplatform-et-sweep-state.json`.

Design: `docs/superpowers/specs/2026-06-15-datadog-error-tracking-sweep-loop-design.md`.
```

- [ ] **Step 2: Add a pointer in CLAUDE.md**

In `CLAUDE.md`, after the "## Risk Callbacks" section pointer block, add:
```markdown
## Error Tracking Sweep

[/et-sweep loop: Datadog Error Tracking -> de-duped GitHub issues with drafted root-cause writeups, observe/live/baseline modes, token-isolated investigator subagent →](docs/error-tracking-sweep.md)
```

- [ ] **Step 3: Run the lib tests once more as a regression gate**

Run: `node --test scripts/et-sweep/sweep-lib.test.mjs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add docs/error-tracking-sweep.md CLAUDE.md
git commit -m "docs(et-sweep): document the error tracking sweep loop"
```

---

## Task 8: Acceptance + finish

- [ ] **Step 1: Final observe run (clean state)**

Run: `/et-sweep --observe`
Expected: table renders, the known noise issue shows `drop-noise`, `would-file: 0`, no state written, no GitHub mutation.

- [ ] **Step 2: Confirm no stray artifacts**

```bash
git status
gh issue list --label datadog-error-tracking --state all
```
Expected: working tree clean (all committed); no leftover test issues from Task 6.

- [ ] **Step 3: Finish the branch**

Use the superpowers:finishing-a-development-branch skill to open the PR for `feat/et-sweep` (do NOT commit the spec/plan files under `docs/superpowers/`).

---

## Self-Review

**Spec coverage:**
- Execution model (/loop live session) → Tasks 5–6 + usage doc. ✓
- Subagent funnel (triage gate → investigator), token isolation → Task 4 + command steps 6/8. ✓
- Gap-safe window (`max(now-30d, min(lastTick, now-24h))`) → Task 2 `windowStartMs` + tests. ✓
- Cheap filter (recent OR regression AND count≥N) → Task 2 `passesFilter` + tests. ✓
- Dedup classification (NEW / ALREADY_OPEN / REGRESSION, open-wins) → Task 2 `classify` + tests; command step 5. ✓
- Regression = reopen + comment → investigator agent + Task 6 step 3. ✓
- Issue format (title prefix `[Datadog]`, marker, labels, no `#` headers) → `buildTitle`/`buildMarker` + investigator + spec template. ✓
- Observe / live / baseline modes + first-run flood guard → Tasks 5–6. ✓
- Count threshold default 1, tunable → CLI + command `--count`. ✓
- Per-tick cap (10) + log dropped → command step 5 + resilience note. ✓
- State file (gitignored/out-of-tree) + advance-on-complete → Task 6. ✓
- Resilience (per-candidate skip, state advance rules) → Task 6 resilience note. ✓
- Self-pace under /loop → Task 6 self-pace note + usage doc. ✓

**Placeholder scan:** No TBD/TODO; all code blocks complete; the one "temporarily edit triage to exercise reopen" is an explicit, reversible verification instruction, not a code gap.

**Type/name consistency:** `windowStartMs`, `passesFilter`, `classify`, `buildMarker`, `extractIssueId`, `buildTitle` are spelled identically in lib, tests, CLI, and command. CLI subcommands (`window`, `filter-batch`, `classify`, `title`, `marker`) match the command's invocations. Marker string `<!-- dd-et-issue: <id> -->` identical in lib, agent, spec, doc. Labels `datadog-error-tracking` / `auto-filed` / `et-baseline` / `sev:<...>` consistent across agent, command, doc.
