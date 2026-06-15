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
