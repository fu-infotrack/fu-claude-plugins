// routine.mjs end to end, hermetic: a throwaway $HOME, fake target clones found
// through DB_SWEEP_SEARCH_ROOT, and a `gh` stub on PATH that serves REST
// fixtures, records every call, and rejects what a cloud session's proxy does:
// GraphQL-backed commands, --paginate, and any API path outside repos/{owner}/{repo}/.
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
const INST = 'pg-prod-1';
const OTHER = 'pg-prod-2';
// The last sweep ended 8 days ago, so this run reads 8 days (more than the 7-day floor).
const LAST_TICK = Date.now() - 8 * 864e5;

const GH_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/gh.log"
[ "$1" = api ] || { echo "stub: only gh api (GraphQL is 403 here)" >&2; exit 9; }
case "$*" in *--paginate*|*graphql*) echo "stub: rejected" >&2; exit 9 ;; esac
case "$2" in repos/acme/compliance/*) ;; *) echo "stub: sessions are bound to their configured repositories (HTTP 403)" >&2; exit 9 ;; esac
case "$2" in
  'repos/acme/compliance/issues?state=all&labels=datadog-dbm&per_page=100&page=1') cat "$FX/issues.json" ;;
  repos/acme/compliance/issues)
    in=$(cat)
    case "$in" in
      *fu-db-sweep-state*) printf '%s' "$in" > "$FX/state-created.json"; echo '{"number":77}' ;;
      *) printf '%s\\n' "$in" >> "$FX/created.jsonl"; echo '{"number":42}' ;;
    esac ;;
  repos/acme/compliance/issues/*/comments) cat >> "$FX/comments.jsonl"; printf '\\n' >> "$FX/comments.jsonl"; echo '{}' ;;
  repos/acme/compliance/issues/*/events*) cat "$FX/events.json" ;;
  repos/acme/compliance/compare/*) echo "{\\"status\\":\\"$COMPARE\\"}" ;;
  repos/acme/compliance/issues/*)
    case "$*" in
      *--method*) case "$*" in *--input*) cat > "$FX/patch-\${2##*/}.json" ;; *) echo "$*" >> "$FX/patches.log" ;; esac; echo '{}' ;;
      *) cat "$FX/issue-\${2##*/}.json" 2>/dev/null || { echo "HTTP 404" >&2; exit 1; } ;;
    esac ;;
  *) echo "stub: unexpected $2" >&2; exit 9 ;;
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

