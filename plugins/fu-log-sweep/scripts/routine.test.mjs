// routine.mjs end to end, hermetic: a throwaway $HOME, two fake target clones
// found through LOG_SWEEP_SEARCH_ROOT, a `gh` stub on PATH that serves REST
// fixtures, records every call, and rejects what a cloud session's proxy does
// (GraphQL-backed commands, --paginate, any API path outside
// repos/{owner}/{repo}/), and a `pup` stub that serves log aggregates and
// samples from $FX/pup.json.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSignature, buildBucketQuery, buildLogQuery } from './log-sweep-lib.mjs';

const ROUTINE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'routine.mjs');
const NS = ['Acme'];
const FACET = '@Properties.exception.type';
const WIDGETS = 'acme/widgets';
const GADGETS = 'acme/gadgets';
const SERVICE = { [WIDGETS]: 'orders-api', [GADGETS]: 'gizmo-api' };
const stack = (method) => `Acme.Boom: no\n   at Acme.Orders.${method}() in /app/src/Orders.cs:line 9\n   at System.Threading.Tasks.Task.Run()`;
const bucket = (kind, method, count, versions = [], service = 'orders-api') => ({
  errorKind: kind, service, count, versions,
  samples: [{ timestamp: '2026-10-22T08:00:00Z', message: `${kind} failed`, stack: stack(method) }],
});
const sigOf = (b) => buildSignature(b.errorKind, b.service, b.samples[0].stack, b.samples[0].message, NS).sig;
const bucketQ = (b, facet = FACET) => buildBucketQuery(b.service, 'prod', 'status:error', facet, b.errorKind);

// Fixtures and records are per repo, under $FX/<repo name>/.
const GH_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/gh.log"
[ "$1" = api ] || { echo "stub: only gh api (GraphQL is 403 here)" >&2; exit 9; }
case "$*" in *--paginate*|*graphql*) echo "stub: rejected" >&2; exit 9 ;; esac
case "$2" in repos/acme/widgets/*|repos/acme/gadgets/*) ;; *) echo "stub: sessions are bound to their configured repositories (HTTP 403)" >&2; exit 9 ;; esac
rest=\${2#repos/acme/}; R="$FX/\${rest%%/*}"; p=\${rest#*/}
case "$p" in
  'issues?state=all&labels=datadog-logs&per_page=100&page=1')
    [ -f "$R/issues-fail" ] && { echo "HTTP 500" >&2; exit 1; }; cat "$R/issues.json" ;;
  'releases?per_page=30') cat "$R/releases.json" ;;
  issues)
    in=$(cat)
    case "$in" in
      *log-sweep-state*) printf '%s' "$in" > "$R/state-created.json"; echo '{"number":77}' ;;
      *) printf '%s\\n' "$in" >> "$R/created.jsonl"; echo '{"number":42}' ;;
    esac ;;
  issues/*/comments) cat > "$R/comment.json"; echo '{}' ;;
  issues/*)
    case "$*" in
      *--method*) case "$*" in *--input*) cat > "$R/patch-\${p##*/}.json" ;; esac; echo '{}' ;;
      *) [ -n "$GH_FAIL_STATE" ] && { echo "HTTP 502" >&2; exit 1; }
         cat "$R/issue-\${p##*/}.json" 2>/dev/null || { echo "HTTP 404" >&2; exit 1; } ;;
    esac ;;
  *) echo "stub: unexpected $2" >&2; exit 9 ;;
