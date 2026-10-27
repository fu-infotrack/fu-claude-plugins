// routine.mjs end to end, hermetic: a throwaway $HOME, fake target clones found
// through DB_SWEEP_SEARCH_ROOT, a `gh` stub on PATH that serves REST fixtures,
// records every call, and rejects what a cloud session's proxy does
// (GraphQL-backed commands, --paginate, any API path outside
// repos/{owner}/{repo}/), and a `pup` stub that serves DBM samples and fails
// metric queries unless $FX/timeseries.json exists.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fingerprint, composeIssueBody, buildStateBody } from './db-sweep-lib.mjs';

const ROUTINE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'routine.mjs');
const REPO = 'acme/compliance';
const BILLING = 'acme/billing';
const INST = 'pg-prod-1';
const OTHER = 'pg-prod-2';
// The last sweep ended 8 days ago, so this run reads 8 days (more than the 7-day floor).
const LAST_TICK = Date.now() - 8 * 864e5;

// Fixtures and records are per repo, under $FX/<repo name>/.
const GH_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/gh.log"
[ "$1" = api ] || { echo "stub: only gh api (GraphQL is 403 here)" >&2; exit 9; }
case "$*" in *--paginate*|*graphql*) echo "stub: rejected" >&2; exit 9 ;; esac
case "$2" in repos/acme/compliance/*|repos/acme/billing/*) ;; *) echo "stub: sessions are bound to their configured repositories (HTTP 403)" >&2; exit 9 ;; esac
rest=\${2#repos/acme/}; R="$FX/\${rest%%/*}"; p=\${rest#*/}
case "$p" in
  'issues?state=all&labels=datadog-dbm&per_page=100&page=1') cat "$R/issues.json" ;;
  issues)
    in=$(cat)
    case "$in" in
      *fu-db-sweep-state*) printf '%s' "$in" > "$R/state-created.json"; echo '{"number":77}' ;;
      *) printf '%s\\n' "$in" >> "$R/created.jsonl"; echo '{"number":42}' ;;
    esac ;;
  issues/*/comments) cat >> "$R/comments.jsonl"; printf '\\n' >> "$R/comments.jsonl"; echo '{}' ;;
  issues/*/events*) cat "$R/events.json" ;;
  compare/*) echo "{\\"status\\":\\"$COMPARE\\"}" ;;
  issues/*)
    case "$*" in
      *--method*) case "$*" in *--input*) cat > "$R/patch-\${p##*/}.json" ;; *) echo "$*" >> "$R/patches.log" ;; esac; echo '{}' ;;
      *) cat "$R/issue-\${p##*/}.json" 2>/dev/null || { echo "HTTP 404" >&2; exit 1; } ;;
    esac ;;
  *) echo "stub: unexpected $2" >&2; exit 9 ;;
esac
`;

const PUP_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/pup.log"
case "$*" in
  *'dbm samples search'*)
    sig=$(printf '%s' "$*" | sed -n 's/.*@db.query_signature:\\([0-9a-f]*\\).*/\\1/p')
    printf '{"result":{"events":[{"event":{"custom":{"db":{"statement":"SELECT * FROM t WHERE sig = ? -- %s","metadata":{"tables":["risk.t"]}}}}}]}}' "$sig" ;;
  *'metrics timeseries'*) [ -f "$FX/timeseries.json" ] && cat "$FX/timeseries.json" || { echo "stub: HTTP 403 Forbidden" >&2; exit 1; } ;;
  *) echo "stub: unexpected pup $*" >&2; exit 9 ;;
esac
`;

