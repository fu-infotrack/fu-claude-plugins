// alert-triage-lib.mjs (pure) and alert-triage.mjs (the CLI) — hermetic: a
// throwaway $HOME with fu-tools config, a fake clone under repo_root, `pup` and
// `gh` stubs on PATH serving fixtures, and a local HTTP server standing in for
// the Teams webhook.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSignature, buildMarker } from './log-sweep-lib.mjs';
import {
  parseAlertMessage, actionFor, logsQueryFromMonitor, alertLogsQuery, facetPath, signEvents,
  classifyErrors, nearbyAlerts, validateVerdict, teamsReplyPayload, triggerFor, pushLine,
} from './alert-triage-lib.mjs';

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), 'alert-triage.mjs');
const T0 = Date.parse('2026-11-09T18:38:26.518Z');

// A Graph channel message shaped like the Datadog → Teams integration's.
function alertMsg({ id = '100', state = 'Triggered', title = 'Widgets high error count', monitorId = 42, fromMs = T0 - 16 * 60000, toMs = T0 + 4 * 60000, createdMs = T0 } = {}) {
  const card = {
    type: 'AdaptiveCard',
    body: [{ type: 'TextBlock', text: `[${state}] ${title}` }],
    actions: [
      { type: 'Action.OpenUrl', title: 'View in Datadog', url: `https://ap2.datadoghq.com/monitors/${monitorId}?from_ts=${fromMs}&to_ts=${toMs}&event_id=777&link_source=monitor_notif` },
      { type: 'Action.ShowCard', card: { type: 'AdaptiveCard', actions: [{ type: 'Action.Submit', data: { action: 'core.MUTE_MONITOR' } }] } },
    ],
  };
  return {
    id, summary: `[${state}] ${title}`, createdDateTime: new Date(createdMs).toISOString(),
    channelIdentity: { teamId: 'team-1', channelId: 'chan-1' }, webUrl: `https://teams/${id}`,
    attachments: [{ contentType: 'application/vnd.microsoft.card.adaptive', content: JSON.stringify(card) }],
  };
}

const STACK = 'Acme.Boom: no\n   at Acme.Orders.Place() in /app/Orders.cs:line 9\n   at System.Threading.Tasks.Task.Run()';
const exEvent = (ts, version = 'v2') => ({ attributes: { service: 'orders-api', timestamp: ts, message: 'Boom happened', tags: [`version:${version}`, 'env:prod'], attributes: { error: { kind: 'Acme.Boom', stack: STACK } } } });
const plainEvent = (ts, ms) => ({ attributes: { service: 'orders-api', timestamp: ts, message: `Failed executing DbCommand (${ms}ms)`, tags: ['version:v2'], attributes: { properties: { EventId: { Name: 'Microsoft.EntityFrameworkCore.Database.Command.CommandError' }, SourceContext: 'Microsoft.EntityFrameworkCore.Database.Command' } } } });
const SHAPE = { errorFacet: '@error.kind', stackPath: 'attributes.attributes.error.stack', messagePath: 'attributes.message', appNamespace: ['Acme'], versionTag: 'version' };

// ---- lib ---------------------------------------------------------------------

test('parseAlertMessage reads state, title, monitor and window from the card link', () => {
  const r = parseAlertMessage(alertMsg());
  assert.equal(r.ok, true);
  assert.deepEqual(
    { state: r.alert.state, title: r.alert.title, monitorId: r.alert.monitorId, fromMs: r.alert.fromMs, toMs: r.alert.toMs, eventId: r.alert.eventId, site: r.alert.site, teamId: r.alert.teamId, createdMs: r.alert.createdMs },
    { state: 'Triggered', title: 'Widgets high error count', monitorId: 42, fromMs: T0 - 960000, toMs: T0 + 240000, eventId: '777', site: 'https://ap2.datadoghq.com', teamId: 'team-1', createdMs: T0 },
  );
  assert.equal(parseAlertMessage(alertMsg({ state: 'Re-Triggered' })).alert.state, 'Re-Triggered');
  assert.equal(parseAlertMessage(alertMsg({ state: 'No Data' })).alert.state, 'No Data');
});

