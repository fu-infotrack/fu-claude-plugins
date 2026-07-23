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