const stats = (calls, avg, bpc = 10) => ({ timeNs: calls * avg * 1e6, calls, blksHit: calls * bpc, blksRead: 0 });
const q = (sig, win, base = win, inst = INST) => ({ instance: inst, querySignature: sig, window: win, baseline: base, drift: base });
const filler = q('filler', stats(1e7, 0.1));
const quietInstance = { instance: INST, maxBlocked: 0, maxConnPct: 0.1, deadlocks: 0, maxIdleInTxnSeconds: 5, timeNsByDb: { compliance_mono: 1e15 } };
const COLLECTED = {
  db: 'compliance_mono', instances: [INST],
  queries: [
    q('c985631ee7416fa1', stats(245, 104, 75373)), // NEW, heavy
    q('9b67ccf583e62815', stats(2058, 46, 36020)), // already open
    q('accepted00000001', stats(700, 50, 30000)), // wontfix, not worse
    filler,
  ],
  instanceStats: [quietInstance],
  tables: [{ instance: INST, table: 'outbox.inbox_state', deadRows: 140000, liveRows: 0 }], // closed as fixed → gate
};
const fp = (rule, key, inst = INST) => fingerprint(rule, inst, 'compliance_mono', key);
const marked = (number, rule, key, value, extra = {}) => ({
  number, state: 'open', labels: [{ name: 'datadog-dbm' }],
  body: composeIssueBody({ fingerprint: fp(rule, key), measure: { name: 'x', value } }, 'filed earlier'), ...extra,
});