test('parseAlertMessage rejects what is not a monitor alert', () => {
  assert.match(parseAlertMessage({ id: '1', summary: 'hello' }).error, /no \[state\]/);
  const noLink = alertMsg();
  noLink.attachments = [];
  assert.match(parseAlertMessage(noLink).error, /no Datadog monitor link/);
  assert.match(parseAlertMessage(null).error, /not a JSON object/);
});

test('actionFor routes each state', () => {
  assert.deepEqual(['Triggered', 'Re-Triggered', 'Recovered', 'Warn', 'No Data'].map(actionFor), ['triage', 'triage', 'recover', 'archive', 'archive']);
});

test('logsQueryFromMonitor unescapes the inner query; other monitor types give null', () => {
  const q = 'logs("env:prod service:a* status:error -(\\"Company not found\\" OR x)").index("*").rollup("count").last("10m") > 0';
  assert.equal(logsQueryFromMonitor(q), 'env:prod service:a* status:error -("Company not found" OR x)');
  assert.equal(logsQueryFromMonitor('avg(last_5m):avg:trace.http.request.errors{service:a} > 5'), null);
});

test('alertLogsQuery falls back to the monitor service tags, then to nothing', () => {
  assert.deepEqual(alertLogsQuery({ query: 'avg(last_5m):x > 1', tags: ['service:a', 'service:b', 'env:prod'] }), { query: 'service:(a OR b) env:prod status:error', source: 'service-tags' });
  assert.equal(alertLogsQuery({ query: 'avg(last_5m):x > 1', tags: [] }), null);
  assert.equal(alertLogsQuery({ query: 'logs("a").index("*") > 0' }).source, 'monitor');
});

test('signEvents signs an exception exactly as /log-sweep does', () => {
  const [e] = signEvents([exEvent('2026-11-09T18:30:00Z'), exEvent('2026-11-09T18:31:00Z', 'v1')], SHAPE);
  const want = buildSignature('Acme.Boom', 'orders-api', STACK, 'Boom happened', ['Acme']);
  assert.equal(e.sig, want.sig);
  assert.equal(e.confidence, 'app-frame');
  assert.equal(e.count, 2);
  assert.equal(e.hasExceptionType, true);
  assert.deepEqual(e.versions.sort((a, b) => a.version.localeCompare(b.version)), [{ version: 'v1', count: 1 }, { version: 'v2', count: 1 }]);
  assert.deepEqual([e.firstSeen, e.lastSeen], ['2026-11-09T18:30:00Z', '2026-11-09T18:31:00Z']);
  assert.equal(facetPath('@Properties.exception.type'), 'attributes.attributes.Properties.exception.type');
});

test('signEvents gives a log with no exception type its logger name, and masks numbers', () => {
  const errs = signEvents([plainEvent('2026-11-09T18:37:14Z', '1,108'), plainEvent('2026-11-09T18:38:00Z', '2,001'), exEvent('2026-11-09T18:30:00Z')], SHAPE);
  assert.equal(errs.length, 2);
  const [db] = errs;
  assert.equal(db.errorKind, 'Microsoft.EntityFrameworkCore.Database.Command.CommandError');
  assert.equal(db.count, 2);
  assert.equal(db.confidence, 'message');
  assert.equal(db.hasExceptionType, false);
});

