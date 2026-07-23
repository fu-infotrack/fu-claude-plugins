# fu-log-sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new `fu-log-sweep` plugin that sweeps a service's Datadog error-level **Logs** into de-duped GitHub issues with drafted root-cause writeups, deduping on a *computed* error signature, run via `/loop`.

**Architecture:** Sibling to `fu-et-sweep`; reuses its loop/subagent/GitHub-dedup patterns. A thin `/log-sweep` command orchestrates one tick: `pup logs aggregate` groups errors server-side into buckets (cheap), we fetch one sample per surviving bucket and compute a `type|service|top-app-frame` sha1 signature (the ET-`issue_id` replacement), dedup that signature against GitHub, then fan out to a metadata triage gate and an investigation subagent that files/reopens the issue. Pure logic lives in a `node:test`-covered `log-sweep-lib.mjs`.

**Tech Stack:** Node (ESM, built-in test runner — no build step, no package.json), `pup` CLI for Datadog (via Bash), `gh` CLI for GitHub, Claude Code plugin manifest + subagents.

## Global Constraints

- Every value below is copied verbatim from `docs/superpowers/specs/2026-07-23-fu-log-sweep-design.md`.
- Plugin name `fu-log-sweep`; all plugins are prefixed `fu-`.
- **Register in all three:** `.claude-plugin/marketplace.json`, root `README.md` Plugins table, `CLAUDE.md` Plugins table.
- No build step, no `package.json`. Tests use Node's runner: `node --test <file>`.
- Runtime config via **fu-tools layered config**, tool key `log-sweep`. Do NOT use Claude Code `userConfig`.
- Datadog access is the `pup` CLI via Bash — **no MCP server**.
- Dedup marker: `<!-- dd-log-sig: <hash> -->`. Signature = `sha1(errorKind|service|frameKey)` hex, **first 12 chars**.
- Labels: `datadog-logs`, `auto-filed`, `sev:low|med|high`; baseline run also adds `log-baseline`.
- Base log query default: `status:error`. Query shape: `service:(...) env:<env> status:error`.
- **No InfoTrack literals in the repo.** All examples/tests use a placeholder namespace (`Acme.Widgets`). `InfoTrack.Compliance.Mono` is the observe-phase test target only, recorded in memory outside the repo.
- **Execution happens in a git worktree** (this repo's `fu-dev-guards` blocks branch ops in the main-tracked dir). Land via feature branch → PR (squash); never push `main` directly. Commit steps below target the worktree's branch.

---

### Task 1: Plugin manifest + three registries

**Files:**
- Create: `plugins/fu-log-sweep/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json` (add plugin entry)
- Modify: `README.md` (Plugins table row)
- Modify: `CLAUDE.md` (Plugins table row)

**Interfaces:**
- Produces: an installable plugin manifest at the conventional path; the marketplace entry `fu-log-sweep` → `./plugins/fu-log-sweep`.

- [ ] **Step 1: Create the manifest**

`plugins/fu-log-sweep/.claude-plugin/plugin.json`:

```json
{
  "name": "fu-log-sweep",
  "version": "0.1.0",
  "description": "Sweep a service's Datadog error-level Logs into de-duped GitHub issues with drafted root-cause writeups, deduping on a computed error signature. Run via /loop for a self-paced watch.",
  "author": {
    "name": "fu-infotrack",
    "url": "https://github.com/fu-infotrack"
  },
  "keywords": [
    "datadog",
    "logs",
    "github",
    "observability"
  ],
  "commands": "./commands/"
}
```

(Agents auto-load from the conventional `agents/` dir — `fu-et-sweep` registers its agents with no `agents` manifest key, so we match that.)

- [ ] **Step 2: Add the marketplace entry**

In `.claude-plugin/marketplace.json`, add this object to the `plugins` array immediately after the `fu-et-sweep` entry (keep it adjacent to its sibling):

```json
    { "name": "fu-log-sweep", "source": "./plugins/fu-log-sweep", "category": "productivity",
      "description": "Sweep a service's Datadog error-level Logs into de-duped GitHub issues with drafted root-cause writeups, deduping on a computed error signature." },
```

- [ ] **Step 3: Add the root README table row**

In `README.md`, find the Plugins table and add a row directly below the `fu-et-sweep` row:

```markdown
| fu-log-sweep | command + agents + scripts | Datadog error-level **Logs** → de-duped GitHub issues with root-cause writeups; dedups on a computed error signature (no Error Tracking required) |
```

- [ ] **Step 4: Add the CLAUDE.md table row**

In `CLAUDE.md`, find the `## Plugins` table and add a row directly below the `fu-et-sweep` row:

```markdown
| fu-log-sweep | command + agents + scripts | Datadog error-level Logs → de-duped GitHub issues with root-cause writeups; sibling to fu-et-sweep, dedups on a self-computed error signature (`type\|service\|top-app-frame` sha1) instead of an ET `issue_id` |
```

- [ ] **Step 5: Verify JSON is valid and all three registries mention the plugin**

Run:
```bash
jq -e '.plugins[] | select(.name=="fu-log-sweep")' .claude-plugin/marketplace.json >/dev/null \
  && jq -e . plugins/fu-log-sweep/.claude-plugin/plugin.json >/dev/null \
  && grep -q 'fu-log-sweep' README.md \
  && grep -q 'fu-log-sweep' CLAUDE.md \
  && echo OK
```
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add plugins/fu-log-sweep/.claude-plugin/plugin.json .claude-plugin/marketplace.json README.md CLAUDE.md
git commit -m "feat(fu-log-sweep): plugin manifest + registry entries"
```

---

### Task 2: Pure-logic lib — helpers copied from fu-et-sweep + buildLogQuery

**Files:**
- Create: `plugins/fu-log-sweep/scripts/log-sweep-lib.mjs`
- Test: `plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`

**Interfaces:**
- Produces (consumed by Task 4 CLI and later tasks):
  - `windowStartMs(lastTickMs, nowMs) -> number`
  - `classify(matches) -> {kind:'NEW'} | {kind:'ALREADY_OPEN', number} | {kind:'REGRESSION', number}`
  - `buildTitle(errorType, message) -> string`
  - `parseRepoFromRemote(url) -> string|null`
  - `collectServices(appNames) -> string[]`
  - `buildServiceQuery(services, env) -> string`
  - `buildLogQuery(services, env, statusQuery) -> string`
  - `mergeConfig(userObj, projectObj, autoObj, cliObj, tool) -> object`

- [ ] **Step 1: Write the failing tests**

`plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`:

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  windowStartMs, classify, buildTitle,
  parseRepoFromRemote, collectServices, buildServiceQuery, buildLogQuery, mergeConfig,
} from './log-sweep-lib.mjs';

const DAY = 24 * 60 * 60 * 1000;
const NOW = 1_000_000_000_000;

test('windowStartMs: first run defaults to now-24h', () => {
  assert.equal(windowStartMs(null, NOW), NOW - DAY);
});
test('windowStartMs: recent tick clamps to the 24h floor', () => {
  assert.equal(windowStartMs(NOW - 60 * 60 * 1000, NOW), NOW - DAY);
});
test('windowStartMs: older tick extends back to that tick', () => {
  const lastTick = NOW - 5 * DAY;
  assert.equal(windowStartMs(lastTick, NOW), lastTick);
});
test('windowStartMs: very old tick capped at 30d', () => {
  assert.equal(windowStartMs(NOW - 90 * DAY, NOW), NOW - 30 * DAY);
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

test('buildTitle: short message kept, dotted type shortened', () => {
  assert.equal(buildTitle('System.NullReferenceException', 'boom'), '[Datadog] NullReferenceException: boom');
});
test('buildTitle: long message truncated, title <= 80 chars', () => {
  const t = buildTitle('System.Exception', 'x'.repeat(200));
  assert.ok(t.length <= 80, `len ${t.length}`);
  assert.ok(t.endsWith('…'));
});

test('parseRepoFromRemote: https github', () => {
  assert.equal(parseRepoFromRemote('https://github.com/acme/widgets.git'), 'acme/widgets');
});
test('parseRepoFromRemote: ssh github', () => {
  assert.equal(parseRepoFromRemote('git@github.com:acme/widgets.git'), 'acme/widgets');
});
test('parseRepoFromRemote: non-github -> null', () => {
  assert.equal(parseRepoFromRemote('https://dev.azure.com/acme/_git/widgets'), null);
});

test('collectServices: distinct, order-preserving', () => {
  assert.deepEqual(collectServices(['a-api', 'a-ui', 'a-api']), ['a-api', 'a-ui']);
});
test('collectServices: drops empties', () => {
  assert.deepEqual(collectServices(['a', '', null, undefined, 'b']), ['a', 'b']);
});

test('buildServiceQuery: single', () => {
  assert.equal(buildServiceQuery(['a-api'], 'prod'), 'service:a-api env:prod');
});
test('buildServiceQuery: multiple uses OR group', () => {
  assert.equal(buildServiceQuery(['a', 'b'], 'prod'), 'service:(a OR b) env:prod');
});

test('buildLogQuery: appends the status filter', () => {
  assert.equal(buildLogQuery(['a-api'], 'prod', 'status:error'), 'service:a-api env:prod status:error');
});
test('buildLogQuery: defaults status to status:error', () => {
  assert.equal(buildLogQuery(['a-api'], 'prod'), 'service:a-api env:prod status:error');
});

test('mergeConfig: precedence cli > project > auto > user', () => {
  const user = { 'log-sweep': { env: 'stage', repo: 'u/r' } };
  const project = { 'log-sweep': { env: 'prod' } };
  const auto = { repo: 'a/r', services: ['s1'] };
  const cli = { repo: 'c/r' };
  assert.deepEqual(
    mergeConfig(user, project, auto, cli, 'log-sweep'),
    { env: 'prod', repo: 'c/r', services: ['s1'] },
  );
});
test('mergeConfig: missing layers tolerated', () => {
  assert.deepEqual(mergeConfig(null, null, { services: ['s'] }, {}, 'log-sweep'), { services: ['s'] });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`
Expected: FAIL — `Cannot find module './log-sweep-lib.mjs'`.

- [ ] **Step 3: Write the lib**

`plugins/fu-log-sweep/scripts/log-sweep-lib.mjs`:

```javascript
// Pure, dependency-free helpers for the /log-sweep loop (except node:crypto,
// used by the fingerprint core in a later section — deterministic, no I/O).
// No network, no Date.now() — fully unit-testable.

const DAY_MS = 24 * 60 * 60 * 1000;

// Search window start (epoch ms). Always covers >= 24h, never reaches > 30d
// back, otherwise extends back to the last completed tick. First run => now-24h.
export function windowStartMs(lastTickMs, nowMs) {
  const floor = nowMs - DAY_MS;
  const cap = nowMs - 30 * DAY_MS;
  if (!lastTickMs) return floor;
  return Math.max(cap, Math.min(lastTickMs, floor));
}

// Classify a candidate from its GitHub marker-search matches.
// matches: [{number, state:'OPEN'|'CLOSED'}]. Open wins over closed (no churn).
export function classify(matches) {
  if (!matches || matches.length === 0) return { kind: 'NEW' };
  const open = matches.find((m) => m.state === 'OPEN');
  if (open) return { kind: 'ALREADY_OPEN', number: open.number };
  return { kind: 'REGRESSION', number: matches[0].number };
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

// Parse a git remote URL to "owner/name" — github only, else null.
export function parseRepoFromRemote(url) {
  if (!url) return null;
  const m = url.match(/github\.com[/:]([^/]+)\/(.+?)(?:\.git)?\/?$/i);
  return m ? `${m[1]}/${m[2]}` : null;
}

// Distinct, order-preserving, empties removed.
export function collectServices(appNames) {
  const seen = new Set();
  const out = [];
  for (const n of appNames || []) {
    if (n && !seen.has(n)) { seen.add(n); out.push(n); }
  }
  return out;
}

// Datadog query across one or more services for an env.
export function buildServiceQuery(services, env) {
  const svc = services.length === 1 ? `service:${services[0]}` : `service:(${services.join(' OR ')})`;
  return `${svc} env:${env}`;
}

// Datadog Logs query: service+env scope plus the error status filter.
export function buildLogQuery(services, env, statusQuery) {
  return `${buildServiceQuery(services, env)} ${statusQuery || 'status:error'}`;
}

// Merge config layers for a tool: user < auto < project < cli (later wins).
export function mergeConfig(userObj, projectObj, autoObj, cliObj, tool) {
  const u = (userObj && userObj[tool]) || {};
  const p = (projectObj && projectObj[tool]) || {};
  const a = autoObj || {};
  const c = cliObj || {};
  return { ...u, ...a, ...p, ...c };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`
Expected: PASS — all tests green (0 failing).

- [ ] **Step 5: Commit**

```bash
git add plugins/fu-log-sweep/scripts/log-sweep-lib.mjs plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs
git commit -m "feat(fu-log-sweep): pure-logic helpers (window, classify, title, config, log query)"
```

---

### Task 3: Fingerprint core — the ET-`issue_id` replacement

**Files:**
- Modify: `plugins/fu-log-sweep/scripts/log-sweep-lib.mjs` (append the fingerprint section)
- Modify: `plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs` (append fingerprint tests)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (consumed by Task 4 CLI and Task 6/7 agents/command):
  - `parseFrames(stackText) -> string[]` (qualified `Ns.Type.Method` names, innermost first)
  - `isBclFrame(qualifiedMethod) -> boolean`
  - `firstAppFrame(stackText, appNsPrefixes) -> string|null`
  - `firstNonBclFrame(stackText) -> string|null`
  - `normalizeFrame(frame) -> string`
  - `normalizeMessage(message) -> string`
  - `computeSignature(errorKind, service, frameKey) -> string` (12 hex chars)
  - `buildSignature(errorKind, service, stackText, message, appNsPrefixes) -> {sig, frame, confidence}` where `confidence ∈ {'app-frame','first-frame','message'}`
  - `buildMarker(sig) -> string`
  - `extractSig(body) -> string|null`

- [ ] **Step 1: Write the failing tests**

Append to `plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`:

```javascript
import {
  parseFrames, isBclFrame, firstAppFrame, firstNonBclFrame,
  normalizeFrame, normalizeMessage, computeSignature, buildSignature,
  buildMarker, extractSig,
} from './log-sweep-lib.mjs';

// A representative .NET stack (placeholder namespace — never a real one).
const STACK = [
  'System.NullReferenceException: Object reference not set to an instance of an object.',
  '   at Acme.Widgets.Orders.CompanyDetailProjector.Project(CompanyDto dto) in /src/Orders/CompanyDetailProjector.cs:line 42',
  '   at Acme.Widgets.Orders.OrderService.<HandleAsync>d__12.MoveNext() in /src/Orders/OrderService.cs:line 88',
  '   at System.Runtime.CompilerServices.TaskAwaiter.ThrowForNonSuccess(Task task)',
  '   at Microsoft.AspNetCore.Mvc.Infrastructure.ControllerActionInvoker.InvokeAsync()',
].join('\n');

test('parseFrames: qualified methods, innermost first, no params/file/line', () => {
  assert.deepEqual(parseFrames(STACK), [
    'Acme.Widgets.Orders.CompanyDetailProjector.Project',
    'Acme.Widgets.Orders.OrderService.<HandleAsync>d__12.MoveNext',
    'System.Runtime.CompilerServices.TaskAwaiter.ThrowForNonSuccess',
    'Microsoft.AspNetCore.Mvc.Infrastructure.ControllerActionInvoker.InvokeAsync',
  ]);
});
test('parseFrames: empty/undefined -> []', () => {
  assert.deepEqual(parseFrames(''), []);
  assert.deepEqual(parseFrames(undefined), []);
});

test('isBclFrame: System/Microsoft are BCL, app is not', () => {
  assert.equal(isBclFrame('System.String.Concat'), true);
  assert.equal(isBclFrame('Microsoft.AspNetCore.X.Y'), true);
  assert.equal(isBclFrame('Acme.Widgets.Orders.OrderService.Handle'), false);
});

test('firstAppFrame: returns first frame under an app prefix', () => {
  assert.equal(firstAppFrame(STACK, ['Acme']), 'Acme.Widgets.Orders.CompanyDetailProjector.Project');
});
test('firstAppFrame: no matching prefix -> null', () => {
  assert.equal(firstAppFrame(STACK, ['Nope']), null);
});
test('firstAppFrame: empty prefixes -> null', () => {
  assert.equal(firstAppFrame(STACK, []), null);
});

test('firstNonBclFrame: first non-System/Microsoft frame', () => {
  assert.equal(firstNonBclFrame(STACK), 'Acme.Widgets.Orders.CompanyDetailProjector.Project');
});
test('firstNonBclFrame: all-BCL stack -> null', () => {
  const bcl = ['   at System.A.B()', '   at Microsoft.C.D()'].join('\n');
  assert.equal(firstNonBclFrame(bcl), null);
});

test('normalizeFrame: unwraps async state machine', () => {
  assert.equal(
    normalizeFrame('Acme.Widgets.Orders.OrderService.<HandleAsync>d__12.MoveNext'),
    'Acme.Widgets.Orders.OrderService.HandleAsync',
  );
});
test('normalizeFrame: unwraps lambda display class', () => {
  assert.equal(
    normalizeFrame('Acme.Widgets.Orders.OrderService.<Process>b__4_0'),
    'Acme.Widgets.Orders.OrderService.Process',
  );
});
test('normalizeFrame: drops generic arity backticks', () => {
  assert.equal(normalizeFrame('Acme.Widgets.Repo`1.GetAll'), 'Acme.Widgets.Repo.GetAll');
});