esac
`;

// Serves $FX/pup.json: {agg: {query: buckets}, search: {query: event}, versions: {query: [{version, count}]}, fail: [query]}.
const PUP_STUB = `#!/usr/bin/env node
const fs = require('fs');
const a = process.argv.slice(2);
fs.appendFileSync(process.env.FX + '/pup.log', JSON.stringify(a) + '\\n');
const fx = JSON.parse(fs.readFileSync(process.env.FX + '/pup.json', 'utf8'));
const flag = (n) => a[a.indexOf(n) + 1];
const q = flag('--query');
if (a[0] !== '--no-agent' || a[1] !== 'logs') { process.stderr.write('stub: unexpected pup ' + a.join(' ')); process.exit(9); }
if ((fx.fail || []).includes(q)) { process.stderr.write('Error: HTTP 403 Forbidden'); process.exit(1); }
const out = (x) => process.stdout.write(JSON.stringify(x));
if (a[2] === 'aggregate') {
  const gb = flag('--group-by');
  if (gb.endsWith(',service')) out({ data: { buckets: (fx.agg[q] || []).map((b) => ({ by: { [gb.split(',')[0]]: b.errorKind, service: b.service }, computes: { c0: b.count } })) } });
  else out({ data: { buckets: ((fx.versions || {})[q] || []).map((v) => ({ by: { [gb]: v.version }, computes: { c0: v.count } })) } });
} else if (a[2] === 'search') out({ data: (fx.search || {})[q] ? [fx.search[q]] : [] });
else { process.stderr.write('stub: unexpected pup ' + a.join(' ')); process.exit(9); }
`;

// NEW, ALREADY_OPEN, a REGRESSION held (only on a pre-fix build), a REGRESSION
// reopened (on a post-fix build), and one under the threshold.
const NEW = bucket('Acme.NewError', 'Create', 9);
const OPEN = bucket('Acme.OpenError', 'Read', 8);
const HELD = bucket('Acme.HeldError', 'Update', 7, [{ version: 'v1', count: 7 }]);
const BACK = bucket('Acme.BackError', 'Delete', 6, [{ version: 'v2', count: 2 }, { version: 'v1', count: 4 }]);
const TINY = bucket('Acme.TinyError', 'List', 1);
const GIZMO = bucket('Acme.GizmoError', 'Spin', 5, [], 'gizmo-api');

const event = (b, stackAt = (s) => ({ Exception: s })) => ({
  attributes: { timestamp: b.samples[0].timestamp, message: b.samples[0].message, attributes: stackAt(b.samples[0].stack) },
});

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'log-sweep-routine-'));
  const fx = path.join(root, 'fx');
  const bin = path.join(root, 'bin');
  const clones = path.join(root, 'clones');
  for (const d of [fx, bin, clones, path.join(fx, 'widgets'), path.join(fx, 'gadgets')]) fs.mkdirSync(d);
  fs.writeFileSync(path.join(bin, 'gh'), GH_STUB, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'pup'), PUP_STUB, { mode: 0o755 });
  const dirs = {};
  for (const repo of [WIDGETS, GADGETS]) {
    const d = path.join(clones, repo.split('/')[1]);
    execFileSync('git', ['init', '-q', d]);
    execFileSync('git', ['-C', d, 'remote', 'add', 'origin', `https://github.com/${repo}.git`]);
    fs.writeFileSync(path.join(d, 'k8_settings.json'), JSON.stringify({ app_name: SERVICE[repo] }));
    fs.writeFileSync(path.join(fx, repo.split('/')[1], 'issues.json'), '[]');
    fs.writeFileSync(path.join(fx, repo.split('/')[1], 'releases.json'), '[]');
    dirs[repo] = d;
  }
  const marker = (b) => `<!-- dd-log-sig: ${sigOf(b)} -->`;
  fs.writeFileSync(path.join(fx, 'widgets', 'issues.json'), JSON.stringify([
    { number: 5, state: 'open', body: marker(OPEN) },
    { number: 7, state: 'closed', closed_at: '2026-10-10T00:00:00Z', body: marker(HELD) },
    { number: 8, state: 'closed', closed_at: '2026-10-10T00:00:00Z', body: marker(BACK) },
  ]));
  fs.writeFileSync(path.join(fx, 'widgets', 'releases.json'), JSON.stringify([
    { tag_name: 'v2', published_at: '2026-10-12T00:00:00Z' },
    { tag_name: 'v1', published_at: '2026-10-01T00:00:00Z' },
  ]));
  const env = { ...process.env, HOME: path.join(root, 'home'), PATH: `${bin}:${process.env.PATH}`, FX: fx, LOG_SWEEP_SEARCH_ROOT: clones, LOG_SWEEP_RETRY_MS: '1' };
  const run = (args, extra = {}) => {
    const r = spawnSync(process.execPath, [ROUTINE, ...args], { cwd: root, env: { ...env, ...extra }, encoding: 'utf8' });
    assert.equal(r.stderr, '', 'stderr stays empty');
    return r.stdout;
  };
  const dir = path.join(env.HOME, '.claude', 'log-sweep', 'routine');
  const read = (rel) => fs.readFileSync(path.join(fx, rel), 'utf8');
  const ghLog = () => (fs.existsSync(path.join(fx, 'gh.log')) ? read('gh.log') : '');
  const pupCalls = () => (fs.existsSync(path.join(fx, 'pup.log')) ? read('pup.log').trim().split('\n').map((l) => JSON.parse(l)) : []);
  // Datadog: each repo's buckets, every bucket's newest event, and the regressions' versions.
  const datadog = (byRepo, { fail = [], stackAt } = {}) => {
    const fixture = { agg: {}, search: {}, versions: {}, fail };
    for (const [repo, buckets] of Object.entries(byRepo)) {
      const facet = stackAt ? '@error.kind' : FACET;
      fixture.agg[buildLogQuery([SERVICE[repo]], 'prod', 'status:error')] = buckets;
      for (const b of buckets) {
        fixture.search[bucketQ(b, facet)] = event(b, stackAt);
        fixture.versions[bucketQ(b, facet)] = b.versions;
      }
    }
    fs.writeFileSync(path.join(fx, 'pup.json'), JSON.stringify(fixture));
  };
  return { fx, dirs, dir, run, read, ghLog, pupCalls, datadog };
}