test('classifyErrors: new, open, regressed on a post-fix build, held on a pre-fix one', () => {
  const sig = (s) => ({ sig: s, versions: [{ version: 'v2', count: 3 }] });
  const issue = (n, s, state, closedAt = null) => ({ number: n, state, closed_at: closedAt, body: `${buildMarker(s)}\n\nbody` });
  const issues = [issue(1, 'aaa', 'open'), issue(2, 'bbb', 'closed', '2026-11-01T00:00:00Z'), issue(3, 'ccc', 'closed', '2026-11-08T00:00:00Z'), { number: 9, pull_request: {}, body: buildMarker('ddd') }];
  const releases = [{ tag: 'v2', publishedAt: '2026-11-05T00:00:00Z' }];
  const got = classifyErrors([sig('aaa'), sig('bbb'), sig('ccc'), sig('ddd')], issues, releases).map((e) => [e.sig, e.classification, e.issue ?? null]);
  assert.deepEqual(got, [['aaa', 'ALREADY_OPEN', 1], ['bbb', 'REGRESSION', 2], ['ccc', 'HELD', 3], ['ddd', 'NEW', null]]);
});

test('nearbyAlerts keeps other monitors that triggered within the window, nearest first', () => {
  const self = { id: 's', monitorId: 1, atMs: T0 };
  const list = [
    { id: 's', monitorId: 1, state: 'Triggered', atMs: T0 },
    { id: 'a', monitorId: 2, title: 'A', state: 'Triggered', atMs: T0 + 10 * 60000 },
    { id: 'b', monitorId: 3, title: 'B', state: 'Re-Triggered', atMs: T0 - 2 * 60000 },
    { id: 'c', monitorId: 4, title: 'C', state: 'Recovered', atMs: T0 },
    { id: 'd', monitorId: 1, title: 'same monitor', state: 'Triggered', atMs: T0 },
    { id: 'e', monitorId: 5, title: 'far', state: 'Triggered', atMs: T0 + 60 * 60000 },
  ];
  assert.deepEqual(nearbyAlerts(self, list, 15 * 60000).map((a) => [a.id, a.minutesFromThis]), [['b', -2], ['a', 10]]);
});

test('validateVerdict: a down verdict must name the authority, a start and whether it is ongoing', () => {
  assert.equal(validateVerdict({ authorityDown: false, summary: 'one db error' }).ok, true);
  assert.match(validateVerdict({ authorityDown: true, summary: 's' }).error, /name the authority/);
  assert.match(validateVerdict({ authorityDown: true, summary: 's', authority: 'X', startIso: 'soon', ongoing: true }).error, /ISO startIso/);
  assert.match(validateVerdict({ authorityDown: true, summary: 's', authority: 'X', startIso: '2026-11-09T18:20:00Z' }).error, /ongoing/);
  assert.match(validateVerdict({ summary: 's' }).error, /authorityDown/);
  assert.match(validateVerdict({ authorityDown: false, summary: 's', actions: [1] }).error, /actions/);
  const ok = validateVerdict({ authorityDown: true, summary: 's', authority: 'X', startIso: '2026-11-09T18:20:00Z', ongoing: true });
  assert.equal(ok.value.authority, 'X');
});

test('teamsReplyPayload carries the ids and escapes HTML; pushLine fits a notification', () => {
  const a = parseAlertMessage(alertMsg()).alert;
  const v = { authority: 'Registry <A>', startIso: '2026-11-09T18:20:00Z', ongoing: true, summary: '5xx & timeouts' };
  const p = teamsReplyPayload(a, v);
  assert.deepEqual([p.teamId, p.channelId, p.messageId], ['team-1', 'chan-1', '100']);
  assert.match(p.text, /Registry &lt;A&gt; looks down/);
  assert.match(p.text, /5xx &amp; timeouts/);
  assert.ok(pushLine(a, v).length <= 200);
  assert.match(pushLine(a, v), /down since 18:20Z, ongoing/);
});

test('triggerFor picks the latest earlier trigger of the same monitor', () => {
  const t = [{ id: 'x', monitorId: 1, atMs: 1 }, { id: 'y', monitorId: 1, atMs: 5 }, { id: 'z', monitorId: 1, atMs: 9 }, { id: 'w', monitorId: 2, atMs: 6 }];
  assert.equal(triggerFor({ monitorId: 1, atMs: 7 }, t).id, 'y');
  assert.equal(triggerFor({ monitorId: 3, atMs: 7 }, t), null);
});

// ---- CLI -----------------------------------------------------------------------