test('normalizeMessage: strips guids and numbers, collapses ws, caps 80', () => {
  const m = normalizeMessage('Order 12345 (a3d45410-38d4-11f1-b7c1-da7ad0900000)  failed');
  assert.equal(m, 'Order <n> (<guid>) failed');
});

test('computeSignature: 12 hex chars, deterministic', () => {
  const a = computeSignature('System.NullReferenceException', 'a-api', 'Acme.X.Y');
  assert.match(a, /^[0-9a-f]{12}$/);
  assert.equal(a, computeSignature('System.NullReferenceException', 'a-api', 'Acme.X.Y'));
});
test('computeSignature: different frame -> different sig', () => {
  const a = computeSignature('E', 's', 'Acme.A.B');
  const b = computeSignature('E', 's', 'Acme.C.D');
  assert.notEqual(a, b);
});

test('buildSignature: app frame -> app-frame confidence, normalized frame', () => {
  const r = buildSignature('System.NullReferenceException', 'a-api', STACK, 'boom', ['Acme']);
  assert.equal(r.confidence, 'app-frame');
  assert.equal(r.frame, 'Acme.Widgets.Orders.CompanyDetailProjector.Project');
  assert.match(r.sig, /^[0-9a-f]{12}$/);
});
test('buildSignature: no app prefix falls back to first non-BCL frame', () => {
  const r = buildSignature('E', 'a-api', STACK, 'boom', []);
  assert.equal(r.confidence, 'first-frame');
  assert.equal(r.frame, 'Acme.Widgets.Orders.CompanyDetailProjector.Project');
});
test('buildSignature: no stack falls back to normalized message', () => {
  const r = buildSignature('E', 'a-api', '', 'Order 5 failed', ['Acme']);
  assert.equal(r.confidence, 'message');
  assert.equal(r.frame, null);
  assert.match(r.sig, /^[0-9a-f]{12}$/);
});