// Both repos are cloned and have issues; compliance's state issue is #5, billing's #6.
function setup({ issues = [], billingIssues = [], stateIssue = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'db-sweep-routine-'));
  const fx = path.join(root, 'fx');
  const bin = path.join(root, 'bin');
  const home = path.join(root, 'home');
  const clones = path.join(root, 'clones');
  for (const d of [fx, bin, home, clones]) fs.mkdirSync(d, { recursive: true });
  for (const [repo, list, n] of [[REPO, issues, 5], [BILLING, billingIssues, 6]]) {
    const name = repo.split('/')[1];
    const clone = path.join(clones, name);
    fs.mkdirSync(clone);
    execFileSync('git', ['init', '-q', clone]);
    execFileSync('git', ['-C', clone, 'remote', 'add', 'origin', `https://github.com/${repo}.git`]);
    const r = path.join(fx, name);
    fs.mkdirSync(r);
    fs.writeFileSync(path.join(r, 'issues.json'), JSON.stringify(list));
    fs.writeFileSync(path.join(r, 'events.json'), JSON.stringify([{ event: 'closed', commit_id: 'f1f1f1f1' }]));
    if (stateIssue) fs.writeFileSync(path.join(r, `issue-${n}.json`), JSON.stringify({ number: n, body: buildStateBody(LAST_TICK) }));
  }
  fs.writeFileSync(path.join(bin, 'gh'), GH_STUB, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'pup'), PUP_STUB, { mode: 0o755 });
  const env = { ...process.env, HOME: home, FX: fx, PATH: `${bin}:${process.env.PATH}`, DB_SWEEP_SEARCH_ROOT: clones, COMPARE: 'behind' };
  const run = (...args) => {
    const r = spawnSync(process.execPath, [ROUTINE, ...args], { env, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout;
  };
  const dir = path.join(home, '.claude', 'db-sweep', 'routine');
  // read('patch-5.json') is compliance's; read('billing/patch-6.json') is billing's.
  const read = (name) => { try { return fs.readFileSync(path.join(fx, name.includes('/') ? name : `compliance/${name}`), 'utf8'); } catch { return ''; } };
  return { run, env, dir, fx, read, log: () => fs.readFileSync(path.join(fx, 'gh.log'), 'utf8') };
}

const CONFIG = (extra = {}) => JSON.stringify({
  stateIssues: { [REPO]: 5 },
  pairs: [{ repo: REPO, db: 'compliance_mono' }, { repo: 'acme/elsewhere', db: 'other_db' }], ...extra,
});
const TWO_REPOS = (extra = {}) => JSON.stringify({
  stateIssues: { [REPO]: 5, [BILLING]: 6 },
  pairs: [{ repo: REPO, db: 'compliance_mono' }, { repo: BILLING, db: 'billing_db' }], ...extra,
});
const STANDARD_ISSUES = [
  marked(10, 'heavy', '9b67ccf583e62815', 36020),
  marked(11, 'heavy', 'accepted00000001', 29000, { state: 'closed', state_reason: 'not_planned', closed_at: '2026-09-01T00:00:00Z' }),
  marked(12, 'hygiene', 'outbox.inbox_state', 120000, { state: 'closed', state_reason: 'completed', closed_at: '2026-10-01T00:00:00Z' }),
];

const verdict = (extra) => ({ actionable: true, reason: 'r', title: 'perf(compliance_mono): t', body: 'A long enough body naming src/Risk/Spec.cs:12 and the numbers.', sql: 'select 1', sqlConfidence: 'high', codePaths: [], deployedSha: '0e789f0a', ...extra });

// data: one collector output for every pair, or a function of the pair's db.
function writeCollectors(s, data = COLLECTED) {
  const run = JSON.parse(fs.readFileSync(path.join(s.dir, 'run.json'), 'utf8'));
  for (const p of run.pairs.filter((x) => x.active)) {
    const d = typeof data === 'function' ? data(p.db) : data;
    fs.writeFileSync(p.outputFile, JSON.stringify(d.error ? d : { ...d, db: p.db }));
  }
}

const planCandidates = (plan) => Object.values(plan.repos).flatMap((r) => r.candidates);

function writeVerdicts(s, byClass = {}) {
  const plan = JSON.parse(fs.readFileSync(path.join(s.dir, 'plan.json'), 'utf8'));
  for (const cf of planCandidates(plan)) {
    const c = JSON.parse(fs.readFileSync(cf, 'utf8'));
    const v = byClass[c.classification] ?? (c.classification === 'NEW' ? verdict() : verdict({ body: undefined, comment: 'Still breaching: 140,000 dead rows.' }));
    fs.writeFileSync(c.outputFile, JSON.stringify(v));
  }
  return plan;
}

const quiet = { ...COLLECTED, queries: [filler], tables: [] };

test('live: files the new finding, holds an undeployed fix, keeps accepted and open ones, posts the summary, advances state', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  const out = s.run('prepare', '--live', CONFIG());
  assert.match(out, /^PROCEED 1 pair\(s\) live/);
  const run = JSON.parse(fs.readFileSync(path.join(s.dir, 'run.json'), 'utf8'));
  assert.equal(run.repos[REPO].spans.window.from, new Date(LAST_TICK).toISOString());

  writeCollectors(s);
  const planOut = s.run('plan');
  assert.match(planOut, /^PROCEED 2 — 1 repo\(s\) with candidates/);
  assert.match(planOut, /acme\/compliance: findings=4 already-open=1 accepted=1 candidates=2/);
  assert.match(planOut, /acme\/elsewhere: skipped — not attached/);
  // A query candidate carries its statement from DBM; a table candidate has none.
  const cands = Object.fromEntries(planCandidates(writeVerdicts(s)).map((cf) => JSON.parse(fs.readFileSync(cf, 'utf8'))).map((c) => [c.finding.rule, c]));
  assert.equal(cands.heavy.sql, 'SELECT * FROM t WHERE sig = ? -- c985631ee7416fa1');
  assert.deepEqual(cands.heavy.sqlTables, ['risk.t']);
  assert.equal(cands.hygiene.sql, null);
  assert.match(fs.readFileSync(path.join(s.fx, 'pup.log'), 'utf8'), new RegExp(`dbm samples search --query @db.query_signature:c985631ee7416fa1 host:${INST} --from \\S+ --to \\S+ --limit 1`));
  const fin = s.run('finish');
  assert.match(fin, /^SWEPT — filed=1 held=1 dropped=0 failed=0/);
  assert.match(fin, /acme\/compliance#42 created \(med\)/);
  assert.match(fin, /held #12 .*fix not deployed yet/);

  const created = s.read('created.jsonl').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].labels, ['datadog-dbm', 'auto-filed', 'sev:med']);
  assert.match(created[0].body, new RegExp(`dd-dbm: \\{"fp":"${fp('heavy', 'c985631ee7416fa1')}"`));
  assert.match(s.read('comments.jsonl'), /DB perf sweep — SWEPT/);
  assert.match(s.read('patch-5.json'), /fu-db-sweep-state/);
  assert.doesNotMatch(s.read('patches.log'), /issues\/12 .*state=open/);
  for (const line of s.log().trim().split('\n')) assert.match(line, /^api repos\/acme\/compliance\//);
});

test('each repo gets its own summary and state, in its own repo', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--live', TWO_REPOS());
  writeCollectors(s, (db) => (db === 'billing_db' ? quiet : COLLECTED));
  const planOut = s.run('plan');
  assert.match(planOut, /acme\/billing: findings=0 .*candidates=0/);
  // billing had nothing to file, so its summary and state land at plan time
  assert.match(s.read('billing/comments.jsonl'), /DB perf sweep — nothing to file/);
  assert.match(s.read('billing/patch-6.json'), /fu-db-sweep-state/);
  assert.equal(s.read('comments.jsonl'), '');
  writeVerdicts(s);
  s.run('finish');
  assert.match(s.read('comments.jsonl'), /DB perf sweep — SWEPT/);
  assert.doesNotMatch(s.read('comments.jsonl'), /billing_db/);
  assert.doesNotMatch(s.read('billing/comments.jsonl'), /compliance_mono/);
  assert.equal(s.read('billing/created.jsonl'), '');
});

