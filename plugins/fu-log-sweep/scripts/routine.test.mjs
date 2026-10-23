// routine.mjs end to end, hermetic: a throwaway $HOME, a fake target clone, and
// a `gh` stub on PATH that serves REST fixtures, records every call, and
// rejects GraphQL-backed commands and --paginate as a cloud session does.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSignature } from './log-sweep-lib.mjs';

const ROUTINE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'routine.mjs');
const NS = ['Acme'];
const stack = (method) => `Acme.Boom: no\n   at Acme.Orders.${method}() in /app/src/Orders.cs:line 9\n   at System.Threading.Tasks.Task.Run()`;
const bucket = (kind, method, count, versions) => ({
  errorKind: kind, service: 'orders-api', count, versions,
  samples: [{ timestamp: '2026-10-22T08:00:00Z', message: `${kind} failed`, stack: stack(method) }],
});
const sigOf = (b) => buildSignature(b.errorKind, b.service, b.samples[0].stack, b.samples[0].message, NS).sig;

const GH_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/gh.log"
[ "$1" = api ] || { echo "stub: only gh api (GraphQL is 403 here)" >&2; exit 9; }
case "$*" in *--paginate*|*graphql*) echo "stub: rejected" >&2; exit 9 ;; esac
case "$2" in
  'repos/acme/widgets/issues?state=all&labels=datadog-logs&per_page=100&page=1')
    [ -n "$GH_FAIL_ISSUES" ] && { echo "HTTP 500" >&2; exit 1; }; cat "$FX/issues.json" ;;
  'repos/acme/widgets/releases?per_page=30') cat "$FX/releases.json" ;;
  repos/acme/widgets/issues) cat > "$FX/created.json"; echo '{"number":42}' ;;
  repos/acme/widgets/issues/*/comments) cat > "$FX/comment.json"; echo '{}' ;;
  repos/acme/widgets/issues/*) echo '{}' ;;
  *) echo "stub: unexpected $2" >&2; exit 9 ;;
esac
`;

// NEW, ALREADY_OPEN, a REGRESSION held (only on a pre-fix build), a REGRESSION
// reopened (on a post-fix build), and one under the threshold.
const NEW = bucket('Acme.NewError', 'Create', 9, []);
const OPEN = bucket('Acme.OpenError', 'Read', 8, []);
const HELD = bucket('Acme.HeldError', 'Update', 7, [{ version: 'v1', count: 7 }]);
const BACK = bucket('Acme.BackError', 'Delete', 6, [{ version: 'v2', count: 2 }, { version: 'v1', count: 4 }]);
const TINY = bucket('Acme.TinyError', 'List', 1, []);

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'log-sweep-routine-'));
  const fx = path.join(root, 'fx');
  const bin = path.join(root, 'bin');
  const repo = path.join(root, 'widgets');
  for (const d of [fx, bin, repo]) fs.mkdirSync(d);
  fs.writeFileSync(path.join(bin, 'gh'), GH_STUB, { mode: 0o755 });
  execFileSync('git', ['init', '-q', repo]);
  execFileSync('git', ['-C', repo, 'remote', 'add', 'origin', 'https://github.com/acme/widgets.git']);
  fs.writeFileSync(path.join(repo, 'k8_settings.json'), '{"app_name":"orders-api"}');
  const marker = (b) => `<!-- dd-log-sig: ${sigOf(b)} -->`;
  fs.writeFileSync(path.join(fx, 'issues.json'), JSON.stringify([
    { number: 5, state: 'open', body: marker(OPEN) },
    { number: 7, state: 'closed', closed_at: '2026-10-10T00:00:00Z', body: marker(HELD) },
    { number: 8, state: 'closed', closed_at: '2026-10-10T00:00:00Z', body: marker(BACK) },
  ]));
  fs.writeFileSync(path.join(fx, 'releases.json'), JSON.stringify([
    { tag_name: 'v2', published_at: '2026-10-12T00:00:00Z' },
    { tag_name: 'v1', published_at: '2026-10-01T00:00:00Z' },
  ]));
  const env = { ...process.env, HOME: path.join(root, 'home'), PATH: `${bin}:${process.env.PATH}`, FX: fx };
  const run = (args, extra = {}) => {
    const r = spawnSync(process.execPath, [ROUTINE, ...args], { cwd: repo, env: { ...env, ...extra }, encoding: 'utf8' });
    assert.equal(r.stderr, '', 'stderr stays empty');
    return r.stdout;
  };
  const dir = path.join(env.HOME, '.claude', 'log-sweep', 'routine');
  const ghLog = () => fs.readFileSync(path.join(fx, 'gh.log'), 'utf8');
  return { fx, repo, dir, run, ghLog };
}

const CONFIG = JSON.stringify({ appNamespace: NS, count: 2 });
const prompts = (out) => out.split('\n').filter((l) => l.startsWith('--- '));
const value = (out, key) => out.split('\n').find((l) => l.startsWith(`${key}=`))?.slice(key.length + 1);

function throughPlan(t, mode) {
  const out = t.run(['prepare', mode, CONFIG]);
  assert.match(out.split('\n')[0], new RegExp(`^PROCEED collector ${mode.slice(2)} acme/widgets$`));
  assert.deepEqual(prompts(out), ['--- collector ---']);
  assert.equal(value(out, 'QUERY'), 'service:orders-api env:prod status:error');
  assert.equal(value(out, 'STACK_FIELD'), 'Exception');
  assert.equal(value(out, 'THRESHOLD'), '2');
  fs.writeFileSync(value(out, 'OUTPUT_FILE'), JSON.stringify({ buckets: [NEW, OPEN, HELD, BACK, TINY] }));
  return t.run(['plan']);
}

test('plan: NEW and a post-fix REGRESSION proceed; open, held and tiny do not', () => {
  const t = setup();
  const out = throughPlan(t, '--live');
  assert.equal(out.split('\n')[0], 'PROCEED 2 — buckets=5 below-threshold=1 already-open=1 candidates=2');
  assert.deepEqual(prompts(out), [`--- investigator ${sigOf(NEW)} ---`, `--- investigator ${sigOf(BACK)} ---`]);
  const back = JSON.parse(fs.readFileSync(path.join(t.dir, `cand-${sigOf(BACK)}.json`), 'utf8'));
  assert.equal(back.classification, 'REGRESSION');
  assert.equal(back.number, 8);
  assert.equal(back.postFixCount, 2);
  assert.equal(back.frame, 'Acme.Orders.Delete');
  assert.equal(value(out, 'SOURCE_DIR'), t.repo);
});

test('finish (live): creates the NEW issue with our marker, reopens and comments the regression', () => {
  const t = setup();
  throughPlan(t, '--live');
  fs.writeFileSync(path.join(t.dir, `inv-${sigOf(NEW)}.json`), JSON.stringify({ actionable: true, reason: 'app bug', severity: 'high', body: 'drafted <!-- dd-log-sig: 000000000000 -->' }));
  fs.writeFileSync(path.join(t.dir, `inv-${sigOf(BACK)}.json`), JSON.stringify({ actionable: true, reason: 'back', severity: 'med', body: 'b', comment: '**Regressed**' }));
  const out = t.run(['finish']);
  assert.equal(out.split('\n')[0], 'SWEPT acme/widgets — filed=2 dropped=0 failed=0');
  assert.match(out, /#42 created \(high\)/);
  assert.match(out, /#8 reopened \(med\)/);
  assert.match(out, /held .* #7: fix not in prod yet \(still on v1\)/);
  const created = JSON.parse(fs.readFileSync(path.join(t.fx, 'created.json'), 'utf8'));
  assert.equal(created.body, `<!-- dd-log-sig: ${sigOf(NEW)} -->\n\ndrafted`);
  assert.deepEqual(created.labels, ['datadog-logs', 'auto-filed', 'sev:high']);
  assert.equal(JSON.parse(fs.readFileSync(path.join(t.fx, 'comment.json'), 'utf8')).body, '**Regressed**');
  assert.match(t.ghLog(), /^api repos\/acme\/widgets\/issues\/8 --method PATCH -f state=open$/m);
  assert.equal(t.run(['finish']), 'NOTHING_PENDING\n', 'a second finish files nothing');
});

test('finish (observe): touches no GitHub write API', () => {
  const t = setup();
  throughPlan(t, '--observe');
  fs.writeFileSync(path.join(t.dir, `inv-${sigOf(NEW)}.json`), JSON.stringify({ actionable: true, reason: 'app bug', severity: 'low', body: 'b' }));
  fs.writeFileSync(path.join(t.dir, `inv-${sigOf(BACK)}.json`), JSON.stringify({ actionable: false, reason: 'client cancelled' }));
  const out = t.run(['finish']);
  assert.equal(out.split('\n')[0], 'OBSERVED acme/widgets — would-file=1 dropped=1 failed=0');
  assert.match(out, /would create \(low\)/);
  assert.match(out, /dropped .* client cancelled/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});

test('finish: a missing or malformed verdict files nothing for that signature', () => {
  const t = setup();
  throughPlan(t, '--live');
  fs.writeFileSync(path.join(t.dir, `inv-${sigOf(BACK)}.json`), JSON.stringify({ actionable: true, reason: 'r', severity: 'med', body: 'b' }));
  const out = t.run(['finish']);
  assert.equal(out.split('\n')[0], 'SWEPT acme/widgets — filed=0 dropped=0 failed=2');
  assert.match(out, /FAILED .* no verdict file/);
  assert.match(out, /FAILED .* needs a comment/);
  assert.doesNotMatch(t.ghLog(), /--method/);
});

test('plan: a missing or invalid buckets file is FAILED', () => {
  const t = setup();
  t.run(['prepare', '--live', CONFIG]);
  assert.match(t.run(['plan']), /^FAILED — the collector's buckets file is unusable/);
  fs.writeFileSync(path.join(t.dir, 'buckets.json'), JSON.stringify({ buckets: [{ errorKind: 'E' }] }));
  assert.match(t.run(['plan']), /^FAILED — .*bucket 0/);
});

test('plan: nothing new is NO_WORK', () => {
  const t = setup();
  t.run(['prepare', '--live', CONFIG]);
  fs.writeFileSync(path.join(t.dir, 'buckets.json'), JSON.stringify({ buckets: [OPEN, TINY] }));
  assert.match(t.run(['plan']), /^NO_WORK — buckets=2 below-threshold=1 already-open=1 candidates=0/);
});

test('prepare: an unreadable issue list SKIPs, since nothing could be deduped', () => {
  const t = setup();
  assert.match(t.run(['prepare', '--live', CONFIG], { GH_FAIL_ISSUES: '1' }), /^SKIP — could not list acme\/widgets's datadog-logs issues/);
});