function setup({ issues = [], stateIssue = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'db-sweep-routine-'));
  const fx = path.join(root, 'fx');
  const bin = path.join(root, 'bin');
  const home = path.join(root, 'home');
  const clones = path.join(root, 'clones');
  for (const d of [fx, bin, home, clones]) fs.mkdirSync(d, { recursive: true });
  const clone = path.join(clones, 'compliance');
  fs.mkdirSync(clone);
  execFileSync('git', ['init', '-q', clone]);
  execFileSync('git', ['-C', clone, 'remote', 'add', 'origin', `https://github.com/${REPO}.git`]);
  fs.writeFileSync(path.join(bin, 'gh'), GH_STUB, { mode: 0o755 });
  fs.writeFileSync(path.join(fx, 'issues.json'), JSON.stringify(issues));
  fs.writeFileSync(path.join(fx, 'events.json'), JSON.stringify([{ event: 'closed', commit_id: 'f1f1f1f1' }]));
  if (stateIssue) fs.writeFileSync(path.join(fx, 'issue-5.json'), JSON.stringify({ number: 5, body: buildStateBody(LAST_TICK) }));
  const env = { ...process.env, HOME: home, FX: fx, PATH: `${bin}:${process.env.PATH}`, DB_SWEEP_SEARCH_ROOT: clones, COMPARE: 'behind' };
  const run = (...args) => {
    const r = spawnSync(process.execPath, [ROUTINE, ...args], { env, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout;
  };
  const dir = path.join(home, '.claude', 'db-sweep', 'routine');
  const read = (name) => { try { return fs.readFileSync(path.join(fx, name), 'utf8'); } catch { return ''; } };
  return { run, env, dir, fx, clone, read, log: () => read('gh.log') };
}

const CONFIG = (extra = {}) => JSON.stringify({
  stateRepo: REPO, stateIssue: 5,
  pairs: [{ repo: REPO, db: 'compliance_mono' }, { repo: 'acme/elsewhere', db: 'other_db' }], ...extra,
});
const STANDARD_ISSUES = [
  marked(10, 'heavy', '9b67ccf583e62815', 36020),
  marked(11, 'heavy', 'accepted00000001', 29000, { state: 'closed', state_reason: 'not_planned', closed_at: '2026-09-01T00:00:00Z' }),
  marked(12, 'hygiene', 'outbox.inbox_state', 120000, { state: 'closed', state_reason: 'completed', closed_at: '2026-10-01T00:00:00Z' }),
];

const verdict = (extra) => ({ actionable: true, reason: 'r', title: 'perf(compliance_mono): t', body: 'A long enough body naming src/Risk/Spec.cs:12 and the numbers.', sql: 'select 1', sqlConfidence: 'high', codePaths: [], deployedSha: '0e789f0a', ...extra });

function writeCollectors(s, data = COLLECTED) {
  const run = JSON.parse(fs.readFileSync(path.join(s.dir, 'run.json'), 'utf8'));
  for (const p of run.pairs.filter((x) => x.active)) fs.writeFileSync(p.outputFile, JSON.stringify(data));
}

function writeVerdicts(s, byClass = {}) {
  const plan = JSON.parse(fs.readFileSync(path.join(s.dir, 'plan.json'), 'utf8'));
  for (const cf of plan.candidates) {
    const c = JSON.parse(fs.readFileSync(cf, 'utf8'));
    const v = byClass[c.classification] ?? (c.classification === 'NEW' ? verdict() : verdict({ body: undefined, comment: 'Still breaching: 140,000 dead rows.' }));
    fs.writeFileSync(c.outputFile, JSON.stringify(v));
  }
  return plan;
}

test('live: files the new finding, holds an undeployed fix, keeps accepted and open ones, posts the summary, advances state', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  const out = s.run('prepare', '--live', CONFIG());
  assert.match(out, /^PROCEED 1 collectors live/);
  assert.match(out, /--- collector p0 compliance_mono ---/);
  assert.doesNotMatch(out, /other_db/);
  const query = fs.readFileSync(path.join(s.dir, 'query-p0.js'), 'utf8');
  assert.ok(query.includes(`const PARAMS = {"db":"compliance_mono","window":{"from":"${new Date(LAST_TICK).toISOString()}"`));

  writeCollectors(s);
  const planOut = s.run('plan');
  assert.match(planOut, /^PROCEED 2 — findings=4 already-open=1 accepted=1 candidates=2/);
  writeVerdicts(s);
  const fin = s.run('finish');
  assert.match(fin, /^SWEPT — filed=1 held=1 dropped=0 failed=0/);
  assert.match(fin, /acme\/compliance#42 created \(med\)/);
  assert.match(fin, /held acme\/compliance#12 .*fix not deployed yet/);
  assert.match(fin, /skipped acme\/elsewhere other_db — not attached/);

  const created = s.read('created.jsonl').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].labels, ['datadog-dbm', 'auto-filed', 'sev:med']);
  assert.match(created[0].body, new RegExp(`dd-dbm: \\{"fp":"${fp('heavy', 'c985631ee7416fa1')}"`));
  assert.match(s.read('comments.jsonl'), /DB perf sweep — SWEPT/);
  assert.match(s.read('patch-5.json'), /fu-db-sweep-state/);
  assert.doesNotMatch(s.read('patches.log'), /issues\/12 .*state=open/);
  for (const line of s.log().trim().split('\n')) assert.match(line, /^api repos\/acme\/compliance\//);
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
  assert.match(s.read('comments.jsonl'), /<details><summary>create in acme\/compliance: perf\(compliance_mono\): t/);
});

test('a failed collector fails the run: failed summary, nothing filed, state kept', () => {
  const s = setup({ issues: STANDARD_ISSUES });
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s, { error: 'Datadog 401 Unauthorized' });
  const out = s.run('plan');
  assert.match(out, /^FAILED — 1 collector\(s\) failed; nothing filed, state not advanced/);
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

test('the per-run cap keeps the 5 most severe and lists the rest', () => {
  const s = setup();
  const queries = [...Array.from({ length: 7 }, (_, i) => q(`heavy0000000000${i}`, stats(300, 50 + i, 30000))), filler];
  queries.push(q('regress000000001', stats(1400, 50), stats(1400, 8)));
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s, { ...COLLECTED, queries, tables: [] });
  const out = s.run('plan');
  assert.match(out, /^PROCEED 5 /);
  assert.equal((out.match(/--- investigator /g) || []).length, 5);
  const plan = JSON.parse(fs.readFileSync(path.join(s.dir, 'plan.json'), 'utf8'));
  const first = JSON.parse(fs.readFileSync(plan.candidates[0], 'utf8'));
  assert.equal(first.finding.querySignature, 'regress000000001');
  assert.equal(plan.notes.filter((n) => /over the 5-per-run cap/.test(n)).length, 3);
});

test('nothing to file: NO_WORK, summary posted, state advanced on a live run', () => {
  const s = setup();
  s.run('prepare', '--live', CONFIG());
  writeCollectors(s, { ...COLLECTED, queries: [filler], tables: [] });
  const out = s.run('plan');
  assert.match(out, /^NO_WORK — findings=0/);
  assert.match(s.read('comments.jsonl'), /nothing to file/);
  assert.match(s.read('patch-5.json'), /fu-db-sweep-state/);
});

test('no stateIssue: the first live run creates and closes one and says to configure it', () => {
  const s = setup({ stateIssue: false });
  const out = s.run('prepare', '--live', CONFIG({ stateIssue: undefined }));
  assert.match(out, /^PROCEED/);
  writeCollectors(s, { ...COLLECTED, queries: [filler], tables: [] });
  const plan = s.run('plan');
  assert.match(plan, /state issue created: acme\/compliance#77 — add "stateIssue": 77/);
  assert.match(s.read('patches.log'), /issues\/77 --method PATCH -f state=closed/);
  assert.match(s.read('state-created.json'), /fu-db-sweep-state/);
});

test('bad config and unreachable pairs skip the run', () => {
  const s = setup();
  assert.match(s.run('prepare', '--live', '{"stateRepo":"acme/compliance","pairs":[]}'), /^SKIP — CONFIG.pairs/);
  assert.match(s.run('prepare', '--live', JSON.stringify({ stateRepo: REPO, pairs: [{ repo: 'acme/elsewhere', db: 'x' }] })), /^SKIP — no \(repo, db\) pair is reachable/);
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