test('a fix that is deployed reopens the closed issue with a comment', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.env.COMPARE = 'ahead';
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s);
  s.run('plan');
  writeVerdicts(s);
  const fin = s.run('finish');
  assert.match(fin, /acme\/compliance#12 reopened \(low\)/);
  assert.match(s.read('patches.log'), /issues\/12 --method PATCH -f state=open/);
  assert.match(s.read('comments.jsonl'), /Still breaching/);
});

test('observe: posts the summary with drafts, files nothing, never advances state', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--observe', CONFIG());
  writeCollectors(s);
  s.run('plan');
  writeVerdicts(s);
  const fin = s.run('finish');
  assert.match(fin, /^OBSERVED — would-file=1 held=1/);
  assert.equal(s.read('created.jsonl'), '');
  assert.equal(s.read('patch-5.json'), '');
  assert.match(s.read('comments.jsonl'), /<details><summary>create: perf\(compliance_mono\): t/);
});

test('a failed collector fails only its repo: failed summary there, nothing filed, its state kept', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--live', TWO_REPOS());
  writeCollectors(s, (db) => (db === 'billing_db' ? { error: 'Datadog 429 Too Many Requests' } : COLLECTED));
  const out = s.run('plan');
  assert.match(out, /^PROCEED 2 — 1 repo\(s\) with candidates, 0 with nothing to file, 1 failed/);
  assert.match(out, /acme\/billing: FAILED — billing_db: .*429/);
  assert.match(s.read('billing/comments.jsonl'), /DB perf sweep — FAILED.*429/s);
  assert.equal(s.read('billing/patch-6.json'), '');
  writeVerdicts(s);
  assert.match(s.run('finish'), /^SWEPT — filed=1/);
  assert.match(s.read('patch-5.json'), /fu-db-sweep-state/);
  assert.equal(s.read('billing/created.jsonl'), '');
});

test('every repo failing is FAILED with nothing pending', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s, { error: 'Datadog 401 Unauthorized' });
  assert.match(s.run('plan'), /^FAILED — 1 repo\(s\) failed, 0 had nothing to file/);
  assert.match(s.read('comments.jsonl'), /DB perf sweep — FAILED.*Datadog 401/s);
  assert.equal(s.read('patch-5.json'), '');
  assert.equal(s.read('created.jsonl'), '');
  assert.match(s.run('finish'), /^NOTHING_PENDING/);
});

test('a failed or missing verdict files nothing for it and keeps the state', () => {
  const s = setup();
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s);
  s.run('plan');
  writeVerdicts(s, { NEW: { actionable: true, reason: 'r', title: 't', body: 'short' } });
  const fin = s.run('finish');
  assert.match(fin, /failed=\d/);
  assert.match(fin, /state not advanced/);
  assert.equal(s.read('patch-5.json'), '');
});