const config = (extra = {}, repos = [WIDGETS]) => JSON.stringify({ appNamespace: NS, count: 2, repos: repos.map((repo) => ({ repo })), ...extra });
const prompts = (out) => out.split('\n').filter((l) => l.startsWith('--- '));
const value = (out, key) => out.split('\n').find((l) => l.startsWith(`${key}=`))?.slice(key.length + 1);
const verdict = (t, repoId, b, v) => fs.writeFileSync(path.join(t.dir, `inv-${repoId}-${sigOf(b)}.json`), JSON.stringify(v));
const steps = (t, mode, cfg) => {
  const p = t.run(['prepare', mode, cfg]);
  assert.match(p, /^PROCEED /);
  assert.match(t.run(['collect']), /^COLLECTED /);
  return t.run(['plan']);
};

test('plan: NEW and a post-fix REGRESSION proceed; open, held and tiny do not', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW, OPEN, HELD, BACK, TINY] });
  const out = steps(t, '--live', config());
  assert.equal(out.split('\n')[0], 'PROCEED 2 — 1 repo(s) with candidates, 0 with nothing to file, 0 failed');
  assert.match(out, /acme\/widgets: buckets=5 kept=4 already-open=1 candidates=2/);
  assert.deepEqual(prompts(out), [`--- investigator ${sigOf(NEW)} ---`, `--- investigator ${sigOf(BACK)} ---`]);
  const back = JSON.parse(fs.readFileSync(path.join(t.dir, `cand-r0-${sigOf(BACK)}.json`), 'utf8'));
  assert.equal(back.classification, 'REGRESSION');
  assert.equal(back.number, 8);
  assert.equal(back.postFixCount, 2);
  assert.equal(back.frame, 'Acme.Orders.Delete');
  assert.equal(back.stackPath, 'attributes.attributes.Exception');
  assert.equal(back.logsUrl, `https://ap2.datadoghq.com/logs?query=${encodeURIComponent(bucketQ(BACK))}`);
  assert.equal(value(out, 'SOURCE_DIR'), t.dirs[WIDGETS]);
  // Versions are read only for the two regressions; the tiny bucket is never sampled.
  const calls = t.pupCalls();
  assert.equal(calls.filter((a) => a[2] === 'search').length, 4);
  assert.deepEqual(calls.filter((a) => a[2] === 'aggregate' && a.includes('version')).map((a) => a[a.indexOf('--query') + 1]), [bucketQ(HELD), bucketQ(BACK)]);
  for (const a of calls) assert.deepEqual(a.slice(3, 5), ['--storage', 'indexes']);
  assert.equal(calls[0][calls[0].indexOf('--limit') + 1], '100', 'pup defaults to 10 groups per facet');
});