const PUP_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/pup.log"
args="$*"
case "$args" in
  *"monitors get"*) cat "$FX/monitor.json" ;;
  *"logs search"*) cat "$FX/logs.json" ;;
  *) echo "stub: unexpected pup $args" >&2; exit 9 ;;
esac
`;
const GH_STUB = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FX/gh.log"
[ "$1" = api ] || { echo "stub: only gh api" >&2; exit 9; }
case "$2" in
  repos/acme/widgets/issues*) cat "$FX/issues.json" ;;
  repos/acme/widgets/releases*) cat "$FX/releases.json" ;;
  *) echo "stub: unexpected $2" >&2; exit 9 ;;
esac
`;

function setup({ config = {}, monitorTags = ['repo:widgets', 'service:orders-api'] } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'alert-triage-'));
  const home = path.join(root, 'home');
  const fx = path.join(root, 'fx');
  const bin = path.join(root, 'bin');
  const inbox = path.join(root, 'alerts', 'inbox');
  const clone = path.join(home, 'repo', 'Widgets');
  for (const d of [fx, bin, inbox, path.join(home, '.claude', 'fu-tools'), path.join(clone, '.claude')]) fs.mkdirSync(d, { recursive: true });
  execFileSync('git', ['init', '-q', clone]);
  execFileSync('git', ['-C', clone, 'remote', 'add', 'origin', 'git@github.com:acme/widgets.git']);
  fs.writeFileSync(path.join(clone, '.claude', '.fu-tools.json'), JSON.stringify({ 'log-sweep': { errorFacet: '@error.kind', stackPath: 'attributes.attributes.error.stack', appNamespace: ['Acme'] } }));
  fs.writeFileSync(path.join(home, '.claude', 'fu-tools', 'config.json'), JSON.stringify({ 'alert-triage': { inbox, toast: false, ...config } }));
  fs.writeFileSync(path.join(bin, 'pup'), PUP_STUB, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'gh'), GH_STUB, { mode: 0o755 });
  fs.writeFileSync(path.join(fx, 'monitor.json'), JSON.stringify({ id: 42, name: 'Widgets high error count', type: 'log alert', tags: monitorTags, query: 'logs("env:prod service:orders-api status:error").index("*").rollup("count").last("10m") > 0' }));
  fs.writeFileSync(path.join(fx, 'logs.json'), JSON.stringify({ data: [exEvent('2026-11-09T18:30:00Z'), plainEvent('2026-11-09T18:37:14Z', '1,108')] }));
  const openSig = buildSignature('Acme.Boom', 'orders-api', STACK, 'Boom happened', ['Acme']).sig;
  fs.writeFileSync(path.join(fx, 'issues.json'), JSON.stringify([{ number: 7, state: 'open', closed_at: null, body: `${buildMarker(openSig)}\n\nx` }]));
  fs.writeFileSync(path.join(fx, 'releases.json'), JSON.stringify([{ tag_name: 'v2', published_at: '2026-11-01T00:00:00Z' }]));
  const env = { ...process.env, HOME: home, FX: fx, PATH: `${bin}:${process.env.PATH}`, ALERT_TRIAGE_DRY_RUN: '' };
  const run = (cmd, file, extra = {}) => new Promise((resolve) => {
    execFile(process.execPath, [CLI, cmd, file], { env: { ...env, ...extra }, cwd: home, encoding: 'utf8' }, (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout: stdout.trim(), stderr }));
  });
  const put = (msg) => { const f = path.join(inbox, `${msg.id}.json`); fs.writeFileSync(f, JSON.stringify(msg)); return f; };
  const processed = path.join(root, 'alerts', 'processed');
  return { root, fx, inbox, processed, clone, run, put, openSig };
}

const recentMs = () => Date.now() - 5 * 60000;