test('marker round-trips through extractSig', () => {
  const sig = 'a3d4541038d4';
  assert.equal(extractSig(buildMarker(sig)), sig);
});
test('extractSig: no marker -> null', () => {
  assert.equal(extractSig('no marker here'), null);
});
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`
Expected: FAIL — `parseFrames` (and the other new exports) `is not a function` / not exported.

- [ ] **Step 3: Append the fingerprint core to the lib**

Add to the top of `plugins/fu-log-sweep/scripts/log-sweep-lib.mjs` (after the first comment block):

```javascript
import { createHash } from 'node:crypto';
```

Append at the end of `plugins/fu-log-sweep/scripts/log-sweep-lib.mjs`:

```javascript
// ---- Fingerprint core (the dedup-signature computation) --------------------

const BCL_PREFIXES = ['System.', 'Microsoft.', 'Datadog.', 'Newtonsoft.', 'MediatR.', 'Polly.'];

// Parse .NET stack frames from an @error.stack string into an ordered array of
// qualified method names (no params/file/line), innermost first. Non-frame
// lines (the exception header, blank lines) are skipped.
export function parseFrames(stackText) {
  const out = [];
  for (const raw of (stackText || '').split('\n')) {
    const line = raw.trim();
    const m = line.match(/^at\s+(.+?)\s*(?:\(|$)/);
    if (m) out.push(m[1]);
  }
  return out;
}

// A framework/BCL frame (not the application's own code).
export function isBclFrame(qualifiedMethod) {
  return BCL_PREFIXES.some((p) => qualifiedMethod.startsWith(p));
}

// First frame whose qualified method starts with one of appNsPrefixes
// (e.g. ['Acme']). Returns the qualified method or null.
export function firstAppFrame(stackText, appNsPrefixes) {
  const prefixes = (appNsPrefixes || []).filter(Boolean);
  if (!prefixes.length) return null;
  for (const f of parseFrames(stackText)) {
    if (prefixes.some((p) => f.startsWith(p))) return f;
  }
  return null;
}

// First frame that is not a known BCL/framework frame — the fallback used when
// no app prefix is configured or none matched.
export function firstNonBclFrame(stackText) {
  for (const f of parseFrames(stackText)) {
    if (!isBclFrame(f)) return f;
  }
  return null;
}

// Normalize a qualified frame so it is stable across recompiles: unwrap async
// state machines and lambdas, drop generic arity backticks.
export function normalizeFrame(frame) {
  if (!frame) return '';
  let f = frame;
  f = f.replace(/\.<([^>]+)>d__\d+\.MoveNext$/, '.$1'); // async state machine
  f = f.replace(/\.<([^>]+)>b__[0-9_]+$/, '.$1');       // lambda / local function
  f = f.replace(/`\d+/g, '');                            // generic arity
  return f.trim();
}

// Normalize a message for the last-resort signature: mask guids and numbers so
// ids don't fragment it, collapse whitespace, cap at 80 chars.
export function normalizeMessage(message) {
  return (message || '')
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<guid>')
    .replace(/\d+/g, '<n>')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
}

// Stable 12-char signature from the grouping key parts.
export function computeSignature(errorKind, service, frameKey) {
  const key = `${errorKind || ''}|${service || ''}|${frameKey || ''}`;
  return createHash('sha1').update(key).digest('hex').slice(0, 12);
}

// Compute the dedup signature for one error bucket via the fallback ladder.
// Returns { sig, frame, confidence }.
export function buildSignature(errorKind, service, stackText, message, appNsPrefixes) {
  const app = firstAppFrame(stackText, appNsPrefixes);
  if (app) {
    const frame = normalizeFrame(app);
    return { sig: computeSignature(errorKind, service, frame), frame, confidence: 'app-frame' };
  }
  const nonBcl = firstNonBclFrame(stackText);
  if (nonBcl) {
    const frame = normalizeFrame(nonBcl);
    return { sig: computeSignature(errorKind, service, frame), frame, confidence: 'first-frame' };
  }
  const msg = normalizeMessage(message);
  return { sig: computeSignature(errorKind, service, msg), frame: null, confidence: 'message' };
}

const LOG_MARKER_RE = /<!--\s*dd-log-sig:\s*([0-9a-f]+)\s*-->/i;

export function buildMarker(sig) {
  return `<!-- dd-log-sig: ${sig} -->`;
}

export function extractSig(body) {
  const m = (body || '').match(LOG_MARKER_RE);
  return m ? m[1] : null;
}
```

- [ ] **Step 4: Run to verify all tests pass**

Run: `node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`
Expected: PASS — all tests green (0 failing).

- [ ] **Step 5: Commit**

```bash
git add plugins/fu-log-sweep/scripts/log-sweep-lib.mjs plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs
git commit -m "feat(fu-log-sweep): fingerprint core (stack parse, top-app-frame signature, marker)"
```

---

### Task 4: CLI wrapper — sweep.mjs

**Files:**
- Create: `plugins/fu-log-sweep/scripts/sweep.mjs`

**Interfaces:**
- Consumes: all exports from `log-sweep-lib.mjs` (Tasks 2-3).
- Produces (consumed by the Task 7 command + Task 6 agents), each prints one line to stdout:
  - `node sweep.mjs window [lastTickMs|null]` → `{startMs, startIso, nowMs}`
  - `node sweep.mjs classify '<matchesJson>'` → classify result
  - `node sweep.mjs title '<errorType>' '<message>'` → title string
  - `node sweep.mjs marker '<sig>'` → marker string
  - `node sweep.mjs signature '<json>'` where json = `{errorKind, service, stack, message, appNamespace}` → `{sig, frame, confidence}`
  - `node sweep.mjs resolve '<cliJson>'` → `{services, env, repo, statusQuery, appNamespace, query, logsUrlBase}`

- [ ] **Step 1: Write the CLI**

`plugins/fu-log-sweep/scripts/sweep.mjs`:

```javascript
#!/usr/bin/env node
// Thin CLI over log-sweep-lib. Converts ISO<->ms; prints JSON or strings to stdout.
// Usage:
//   node sweep.mjs window [lastTickMs|null]
//   node sweep.mjs classify '<matchesJson>'
//   node sweep.mjs title '<errorType>' '<message>'
//   node sweep.mjs marker '<sig>'
//   node sweep.mjs signature '<json:{errorKind,service,stack,message,appNamespace}>'
//   node sweep.mjs resolve '<cliJson>'
import {
  windowStartMs, classify, buildTitle, buildMarker, buildSignature,
  parseRepoFromRemote, collectServices, buildLogQuery, mergeConfig,
} from './log-sweep-lib.mjs';

const [, , cmd, ...args] = process.argv;

function out(v) {
  process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
  process.stdout.write('\n');
}

function asArray(v) {
  if (Array.isArray(v)) return v.filter(Boolean);
  return v ? [v] : [];
}

switch (cmd) {
  case 'window': {
    const lastTick = args[0] && args[0] !== 'null' ? Number(args[0]) : null;
    const now = Date.now();
    const startMs = windowStartMs(lastTick, now);
    out({ startMs, startIso: new Date(startMs).toISOString(), nowMs: now });
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
  case 'signature': {
    const i = JSON.parse(args[0]);
    out(buildSignature(i.errorKind, i.service, i.stack, i.message, asArray(i.appNamespace)));
    break;
  }
  case 'resolve': {
    const { execFileSync } = await import('node:child_process');
    const fs = await import('node:fs');
    const path = await import('node:path');
    const os = await import('node:os');
    const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
    const userCfg = readJson(path.join(os.homedir(), '.claude', 'fu-tools', 'config.json'));
    let projCfg = null;
    for (let dir = process.cwd(); ; dir = path.dirname(dir)) {
      const cand = path.join(dir, '.claude', '.fu-tools.json');
      if (fs.existsSync(cand)) { projCfg = readJson(cand); break; }
      if (dir === path.dirname(dir)) break;
    }
    let repo = null;
    try { repo = parseRepoFromRemote(execFileSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8' }).trim()); } catch { /* no remote */ }
    const appNames = [];
    for (const f of fs.readdirSync(process.cwd())) {
      if (/^k8_settings.*\.json$/.test(f)) {
        const j = readJson(path.join(process.cwd(), f));
        for (const m of JSON.stringify(j || {}).matchAll(/"app_name"\s*:\s*"([^"]+)"/g)) appNames.push(m[1]);
      }
    }
    const auto = {};
    if (repo) auto.repo = repo;
    const services = collectServices(appNames);
    if (services.length) auto.services = services;
    const cli = args[0] ? JSON.parse(args[0]) : {};
    const merged = mergeConfig(userCfg, projCfg, auto, cli, 'log-sweep');
    if (!merged.env) merged.env = 'prod';
    if (!merged.statusQuery) merged.statusQuery = merged.status_query || 'status:error';
    merged.appNamespace = asArray(merged.appNamespace || merged.app_namespace);
    merged.logsUrlBase = merged.logsUrlBase || merged.logs_url_base || null;
    if (merged.services && merged.services.length) {
      merged.query = buildLogQuery(merged.services, merged.env, merged.statusQuery);
    }
    out(merged);
    break;
  }
  default:
    process.stderr.write(`unknown command: ${cmd}\n`);
    process.exit(1);
}
```

- [ ] **Step 2: Verify each subcommand prints correctly**

Run (from repo root):
```bash
cd plugins/fu-log-sweep/scripts
node sweep.mjs marker abc123abc123
node sweep.mjs title 'System.NullReferenceException' 'boom'
node sweep.mjs classify '[{"number":9,"state":"CLOSED"}]'
node sweep.mjs signature '{"errorKind":"System.NullReferenceException","service":"a-api","stack":"   at Acme.Widgets.Orders.X.Y(Z z)\n   at System.A.B()","message":"boom","appNamespace":["Acme"]}'
cd -
```
Expected, line by line:
```
<!-- dd-log-sig: abc123abc123 -->
[Datadog] NullReferenceException: boom
{"kind":"REGRESSION","number":9}
{"sig":"<12 hex>","frame":"Acme.Widgets.Orders.X.Y","confidence":"app-frame"}
```

- [ ] **Step 3: Verify resolve runs and defaults env/status**

Run: `node plugins/fu-log-sweep/scripts/sweep.mjs resolve '{"services":["a-api"]}'`
Expected: JSON containing `"env":"prod"`, `"statusQuery":"status:error"`, `"query":"service:a-api env:prod status:error"`, `"appNamespace":[]`, `"logsUrlBase":null`.

- [ ] **Step 4: Commit**

```bash
git add plugins/fu-log-sweep/scripts/sweep.mjs
git commit -m "feat(fu-log-sweep): thin CLI wrapper (window/classify/title/marker/signature/resolve)"
```

---

### Task 5: Issue-body template doc + plugin README

**Files:**
- Create: `plugins/fu-log-sweep/docs/DESIGN.md`
- Create: `plugins/fu-log-sweep/README.md`

**Interfaces:**
- Produces: the canonical issue-body + regression-comment templates that the Task 6 investigator reads from `${CLAUDE_PLUGIN_ROOT}/docs/DESIGN.md`.

- [ ] **Step 1: Create the plugin DESIGN.md (issue templates + summary)**

`plugins/fu-log-sweep/docs/DESIGN.md`:

````markdown
# fu-log-sweep — design summary + issue templates

Sibling to `fu-et-sweep`. Sweeps a service's Datadog **error-level Logs**
(`status:error`) into de-duped GitHub issues. Unlike Error Tracking, logs are
not pre-grouped, so the sweep computes its own stable **signature** per distinct
error and dedups on it. Full design:
`docs/superpowers/specs/2026-07-23-fu-log-sweep-design.md`.

**Signature (dedup key):** `sha1(errorKind | service | topAppFrame)` truncated to
12 hex chars. Top app frame = first stack frame under the configured
`app_namespace` (BCL/framework frames skipped), normalized (async/lambda
unwrapped, generic arity dropped). Fallback ladder: no app frame → first non-BCL
frame; no stack → normalized message.

## GitHub issue format

**Title:** `[Datadog] <errorKind>: <topFrame | message truncated ~80 chars>`

**Labels:** `datadog-logs`, `auto-filed`, `sev:low|med|high`. Baseline run also
adds `log-baseline`.

**Body** (no `#` headers — bold labels, per repo prose convention):

```markdown
<!-- dd-log-sig: <sig> -->

**Datadog:** <Logs Explorer URL for this query+window>

**Error**
- Type: `<errorKind>`
- Message: <errorMessage>
- Service: `<service>` · env `<env>`
- Failing frame: `<topFrame>`   (or "unresolved — signature via <confidence>")

**Occurrence**
- Count (window): <count>
- Last seen: <last-seen ISO from newest sample>
- First seen: not tracked for log-sourced errors — window ≥ <window start ISO>

**Suspected root cause** *(drafted, verify before acting)*
<LLM writeup — 1-3 short paras: what throws, why, the traced code path>

**Suspected code location**
- `<path>:<line>` (codegraph trace, when source is indexed this session)

---
*Auto-filed by /log-sweep. Regressions reopen this issue rather than filing a
new one. The root-cause section is a draft, not a verdict.*
```

## Regression comment (when reopening a closed issue)

```markdown
**Regressed** — recurred after close.
- Seen again: <last-seen ISO>
- Count this window: <count>
- Datadog: <Logs Explorer URL>
<one-line note if the suspected root cause shifted vs the original>
```
````

- [ ] **Step 2: Create the plugin README**

`plugins/fu-log-sweep/README.md`:

```markdown
# fu-log-sweep

One tick of a self-paced sweep: a service's Datadog **error-level Logs**
(`status:error`) → de-duped GitHub issues with drafted root-cause writeups.
Sibling to `fu-et-sweep`; the difference is the source (raw Logs, not Error
Tracking) and therefore the dedup key — a **computed signature**
(`type | service | top-app-frame` sha1) instead of an ET `issue_id`.

## Requirements (on PATH, authenticated in a live session)

- `pup` — the Datadog CLI (`pup auth login`; a `401` needs re-login).
- `gh` — authenticated for the target repo.
- `node` — runs the bundled `scripts/` and the `node --test` suite.

## Usage

```
/log-sweep --observe            # dry run: prints the candidate table, files nothing
/log-sweep                      # live: files/reopens GitHub issues
/log-sweep --baseline           # one-time: record existing signatures as known stubs
/loop 24h /log-sweep            # self-paced watch
```

Flags: `--service <a,b>`, `--env <env>`, `--repo <owner/name>`, `--count N`
override the config-resolved defaults.

## Config (`fu-tools`, tool key `log-sweep`)

`services` (auto from k8_settings `app_name`), `env` (prod), `repo` (auto from
git remote), `count_threshold` (1), `app_namespace` (stack-frame app prefix, e.g.
`["Acme"]`), `status_query` (`status:error`), `logs_url_base` (Logs Explorer URL
prefix for the issue link).

## Tests

```
node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs
```
```

- [ ] **Step 3: Verify the template + README exist and carry the marker**

Run:
```bash
grep -q 'dd-log-sig' plugins/fu-log-sweep/docs/DESIGN.md \
  && grep -q 'datadog-logs' plugins/fu-log-sweep/docs/DESIGN.md \
  && test -f plugins/fu-log-sweep/README.md \
  && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add plugins/fu-log-sweep/docs/DESIGN.md plugins/fu-log-sweep/README.md
git commit -m "docs(fu-log-sweep): issue-body/regression templates + plugin README"
```

---

### Task 6: Subagents — log-triage-gate + log-investigator

**Files:**
- Create: `plugins/fu-log-sweep/agents/log-triage-gate.md`
- Create: `plugins/fu-log-sweep/agents/log-investigator.md`

**Interfaces:**
- Consumes: the CLI subcommands `marker`, `title` (Task 4); the issue templates in `docs/DESIGN.md` (Task 5).
- Produces:
  - `log-triage-gate`: given metadata, returns JSON `{actionable, reason, suspected_severity}`.
  - `log-investigator`: given `{sig, errorKind, service, env, classification (+gh number if REGRESSION), mode, repo, logsUrlBase, metadata}`, files/reopens the issue and returns a one-line receipt.

- [ ] **Step 1: Create the triage-gate agent**

`plugins/fu-log-sweep/agents/log-triage-gate.md`:

```markdown
---
name: log-triage-gate
description: Metadata-only triage of one Datadog log-error signature — decides if it is actionable enough to warrant a GitHub issue. Makes no tool calls. Used by the /log-sweep loop.
tools: []
---

You judge ONE Datadog log-sourced error signature from its metadata alone. Make NO tool calls. Return ONLY a JSON object — no prose, no code fences.

Decide: is this a genuine, application-level, actionable error worth a GitHub issue?

DROP (actionable=false) when it is transient/infra noise:
- Client-cancelled requests: TaskCanceledException / OperationCanceledException whose frame is HttpConnection.SendAsync or TaskCompletionSourceWithCancellation — the caller hung up.
- Transient DNS / connectivity: "Name or service not known", "Connection refused", SocketException at ConnectToTcpHostAsync, to an external host.
- Upstream 5xx passthrough with no frame in the application's own code.

KEEP (actionable=true) when it points at the application's own logic:
- NullReferenceException, ArgumentException, InvalidOperationException with a frame in the app's own namespaces.
- Unhandled domain exceptions thrown from the service's own code.
- ORM/database failures (EF Core, Npgsql, MySqlConnector, MongoDB, SqlClient) that originate in an app query/command — not a plain user-cancel.
- Anything you cannot confidently call noise — default to KEEP so a human sees it.

You are given the service name and the failing frame; treat frames in that service's own namespaces/paths as "application" frames and framework/BCL frames (System.*, Microsoft.*, Datadog.*, node internals) as non-application. If the signature confidence is "message" (no stack was available), lean toward KEEP unless the message is obviously transient noise.

suspected_severity: high (data loss / crash / auth break), med (a feature broken for some users), low (degraded / cosmetic / rare).

Return exactly this shape (example):
{"actionable": true, "reason": "<=15 words", "suspected_severity": "med"}
```

- [ ] **Step 2: Create the investigator agent**

`plugins/fu-log-sweep/agents/log-investigator.md`:

```markdown
---
name: log-investigator
description: Deep-dives ONE actionable Datadog log-error signature — pulls a sample stack via pup logs search, traces to source via codegraph when available, drafts a root-cause writeup, and (live mode) files or reopens the GitHub issue. Returns a one-line receipt only. Used by the /log-sweep loop.
tools: All tools
---

You investigate ONE Datadog log-sourced error signature end to end and return ONLY a one-line receipt. Your large working context (stack traces, source reads) MUST stay with you — never echo it back to the caller; it belongs in the GitHub issue body.

You are given: sig (12-char signature), errorKind, service, env, classification ("NEW", or "REGRESSION" with the existing gh issue number), mode ("observe" | "live"), the GitHub repo to file in (owner/name), logsUrlBase (Logs Explorer URL prefix, may be null), and metadata (errorMessage, count, lastSeenIso, windowStartIso, topFrame, confidence).

Datadog access is the `pup` CLI (see the `datadog-pup` skill), run via Bash — not an MCP server. `pup` auto-detects agent mode and wraps responses as `{status,data,metadata}`; read the payload under `.data`. Re-auth with `pup auth login` on a `401`.

Build the bucket query BUCKET_Q = `service:<service> env:<env> status:error @error.kind:"<errorKind>"` (quote the errorKind value — it contains dots).

Steps:
1. Pull a few representative sample events for the **stack frames**: `pup logs search --query '<BUCKET_Q>' --from "<windowStartIso>" --to now --limit 3` and read `@error.stack` / `@error.message`. Keep it modest — a few samples, not bulk. If nothing is retrievable (sampling/retention), note that in the writeup and rely on the given topFrame/metadata.
2. If the service's source is indexed by codegraph in THIS session, trace from the top application-owned stack frame (a frame in the service's own namespaces/paths, not System.*/Microsoft.*/framework — the given `topFrame` is your starting point) to locate the code path. If codegraph has no matching symbols (source not in this session), skip and note "source not available in this session".
3. Draft a root-cause writeup: 1-3 short paragraphs — what throws, why, the traced path — plus the suspected `file:line` when found. Mark it explicitly as a draft. If `confidence` is not "app-frame", say so (the failing frame is approximate).
4. Build the Logs Explorer link: if logsUrlBase is set, `<logsUrlBase>` + the URL-encoded BUCKET_Q; otherwise write `Datadog Logs — query: <BUCKET_Q>` (no link).
5. Build the issue body exactly per the template in ${CLAUDE_PLUGIN_ROOT}/docs/DESIGN.md (hidden marker first, then Datadog link, Error, Occurrence, Suspected root cause, Suspected code location, footer). Use bold labels, NOT '#' headers. Get the marker via `node ${CLAUDE_PLUGIN_ROOT}/scripts/sweep.mjs marker <sig>` and the title via `node ${CLAUDE_PLUGIN_ROOT}/scripts/sweep.mjs title '<errorKind>' '<topFrame or errorMessage>'` (prefer topFrame when present).

If mode == "observe": do NOT touch GitHub. Return: `observed: would-<create|reopen> (<sev>) — <title>`.

If mode == "live" (pass `--repo owner/name` to every gh call):
- NEW: `gh issue create --repo <owner/name> --title "<title>" --label datadog-logs,auto-filed,sev:<sev> --body "<body>"`. Return `#<n> created (<sev>)`.
- REGRESSION (existing #N): `gh issue reopen <N> --repo <owner/name>`; then `gh issue comment <N> --repo <owner/name> --body "<regression comment block from DESIGN.md>"`. Return `#<N> reopened (<sev>)`.
- On any gh failure: print the full drafted body so it is not lost, then return `FAILED <sig>: <reason>`.

Return ONLY the one-line receipt (plus the body dump on failure). Nothing else.
```

- [ ] **Step 3: Verify frontmatter parses and names are unique**

Run:
```bash
grep -l 'name: log-triage-gate' plugins/fu-log-sweep/agents/log-triage-gate.md \
  && grep -l 'name: log-investigator' plugins/fu-log-sweep/agents/log-investigator.md \
  && echo OK
```
Expected: both paths echoed, then `OK`.

- [ ] **Step 4: Commit**

```bash
git add plugins/fu-log-sweep/agents/log-triage-gate.md plugins/fu-log-sweep/agents/log-investigator.md
git commit -m "feat(fu-log-sweep): triage-gate + investigator subagents"
```

---

### Task 7: The /log-sweep command (tick orchestrator)

**Files:**
- Create: `plugins/fu-log-sweep/commands/log-sweep.md`

**Interfaces:**
- Consumes: the CLI subcommands (Task 4), both subagents (Task 6).
- Produces: the `/log-sweep` slash command.

- [ ] **Step 1: Create the command**

`plugins/fu-log-sweep/commands/log-sweep.md`:

```markdown
---
description: One tick of a Datadog error-Logs sweep -> de-duped GitHub issues with drafted root-cause writeups. Run via /loop for a self-paced watch.
---

You are running ONE tick of the log-error sweep. Keep YOUR context tiny: never read stack traces or draft writeups yourself — that is the log-investigator subagent's job. You only orchestrate.

Arguments: $ARGUMENTS
- mode: "--observe" (default), "--live", or "--baseline".
- "--service <a,b>" optional override of monitored services (comma-separated). Default: ALL services auto-detected from the repo.
- "--env <env>" optional. Default: prod.
- "--repo <owner/name>" optional override of the target GitHub repo. Default: auto-detected from the git remote.
- "--count N" overrides the count threshold (default: 1).

Derived:
- LIB = "${CLAUDE_PLUGIN_ROOT}/scripts/sweep.mjs". If that path does not exist (variable not expanded), set LIB to the first match of `find "$HOME/.claude" -path '*plugins/fu-log-sweep/scripts/sweep.mjs' 2>/dev/null | head -1`.
- Build a CLI-override JSON from any flags given: `{ "services": [...from --service], "env": "...", "repo": "..." }` (omit keys not passed).
- RESOLVED = `node "$LIB" resolve '<cli-override-json>'` → `{services, env, repo, statusQuery, appNamespace, query, logsUrlBase}`. `services`/`repo` auto-detect (k8_settings app_name / git remote) unless overridden; `env` defaults to prod.
- REPO = RESOLVED.repo; QUERY = RESOLVED.query (spans ALL monitored services in one search); APPNS = RESOLVED.appNamespace (JSON array); LOGS_URL_BASE = RESOLVED.logsUrlBase; ENV = RESOLVED.env.
- KEY = REPO with every non-alphanumeric char replaced by "-"; STATE_FILE = "$HOME/.claude/log-sweep-state-<KEY>.json" (holds {last_successful_tick, baseline_done} in epoch ms; one file per repo).

Datadog access is the `pup` CLI (see the `datadog-pup` skill) — not an MCP server. All log reads run through `pup` via Bash. If `pup auth status` shows no valid token, STOP and report: run `pup auth login` first (re-auth also needed on a `401`). `pup` wraps responses as `{status,data,metadata}` — read the payload under `.data`.

If REPO is empty (no GitHub remote and no --repo/config), STOP and report: cannot file issues without a target repo.

Procedure:

1. Read state: `cat "$STATE_FILE" 2>/dev/null`. Parse {last_successful_tick, baseline_done}. Missing/empty = first run (last_successful_tick = null, baseline_done = false).

2. Compute window: `node "$LIB" window <last_successful_tick|null>`. Capture startMs, startIso, nowMs.

3. Aggregate (one call, all services, Datadog groups server-side): `pup logs aggregate --query "$QUERY" --from "<startIso>" --to now --compute count --group-by @error.kind --group-by service`. Read `.data`. Build a bucket list `[{errorKind, service, count}]`. (Confirm the exact facet name `@error.kind` vs `@error.type` and the group-by flag shape against live output — see the spec's open questions; adjust the query if the first observe tick shows the facet is named differently.)

4. Prune + cap buckets (no samples yet):
   - Count-prune: drop buckets with `count < threshold`.
   - Sort by `count` desc; if more than 20, keep the top 20 and record "dropped <k> buckets over pre-sample cap".

5. Per surviving bucket, fetch ONE sample + compute the signature:
   - BUCKET_Q = `service:<service> env:<ENV> status:error @error.kind:"<errorKind>"`.
   - `pup logs search --query '<BUCKET_Q>' --from "<startIso>" --to now --limit 1` (newest). Read `.data` for `@error.stack`, `@error.message`, and the event timestamp (lastSeenIso).
   - `node "$LIB" signature '{"errorKind":"<errorKind>","service":"<service>","stack":"<@error.stack>","message":"<@error.message>","appNamespace":<APPNS>}'` → `{sig, frame, confidence}`.
   - Carry `{sig, errorKind, service, count, frame, confidence, errorMessage, lastSeenIso}`.

6. Dedup classification (regression authority): for each bucket, `gh issue list --repo "$REPO" --state all --search "<sig>" --json number,state,title` then `node "$LIB" classify '<matchesJson>'` (map gh state values to OPEN/CLOSED) → NEW / ALREADY_OPEN / REGRESSION. **Drop ALREADY_OPEN.** For REGRESSION keep the gh number. Sort survivors by `count` desc; if more than 10, keep the top 10 and record "dropped <k> over cap".

7. Triage gate (skipped in BASELINE mode): dispatch the `log-triage-gate` agent once per survivor, passing metadata + `service` + `frame` + `confidence`. Keep survivors whose result has actionable=true; remember each verdict + reason.

8. Mode handling:

   BASELINE mode: for each survivor classified NEW, create a stub: title via `node "$LIB" title '<errorKind>' '<frame or errorMessage>'`, marker via `node "$LIB" marker '<sig>'`, then `gh issue create --repo "$REPO" --title "<title>" --label datadog-logs,log-baseline --body "<marker>\n\n**Datadog:** <link or BUCKET_Q>"` (NO writeup). Leave REGRESSION/ALREADY_OPEN untouched. Set baseline_done=true. Skip the investigator.

   LIVE mode: for each actionable survivor, dispatch the `log-investigator` agent with {sig, errorKind, service, env: ENV, classification (+gh number if REGRESSION), mode:"live", repo: REPO, logsUrlBase: LOGS_URL_BASE, metadata:{errorMessage, count, lastSeenIso, windowStartIso: startIso, topFrame: frame, confidence}}. Collect the one-line receipts. The investigator creates/reopens the issue itself.

   OBSERVE mode: do NOT dispatch the investigator and do NOT touch GitHub. Print a table: sig (short) | service | error_kind | count | frame | confidence | classification | triage (actionable + reason) | would-be-action (create / reopen #N / drop-noise).

9. State write: if the tick COMPLETED (even with per-candidate skips) AND mode is not observe, write `echo '{"last_successful_tick": <nowMs>, "baseline_done": <bool>}' > "$STATE_FILE"`. Do NOT write state if the tick aborted before aggregate returned, and never in observe mode.

10. Summary line: counts {buckets, pruned, deduped, actionable, filed/observed, dropped-over-cap} and the list of services monitored.

Resilience:
- Wrap each per-bucket operation so one failing bucket (aggregate/search/signature/gh/subagent error) is logged with its errorKind+service and skipped — never abort the whole tick.
- Pre-sample bucket cap is 20; per-tick survivor cap is 10 (top by count); always log the dropped count, never truncate silently.

Self-pace (only when invoked under /loop):
- After the summary, schedule the next wake ~24h out. Shorten toward a few hours if this tick filed anything (active period); lengthen when quiet. The runtime clamps the delay.

Never circumvent a blocked tool call (e.g. a commit hook) by injecting bypass tokens — report the blocker instead.
```

- [ ] **Step 2: Verify the command references resolve to real files/subcommands**

Run:
```bash
grep -q 'log-triage-gate' plugins/fu-log-sweep/commands/log-sweep.md \
  && grep -q 'log-investigator' plugins/fu-log-sweep/commands/log-sweep.md \
  && grep -q 'logs aggregate' plugins/fu-log-sweep/commands/log-sweep.md \
  && grep -q 'sweep.mjs' plugins/fu-log-sweep/commands/log-sweep.md \
  && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/fu-log-sweep/commands/log-sweep.md
git commit -m "feat(fu-log-sweep): /log-sweep tick orchestrator command"
```

---

### Task 8: Validate, install, and observe-phase dry run (manual gate)

**Files:** none (verification only).

**Interfaces:**
- Consumes: the whole plugin (Tasks 1-7).

- [ ] **Step 1: Full lib test suite green**

Run: `node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs`
Expected: PASS (0 failing).

- [ ] **Step 2: Manifest validates and marketplace re-indexes**

Run:
```bash
claude plugin validate plugins/fu-log-sweep
claude plugin marketplace update fu-claude-plugins
claude plugin install fu-log-sweep@fu-claude-plugins
```
Expected: validate reports the manifest OK; install completes (agents `log-triage-gate` + `log-investigator` and command `/log-sweep` become available in the NEXT session).

- [ ] **Step 3: Observe dry-run against the test target (needs live `pup` + `gh`)**

In a session where `pup auth status` is valid and `gh` is authenticated for the target repo, run against the observe-phase target recorded in memory (`InfoTrack.Compliance.Mono` — service resolved from its `k8_settings` `app_name`):
```
/log-sweep --observe
```
Expected: prints the candidate table (sig, service, error_kind, count, frame, confidence, classification, triage, would-be-action), files NOTHING, writes NO state file. Use this run to confirm the open questions from the spec: the Datadog facet name (`@error.kind` vs `@error.type`), that `@error.stack` is populated, and pick the `app_namespace` value + `logs_url_base` to add to `fu-tools` config before going live.

- [ ] **Step 4: Record verified config in fu-tools (not the repo)**

After the observe run confirms the facets, set the resolved values in `~/.claude/fu-tools/config.json` under `log-sweep` (e.g. `app_namespace`, `logs_url_base`, and — if the facet differs — `status_query`). These live in user config, never committed to this repo.

- [ ] **Step 5: Final commit (if any tracked files changed during validation)**

```bash
git status --short
# commit only if validation surfaced a tracked-file fix; otherwise nothing to do
```

---

## Self-Review

**1. Spec coverage:**
- Source = Logs (`status:error`) → Task 7 step 3 query, `buildLogQuery` (Task 2). ✓
- Hybrid fingerprint (Datadog aggregate → per-bucket sample → top-app-frame sig) → Task 7 steps 3-5, fingerprint core (Task 3), `signature` CLI (Task 4). ✓
- New sibling plugin `fu-log-sweep` → Tasks 1-7; et-sweep untouched. ✓
- Fallback ladder → `buildSignature` (Task 3), tested. ✓
- Dedup marker `dd-log-sig` + regression on closed → `buildMarker`/`extractSig`/`classify` (Tasks 2-3), Task 7 step 6, investigator (Task 6). ✓
- GH issue format + labels `datadog-logs` → Task 5 templates, Task 6 investigator, Task 7. ✓
- Config tool key `log-sweep`, fu-tools layered → `resolve` (Task 4), README (Task 5). ✓
- Observe→live→baseline rollout → Task 7 step 8, Task 8 step 3. ✓
- Window gap-safe → `windowStartMs` (Task 2), Task 7 step 2. ✓
- Token discipline (subagent isolation, one-line receipts) → Task 6 agents, Task 7 preamble. ✓
- Open questions verified in observe phase → Task 8 step 3. ✓
- No InfoTrack literals in repo (placeholder `Acme.Widgets`; target in memory) → tests + docs use `Acme`; Task 8 step 3 references memory only. ✓

**2. Placeholder scan:** No "TBD"/"TODO"/"handle edge cases"/"similar to Task N" — every code step carries full code; every prose file is complete. ✓

**3. Type consistency:** `buildSignature` returns `{sig, frame, confidence}` — same shape consumed by the `signature` CLI (Task 4), the command (Task 7 step 5), and passed to the investigator as `{topFrame: frame, confidence}` (Task 7 step 8, consumed in Task 6). `classify` return shape matches et-sweep and the command's NEW/ALREADY_OPEN/REGRESSION handling. `resolve` output keys (`services, env, repo, statusQuery, appNamespace, query, logsUrlBase`) match every consumer in Task 7. ✓
```