test('finish (live): creates the NEW issue with our marker, reopens and comments the regression', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW, OPEN, HELD, BACK, TINY] });
  steps(t, '--live', config());
  verdict(t, 'r0', NEW, { actionable: true, reason: 'app bug', severity: 'high', body: 'drafted <!-- dd-log-sig: 000000000000 -->' });
  verdict(t, 'r0', BACK, { actionable: true, reason: 'back', severity: 'med', body: 'b', comment: '**Regressed**' });
  assert.equal(t.run(['wait', 'investigate']), 'READY 2/2\n');
  const out = t.run(['finish']);
  assert.equal(out.split('\n')[0], 'SWEPT — filed=2 dropped=0 failed=0');
  assert.match(out, /acme\/widgets: filed=2 dropped=0 failed=0/);
  assert.match(out, /#42 created \(high\)/);
  assert.match(out, /#8 reopened \(med\)/);
  assert.match(out, /held .* #7: fix not in prod yet \(still on v1\)/);
  const created = JSON.parse(t.read('widgets/created.jsonl'));
  assert.equal(created.body, `<!-- dd-log-sig: ${sigOf(NEW)} -->\n\ndrafted`);
  assert.deepEqual(created.labels, ['datadog-logs', 'auto-filed', 'sev:high']);
  assert.equal(JSON.parse(t.read('widgets/comment.json')).body, '**Regressed**');
  assert.match(t.ghLog(), /^api repos\/acme\/widgets\/issues\/8 --method PATCH -f state=open$/m);
  assert.equal(t.run(['finish']), 'NOTHING_PENDING\n', 'a second finish files nothing');
});

test('finish (observe): touches no GitHub write API', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW, OPEN, HELD, BACK, TINY] });
  steps(t, '--observe', config());
  verdict(t, 'r0', NEW, { actionable: true, reason: 'app bug', severity: 'low', body: 'b' });
  verdict(t, 'r0', BACK, { actionable: false, reason: 'client cancelled' });
  const out = t.run(['finish']);
  assert.equal(out.split('\n')[0], 'OBSERVED — would-file=1 dropped=1 failed=0');
  assert.match(out, /would create \(low\)/);
  assert.match(out, /dropped .* client cancelled/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});

test('finish: a missing or malformed verdict files nothing for that signature', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW, OPEN, HELD, BACK, TINY] });
  steps(t, '--live', config());
  verdict(t, 'r0', BACK, { actionable: true, reason: 'r', severity: 'med', body: 'b' });
  assert.match(t.run(['wait', 'investigate'], { LOG_SWEEP_WAIT_SECONDS: '0' }), new RegExp(`^TIMEOUT 1/2 — missing: inv-r0-${sigOf(NEW)}\\.json`));
  const out = t.run(['finish']);
  assert.equal(out.split('\n')[0], 'SWEPT — filed=0 dropped=0 failed=2');
  assert.match(out, /FAILED .* no verdict file/);
  assert.match(out, /FAILED .* needs a comment/);
  assert.match(out, /state not saved: 2 failed/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});

