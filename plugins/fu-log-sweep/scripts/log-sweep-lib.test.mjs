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