test('handle archives Warn and No Data without reading Datadog', async () => {
  const s = setup();
  for (const [id, state] of [['1', 'Warn'], ['2', 'No Data']]) {
    const f = s.put(alertMsg({ id, state, createdMs: recentMs() }));
    assert.equal((await s.run('handle', f)).stdout, `ARCHIVED ${id} ${state}`);
    assert.ok(fs.existsSync(path.join(s.processed, `${id}.json`)));
    assert.ok(!fs.existsSync(f));
  }
  assert.ok(!fs.existsSync(path.join(s.fx, 'pup.log')));
});

test('handle archives monitors out of scope, stale alerts and unparseable files', async () => {
  const s = setup({ config: { monitors: [99] } });
  const f = s.put(alertMsg({ id: '1', createdMs: recentMs() }));
  assert.equal((await s.run('handle', f)).stdout, 'ARCHIVED 1 monitor 42 not in scope');

  const t = setup();
  const old = t.put(alertMsg({ id: '2', createdMs: Date.now() - 48 * 3600000 }));
  assert.equal((await t.run('handle', old)).stdout, 'ARCHIVED 2 stale');
  assert.match(fs.readFileSync(path.join(t.processed, '2.md'), 'utf8'), /Not triaged/);
  const junk = t.put({ id: '3', summary: 'hello' });
  assert.match((await t.run('handle', junk)).stdout, /^ARCHIVED 3 unparseable/);
});

test('handle writes facts for a trigger: signatures, dedup, repo shape, nearby alerts', async () => {
  const s = setup();
  s.put(alertMsg({ id: '50', monitorId: 77, title: 'Other team errors', createdMs: recentMs() + 60000 }));
  const f = s.put(alertMsg({ id: '51', createdMs: recentMs() }));
  const r = await s.run('handle', f);
  const [tok, id, factsPath, cwd] = r.stdout.split('\t');
  assert.deepEqual([tok, id, cwd], ['TRIAGE', '51', s.clone]);
  assert.ok(fs.existsSync(f), 'stays in the inbox until finish');
  const facts = JSON.parse(fs.readFileSync(factsPath, 'utf8'));
  assert.equal(facts.mode, 'live');
  assert.equal(facts.repo.github, 'acme/widgets');
  assert.equal(facts.logsQuery, 'env:prod service:orders-api status:error');
  assert.deepEqual(facts.errors.map((e) => [e.classification, e.issue ?? null]).sort(), [['ALREADY_OPEN', 7], ['NEW', null]]);
  assert.equal(facts.errors.find((e) => e.issue === 7).sig, s.openSig);
  assert.deepEqual(facts.nearbyAlerts.map((a) => a.id), ['50']);
  const pupLog = fs.readFileSync(path.join(s.fx, 'pup.log'), 'utf8');
  assert.match(pupLog, /monitors get 42/);
  assert.match(pupLog, /logs search --storage indexes --query env:prod service:orders-api status:error --from 2026-11-09T18:22:26\.518Z --to 2026-11-09T18:42:26\.518Z --limit 500/);
  assert.equal(fs.readFileSync(path.join(s.processed, '51.attempts'), 'utf8'), '1');
});

test('handle without a matching clone still triages, with no GitHub dedup', async () => {
  const s = setup({ monitorTags: ['repo:unknown', 'service:orders-api'] });
  const r = await s.run('handle', s.put(alertMsg({ id: '60', createdMs: recentMs() })));
  const facts = JSON.parse(fs.readFileSync(r.stdout.split('\t')[2], 'utf8'));
  assert.equal(facts.repo.github, null);
  assert.ok(facts.errors.every((e) => !e.classification));
  assert.ok(!fs.existsSync(path.join(s.fx, 'gh.log')));
});

test('finish retries a missing verdict, then gives up and archives', async () => {
  const s = setup();
  const f = s.put(alertMsg({ id: '70', createdMs: recentMs() }));
  await s.run('handle', f);
  assert.match((await s.run('finish', f)).stdout, /^RETRY 70 verdict: authorityDown must be true or false \(attempt 1\/3\)/);
  await s.run('handle', f);
  await s.run('handle', f);
  assert.match((await s.run('finish', f)).stdout, /^FAILED 70 .*archived after 3 attempts/);
  assert.ok(fs.existsSync(path.join(s.processed, '70.json')));
  assert.match(fs.readFileSync(path.join(s.processed, '70.md'), 'utf8'), /Triage failed/);
});