test('repos are swept on their own: one failing collection fails only its repo', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW], [GADGETS]: [GIZMO] }, { fail: [buildLogQuery(['orders-api'], 'prod', 'status:error')] });
  fs.writeFileSync(path.join(t.fx, 'gadgets', 'issue-9.json'), JSON.stringify({ body: '<!-- fu-log-sweep-state: {"last_successful_tick":1} -->' }));
  fs.writeFileSync(path.join(t.fx, 'widgets', 'issue-3.json'), JSON.stringify({ body: '<!-- fu-log-sweep-state: {"last_successful_tick":1} -->' }));
  const cfg = config({ stateIssues: { [WIDGETS]: 3, [GADGETS]: 9 } }, [WIDGETS, GADGETS]);
  assert.match(t.run(['prepare', '--live', cfg]), /^PROCEED 2 repo\(s\) live/);
  assert.equal(t.run(['collect']), 'COLLECTED 1/2\n');
  const out = t.run(['plan']);
  assert.equal(out.split('\n')[0], 'PROCEED 1 — 1 repo(s) with candidates, 0 with nothing to file, 1 failed');
  assert.match(out, /acme\/widgets: FAILED — collection failed \(pup logs aggregate: Error: HTTP 403 Forbidden\); nothing filed, state kept/);
  assert.deepEqual(prompts(out), [`--- investigator ${sigOf(GIZMO)} ---`]);
  assert.equal(value(out, 'SOURCE_DIR'), t.dirs[GADGETS]);
  verdict(t, 'r1', GIZMO, { actionable: false, reason: 'noise' });
  assert.match(t.run(['finish']), /acme\/gadgets: state saved to #9/);
  assert.ok(fs.existsSync(path.join(t.fx, 'gadgets', 'patch-9.json')));
  assert.ok(!fs.existsSync(path.join(t.fx, 'widgets', 'patch-3.json')), 'the failed repo keeps its state');
});

test('plan: every repo failing is FAILED, and nothing new is NO_WORK', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW] }, { fail: [buildLogQuery(['orders-api'], 'prod', 'status:error')] });
  assert.match(steps(t, '--live', config()), /^FAILED — 1 repo\(s\) failed, 0 had nothing to file/);
  t.datadog({ [WIDGETS]: [OPEN, TINY] });
  const out = steps(t, '--live', config());
  assert.match(out, /^NO_WORK — 1 repo\(s\) had nothing to file/);
  assert.match(out, /acme\/widgets: buckets=2 kept=1 already-open=1 candidates=0/);
});

test('plan: a bucket whose sample could not be read is skipped, not signed from nothing', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW, BACK] }, { fail: [bucketQ(NEW)] });
  assert.deepEqual(prompts(steps(t, '--live', config())), [`--- investigator ${sigOf(BACK)} ---`]);
  verdict(t, 'r0', BACK, { actionable: false, reason: 'noise' });
  const out = t.run(['finish']);
  assert.match(out, /no sample for orders-api Acme\.NewError \(×9\), so no signature; skipped this run/);
});

test('collect: a nested stackPath reads the stack from inside its parent attribute', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW] }, { stackAt: (s) => ({ error: { stack: s } }) });
  const out = steps(t, '--live', config({ errorFacet: '@error.kind', stackPath: 'attributes.attributes.error.stack' }));
  assert.deepEqual(prompts(out), [`--- investigator ${sigOf(NEW)} ---`], 'same signature as the flat stack');
  const cand = JSON.parse(fs.readFileSync(path.join(t.dir, `cand-r0-${sigOf(NEW)}.json`), 'utf8'));
  assert.equal(cand.confidence, 'app-frame');
});

test('config: top-level keys are defaults, a repo\'s own keys win', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [NEW, OPEN, HELD, BACK, TINY] });
  const out = steps(t, '--live', JSON.stringify({ appNamespace: NS, count: 2, repos: [{ repo: WIDGETS, count: 7 }] }));
  assert.match(out, /buckets=5 kept=3 /);
});

test('prepare: a bad CONFIG, an unattached repo and an unreadable issue list', () => {
  const t = setup();
  assert.match(t.run(['prepare', '--live', '{}']), /^SKIP — CONFIG needs a non-empty "repos" array/);
  t.datadog({ [WIDGETS]: [] });
  const out = t.run(['prepare', '--live', config({}, [WIDGETS, 'acme/missing'])]);
  assert.match(out, /^PROCEED 1 repo\(s\) live\n {2}acme\/missing: skipped — not attached to the routine/);
  fs.writeFileSync(path.join(t.fx, 'widgets', 'issues-fail'), '');
  assert.match(t.run(['prepare', '--live', config()]), /^SKIP — no repo is reachable: acme\/widgets: skipped — could not list its datadog-logs issues/);
});