test('the cap is per repo: keeps each repo\'s 5 most severe and lists the rest', () => {
  const s = setup();
  const queries = [...Array.from({ length: 7 }, (_, i) => q(`heavy0000000000${i}`, stats(300, 50 + i, 30000))), filler];
  queries.push(q('regress000000001', stats(1400, 50), stats(1400, 8)));
  s.run('prepare', '--live', TWO_REPOS());
  writeCollectors(s, { ...COLLECTED, queries, tables: [] });
  const out = s.run('plan');
  assert.match(out, /^PROCEED 10 /);
  assert.equal((out.match(/--- investigator /g) || []).length, 10);
  const plan = JSON.parse(fs.readFileSync(path.join(s.dir, 'plan.json'), 'utf8'));
  for (const repo of [REPO, BILLING]) {
    const r = plan.repos[repo];
    assert.equal(r.candidates.length, 5);
    assert.equal(JSON.parse(fs.readFileSync(r.candidates[0], 'utf8')).finding.querySignature, 'regress000000001');
    assert.equal(r.notes.filter((n) => /over the 5-per-repo cap/.test(n)).length, 3);
  }
});

test('nothing to file: NO_WORK, summary posted, state advanced on a live run', () => {
  const s = setup();
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s, quiet);
  const out = s.run('plan');
  assert.match(out, /^NO_WORK — 1 repo\(s\) had nothing to file/);
  assert.match(s.read('comments.jsonl'), /nothing to file/);
  assert.match(s.read('patch-5.json'), /fu-db-sweep-state/);
});

test('no stateIssues entry: the repo\'s first live run creates and closes one and says to configure it', () => {
  const s = setup({ stateIssue: false });
  const out = s.run('prepare', '--live', CONFIG({ stateIssues: undefined }));
  assert.match(out, /^PROCEED/);
  writeCollectors(s, quiet);
  const plan = s.run('plan');
  assert.match(plan, /acme\/compliance: state issue created #77 — add "acme\/compliance": 77 to CONFIG.stateIssues/);
  assert.match(s.read('patches.log'), /issues\/77 --method PATCH -f state=closed/);
  assert.match(s.read('state-created.json'), /fu-db-sweep-state/);
});

test('bad config and unreachable pairs skip the run', () => {
  const s = setup();
  assert.match(s.run('prepare', '--live', '{"pairs":[]}'), /^SKIP — CONFIG.pairs/);
  assert.match(s.run('prepare', '--live', JSON.stringify({ stateRepo: REPO, stateIssue: 5, pairs: [{ repo: REPO, db: 'x' }] })), /^SKIP — .*replaced by stateIssues/);
  assert.match(s.run('prepare', '--live', JSON.stringify({ pairs: [{ repo: 'acme/elsewhere', db: 'x' }] })), /^SKIP — no \(repo, db\) pair is reachable/);
});

test('a second prod instance is its own finding', () => {
  const s = setup();
  s.run('prepare', '--live', CONFIG());
  const data = { ...COLLECTED, instances: [INST, OTHER], tables: [],
    queries: [q('c985631ee7416fa1', stats(245, 104, 75373)), q('c985631ee7416fa1', stats(245, 104, 75373), undefined, OTHER), filler] };
  writeCollectors(s, data);
  const out = s.run('plan');
  assert.match(out, /^PROCEED 2 /);
});

test('collect: a pup failure becomes that pair\'s error, and plan fails its repo', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--live', CONFIG());
  assert.match(s.run('collect'), /^COLLECTED 0\/1/);
  const run = JSON.parse(fs.readFileSync(path.join(s.dir, 'run.json'), 'utf8'));
  assert.match(JSON.parse(fs.readFileSync(run.pairs[0].outputFile, 'utf8')).error, /HTTP 403/);
  assert.match(s.run('plan'), /^FAILED — 1 repo\(s\) failed/);
  assert.match(s.read('comments.jsonl'), /DB perf sweep — FAILED/);
  assert.equal(s.read('patch-5.json'), '');
});

test('wait: READY once every investigator output exists, TIMEOUT naming the missing ones', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--live', TWO_REPOS());
  s.env.DB_SWEEP_WAIT_SECONDS = '0';
  writeCollectors(s);
  s.run('plan');
  assert.match(s.run('wait', 'investigate'), /^TIMEOUT 0\/\d+ — missing: inv-/);
  writeVerdicts(s);
  assert.match(s.run('wait', 'investigate'), /^READY (\d+)\/\1/);
});
