import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  STALE_MS, allBadge, formatTime, isLive, renderSvg, repoBadge,
} from '../src/badge-lib.mjs';

const MIN = 60 * 1000;
// 2026-09-30 14:05 in Sydney (AEST, UTC+10 — before the October DST switch).
const NOW = Date.UTC(2026, 8, 30, 4, 5);

test('staleness is a fixed 15 minutes, inclusive', () => {
  assert.equal(STALE_MS, 15 * MIN);
  assert.equal(isLive(NOW - 15 * MIN, NOW), true);
  assert.equal(isLive(NOW - 15 * MIN - 1, NOW), false);
  assert.equal(isLive(undefined, NOW), false);
  assert.equal(isLive(null, NOW), false);
});

test('times render in Sydney, dated only when not today', () => {
  assert.equal(formatTime(NOW, NOW), '14:05');
  assert.equal(formatTime(NOW - 24 * 60 * MIN, NOW), '29 Sep 14:05');
  // Sydney midnight rollover, not UTC's: 23:59 UTC on the 29th is 09:59 on the 30th.
  assert.equal(formatTime(Date.UTC(2026, 8, 29, 23, 59), NOW), '09:59');
});

test('Sydney daylight saving is applied', () => {
  const summer = Date.UTC(2026, 11, 1, 3, 5); // AEDT, UTC+11
  assert.equal(formatTime(summer, summer), '14:05');
});

test('repo badge: up, down, never pinged', () => {
  assert.deepEqual(repoBadge(NOW - 5 * MIN, NOW), { state: 'up', text: '14:00' });
  assert.deepEqual(repoBadge(NOW - 45 * MIN, NOW), { state: 'down', text: '13:20' });
  assert.deepEqual(repoBadge(undefined, NOW), { state: 'none', text: 'no bot' });
});

test('all-bots badge: one row per live repo, sorted, with its ping time', () => {
  const rows = [
    { repo: 'Zeta', last_ping: NOW - MIN },
    { repo: 'Dead', last_ping: NOW - 60 * MIN },
    { repo: 'Alpha', last_ping: NOW - 2 * MIN },
  ];
  assert.deepEqual(allBadge(rows, NOW), [
    { state: 'up', text: 'Alpha', detail: '14:03' },
    { state: 'up', text: 'Zeta', detail: '14:04' },
  ]);
});

test('all-bots badge says so when nothing is live', () => {
  const none = [{ state: 'none', text: 'no bot active' }];
  assert.deepEqual(allBadge([], NOW), none);
  assert.deepEqual(allBadge([{ repo: 'Dead', last_ping: NOW - 60 * MIN }], NOW), none);
});

test('svg: dot colour carries the state, text is escaped', () => {
  assert.match(renderSvg([{ state: 'up', text: '14:05' }]), /fill="#2ea043"/);
  assert.match(renderSvg([{ state: 'down', text: '13:20' }]), /fill="#cf222e"/);
  assert.match(renderSvg([{ state: 'none', text: 'no bot' }]), /fill="#8c959f"/);
  const out = renderSvg([{ state: 'up', text: 'a<b&c', detail: '<x>' }]);
  assert.ok(!out.includes('a<b&c'));
  assert.match(out, /a&#60;b&#38;c/);
  assert.match(out, /&#60;x&#62;/);
});

test('svg: a single row is one 20px badge, sized to its text', () => {
  const out = renderSvg([{ state: 'up', text: '14:05' }]);
  assert.match(out, /^<svg [^>]*width="81" height="20"/); // 38 + 5*7 + 8
  assert.equal(out.match(/<circle /g).length, 1);
});

test('svg: rows stack vertically, times aligned in one column', () => {
  const out = renderSvg([
    { state: 'up', text: 'Alpha', detail: '14:03' },
    { state: 'up', text: 'LongerName', detail: '29 Sep 14:04' },
  ]);
  // Names end at 38 + 10*7 = 108; times start at 118; widest time is 12*7 = 84.
  assert.match(out, /^<svg [^>]*width="210" height="40"/);
  assert.match(out, /<circle cx="10" cy="10" /);
  assert.match(out, /<circle cx="10" cy="30" /);
  assert.match(out, /<text x="118" y="14">14:03</);
  assert.match(out, /<text x="118" y="34">29 Sep 14:04</);
  assert.match(out, /aria-label="review bot up: Alpha 14:03; review bot up: LongerName 29 Sep 14:04"/);
});