const DAY = 24 * 60 * 60 * 1000;
const withState = (number) => config({ stateIssues: { [WIDGETS]: number } });
const stateIssue = (t, number, body) => fs.writeFileSync(path.join(t.fx, 'widgets', `issue-${number}.json`), JSON.stringify({ number, state: 'closed', body }));
const stateBody = (tick) => `x\n<!-- fu-log-sweep-state: {"last_successful_tick":${tick}} -->`;
const span = (t) => {
  const a = t.pupCalls()[0];
  return Date.parse(a[a.indexOf('--to') + 1]) - Date.parse(a[a.indexOf('--from') + 1]);
};
const sweepNothing = (t, cfg) => { t.datadog({ [WIDGETS]: [OPEN] }); return steps(t, '--live', cfg); };

test('state: the window starts at the last completed sweep the configured state issue records', () => {
  const t = setup();
  const tick = Date.now() - 3 * DAY;
  stateIssue(t, 60, stateBody(tick));
  const out = sweepNothing(t, withState(60));
  const a = t.pupCalls()[0];
  assert.equal(a[a.indexOf('--from') + 1], new Date(tick).toISOString());
  assert.match(out, /since the sweep recorded in #60/);
  assert.match(out, /state saved to #60/);
  for (const call of t.ghLog().trim().split('\n')) assert.match(call, /^api repos\/acme\/widgets\//, 'every call is repo-scoped');
});

test('state: with no stateIssues entry, a live run creates one, closed, and says to configure it', () => {
  const t = setup();
  const out = sweepNothing(t, config());
  assert.equal(span(t), DAY);
  assert.match(out, /no stateIssues entry, so the last 24h/);
  assert.match(out, /state saved to new issue #77 — add "acme\/widgets": 77 to CONFIG\.stateIssues/);
  const created = JSON.parse(t.read('widgets/state-created.json'));
  assert.equal(created.labels, undefined, 'no label, so the dedup index never sees it');
  assert.match(t.ghLog(), /^api repos\/acme\/widgets\/issues\/77 --method PATCH -f state=closed$/m);
});

test('state: a live finish updates the configured state issue in place', () => {
  const t = setup();
  stateIssue(t, 60, stateBody(Date.now() - DAY));
  t.datadog({ [WIDGETS]: [NEW] });
  steps(t, '--live', withState(60));
  verdict(t, 'r0', NEW, { actionable: false, reason: 'noise' });
  assert.match(t.run(['finish']), /state saved to #60/);
  assert.match(t.read('widgets/patch-60.json'), /fu-log-sweep-state/);
  assert.ok(!fs.existsSync(path.join(t.fx, 'widgets', 'state-created.json')), 'no second state issue');
});

test('state: a configured issue with no state marker is never overwritten', () => {
  const t = setup();
  stateIssue(t, 61, 'an unrelated issue, from a mistyped number');
  const out = sweepNothing(t, withState(61));
  assert.equal(span(t), DAY);
  assert.match(out, /state issue unreadable \(#61 holds no state marker\)/);
  assert.match(out, /state not saved: the state issue was unreadable/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});

test('state: a stateIssues entry that is not an issue number reads nothing and writes nothing', () => {
  const t = setup();
  const out = sweepNothing(t, withState('60'));
  assert.equal(span(t), DAY);
  assert.match(out, /stateIssues entry must be an issue number, not "60"/);
  assert.doesNotMatch(t.ghLog(), /issues\/60|--method/);
});

test('state: an unreadable state issue falls back to 24h and is never overwritten', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [OPEN] });
  t.run(['prepare', '--live', withState(60)], { GH_FAIL_STATE: '1' });
  t.run(['collect']);
  assert.equal(span(t), DAY);
  assert.match(t.run(['plan']), /state not saved: the state issue was unreadable/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});

test('state: observe saves nothing', () => {
  const t = setup();
  t.datadog({ [WIDGETS]: [OPEN] });
  assert.doesNotMatch(steps(t, '--observe', config()), /state saved/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});