test('finish on a quiet verdict archives and sends nothing', async () => {
  const s = setup({ config: { teams_webhook: 'http://127.0.0.1:1/never' } });
  const f = s.put(alertMsg({ id: '80', createdMs: recentMs() }));
  await s.run('handle', f);
  fs.writeFileSync(path.join(s.processed, '80.verdict.json'), JSON.stringify({ authorityDown: false, summary: 'one db error' }));
  fs.writeFileSync(path.join(s.processed, '80.md'), 'note');
  assert.equal((await s.run('finish', f)).stdout, 'DONE 80 no outage');
  assert.ok(fs.existsSync(path.join(s.processed, '80.json')));
  assert.ok(!fs.existsSync(path.join(s.processed, '80.attempts')));
});

test('finish on an Authority-down verdict replies on the Teams message', async () => {
  const got = [];
  const server = http.createServer((req, res) => { let b = ''; req.on('data', (c) => { b += c; }); req.on('end', () => { got.push(JSON.parse(b)); res.writeHead(202); res.end(); }); });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    const s = setup({ config: { teams_webhook: `http://127.0.0.1:${server.address().port}/hook` } });
    const f = s.put(alertMsg({ id: '90', createdMs: recentMs() }));
    await s.run('handle', f);
    fs.writeFileSync(path.join(s.processed, '90.verdict.json'), JSON.stringify({ authorityDown: true, authority: 'Registry', startIso: '2026-11-09T18:20:00Z', ongoing: true, summary: '5xx from registry' }));
    fs.writeFileSync(path.join(s.processed, '90.md'), 'note');
    const r = await s.run('finish', f);
    assert.match(r.stdout, /^DONE 90 AUTHORITY DOWN: Registry since 2026-11-09T18:20:00Z \(ongoing\) \[teams reply http 202\]/);
    assert.equal(got.length, 1);
    assert.deepEqual([got[0].teamId, got[0].channelId, got[0].messageId], ['team-1', 'chan-1', '90']);
    assert.match(fs.readFileSync(path.join(s.processed, '90.md'), 'utf8'), /Notified: teams reply http 202/);
  } finally { server.close(); }
});

test('a Recovered alert is noted on the latest trigger of its monitor', async () => {
  const s = setup();
  const f = s.put(alertMsg({ id: '95', createdMs: recentMs() }));
  await s.run('handle', f);
  fs.writeFileSync(path.join(s.processed, '95.verdict.json'), JSON.stringify({ authorityDown: false, summary: 's' }));
  fs.writeFileSync(path.join(s.processed, '95.md'), 'note\n');
  await s.run('finish', f);
  const rec = s.put(alertMsg({ id: '96', state: 'Recovered', createdMs: recentMs() + 120000 }));
  assert.equal((await s.run('handle', rec)).stdout, 'RECOVERED 96 95');
  assert.match(fs.readFileSync(path.join(s.processed, '95.md'), 'utf8'), /\*\*Recovered\*\* at .* \(message 96\)/);
});

test('dry run moves nothing and sends nothing', async () => {
  const s = setup();
  const f = s.put(alertMsg({ id: '97', state: 'Warn', createdMs: recentMs() }));
  assert.equal((await s.run('handle', f, { ALERT_TRIAGE_DRY_RUN: '1' })).stdout, 'ARCHIVED 97 Warn');
  assert.ok(fs.existsSync(f));
  const t = s.put(alertMsg({ id: '98', createdMs: recentMs() }));
  const r = await s.run('handle', t, { ALERT_TRIAGE_DRY_RUN: '1' });
  assert.equal(JSON.parse(fs.readFileSync(r.stdout.split('\t')[2], 'utf8')).mode, 'observe');
});
