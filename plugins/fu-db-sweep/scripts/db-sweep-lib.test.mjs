// The pure rules, against real prod numbers from the 2026-10-27 hand analysis of
// compliance_mono (auawspgsql002l-instance-3) — the acceptance fixtures.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  windows, thresholdsFor, parseCollectorOutput, evaluate, fingerprint, indexIssues, classify,
  composeIssueBody, parseMarker, gateDecision, validateVerdict, parseConfig, rankFindings,
  parseSweepState, buildStateBody, DEFAULT_THRESHOLDS,
} from './db-sweep-lib.mjs';

const NOW = Date.parse('2026-10-27T00:00:00Z');
const SPANS = windows(null, NOW);
const PAIR = { repo: 'infotrackglobal/infotrack.compliance.mono', db: 'compliance_mono' };
const PROD = 'auawspgsql002l-instance-3.cndv4gb0960u.ap-southeast-2.rds.amazonaws.com';
const T = thresholdsFor();

// calls per week, avg ms, buffer pages per call
const stats = (calls, avg, bpc = 10) => ({ timeNs: calls * avg * 1e6, calls, blksHit: calls * bpc, blksRead: 0 });
const q = (sig, win, base, drift = base) => ({ instance: PROD, querySignature: sig, window: win, baseline: base, drift });

export const PROD_FIXTURE = {
  db: 'compliance_mono',
  instances: [PROD],
  queries: [
    // Risk MatchesWithLatestMonitoringEvents* — EF ROW_NUMBER over all of risk.monitoring_event.
    q('c985631ee7416fa1', stats(245, 104, 75373), stats(84, 107.7, 75000)),
    q('9b67ccf583e62815', stats(2058, 46.3, 36020), stats(602, 58, 35500)),
    // Inbox cleanup deletes: 1–3 ms now, slower last week — an improvement, never a finding.
    q('e63e103d9e6f08d5', stats(9821, 3.33, 1373), stats(5124, 52.25, 1400)),
    q('acf8a9c4b87a929', stats(10437, 1.05, 813), stats(5432, 40.62, 800)),
    // Hot point lookups: tons of calls, sub-millisecond.
    q('93176a6b4cba4f81', stats(1548792, 0.12, 9), stats(954030, 0.17, 9)),
    q('8d9106e8926239f9', stats(103117, 0.83, 23), stats(63084, 0.41, 23)),
  ],
  // The text_resource blocking incident (2026-10-19 → 10-22) on the shared instance.
  instanceStats: [{
    instance: PROD, maxBlocked: 21.66, maxConnPct: 0.24, deadlocks: 1, maxIdleInTxnSeconds: 232,
    timeNsByDb: { text_resource: 6.9e15, compliance_mono: 0.39e15, _other: 0.1e15 },
  }],
  tables: [],
};

test('windows: 7 days by default, a missed week widens it, 28 days at most', () => {
  assert.equal(SPANS.window.from, '2026-10-20T00:00:00.000Z');
  assert.equal(SPANS.baseline.from, '2026-10-13T00:00:00.000Z');
  assert.equal(SPANS.drift.from, '2026-09-22T00:00:00.000Z');
  assert.equal(windows(NOW - 2 * 7 * 864e5, NOW).window.from, '2026-10-13T00:00:00.000Z');
  assert.equal(windows(NOW - 2 * 7 * 864e5, NOW).baseline.from, '2026-09-29T00:00:00.000Z');
  assert.equal(windows(NOW - 90 * 864e5, NOW).window.from, '2026-09-29T00:00:00.000Z');
  assert.equal(windows(NOW - 864e5, NOW).window.from, '2026-10-20T00:00:00.000Z');
});

test('acceptance: the prod week files exactly the monitoring_event scan, as med', () => {
  const data = parseCollectorOutput(PROD_FIXTURE, PAIR);
  assert.ok(data.ok, data.error);
  const { findings, notes } = evaluate(PAIR, data.value, SPANS, T);
  assert.deepEqual(findings.map((f) => [f.querySignature, f.rule, f.severity]).sort(), [
    ['9b67ccf583e62815', 'heavy', 'med'],
    ['c985631ee7416fa1', 'heavy', 'med'],
  ]);
  assert.equal(findings.find((f) => f.querySignature === 'c985631ee7416fa1').measure.value, 75373);
  // text_resource's incident is a summary line, never an issue.
  assert.equal(notes.length, 1);
  assert.match(notes[0], /neighbour pressure .* busiest database text_resource/);
});

test('acceptance: the inbox cleanup at 1–3 ms is not flagged even though last week was slower', () => {
  const { findings } = evaluate(PAIR, PROD_FIXTURE, SPANS, T);
  assert.ok(!findings.some((f) => ['e63e103d9e6f08d5', 'acf8a9c4b87a929'].includes(f.querySignature)));
});

// Live collector numbers for the week to 2026-10-27: the inbox cleanup averaged
// 54 ms (20 ms the week before) while text_resource was blocking the instance.
test('acceptance: a latency regression during neighbour pressure is a note, not an issue', () => {
  const live = { ...PROD_FIXTURE, queries: [
    { instance: PROD, querySignature: 'e63e103d9e6f08d5',
      window: { timeNs: 267688793519, calls: 4980, blksHit: 7232962, blksRead: 0 },
      baseline: { timeNs: 38583882435, calls: 1880, blksHit: 2909457, blksRead: 0 },
      drift: { timeNs: 38938954369, calls: 2143, blksHit: 3353160, blksRead: 0 } },
    { instance: PROD, querySignature: 'c985631ee7416fa1',
      window: { timeNs: 9015870722, calls: 84, blksHit: 6459074, blksRead: 0 },
      baseline: { timeNs: 6116553685, calls: 51, blksHit: 3484412, blksRead: 6426 },
      drift: { timeNs: 24171476116, calls: 231, blksHit: 15899869, blksRead: 6426 } },
  ] };
  const { findings, notes } = evaluate(PAIR, live, SPANS, T);
  assert.deepEqual(findings.map((f) => [f.querySignature, f.rule]), [['c985631ee7416fa1', 'heavy']]);
  assert.ok(notes.some((n) => /on e63e103d9e6f08d5 not filed: .* during neighbour pressure/.test(n)));
  // Without the neighbour, the same numbers are a real regression.
  const quiet = { ...live, instanceStats: [] };
  assert.ok(evaluate(PAIR, quiet, SPANS, T).findings.some((f) => f.querySignature === 'e63e103d9e6f08d5' && f.rule === 'regression'));
});

test('regression: 2× is med, 5× at >100/day is high, under the ms floor is ignored', () => {
  // A busy filler query keeps the probe under the heavy rule's share-of-time bar.
  const filler = q('filler', stats(1e6, 1), stats(1e6, 1));
  const run = (win, base) => evaluate(PAIR, { ...PROD_FIXTURE, instanceStats: [], queries: [q('s', win, base), filler] }, SPANS, T).findings;
  assert.equal(run(stats(1400, 20), stats(1400, 8))[0].severity, 'med');
  assert.equal(run(stats(1400, 50), stats(1400, 8))[0].severity, 'high');
  assert.equal(run(stats(140, 50), stats(140, 8))[0].severity, 'med');
  assert.deepEqual(run(stats(1400, 4), stats(1400, 1)), []);
  assert.deepEqual(run(stats(50, 50), stats(50, 8)), []);
});

test('regression: slow drift is caught against the 28-day baseline', () => {
  const data = { ...PROD_FIXTURE, instanceStats: [], queries: [q('s', stats(1400, 30), stats(1400, 25), stats(5600, 10))] };
  const [f] = evaluate(PAIR, data, SPANS, T).findings;
  assert.equal(f.rule, 'regression');
  assert.match(f.why, /3×/);
});

test('step change is low; one query breaching two rules files once, at the worst severity', () => {
  const step = { ...PROD_FIXTURE, instanceStats: [], queries: [q('s', stats(70000, 1), stats(7000, 1))] };
  assert.deepEqual(evaluate(PAIR, step, SPANS, T).findings.map((f) => [f.rule, f.severity]), [['step', 'low']]);
  const both = { ...PROD_FIXTURE, instanceStats: [], queries: [q('s', stats(70000, 60, 30000), stats(7000, 10, 30000))] };
  const [f] = evaluate(PAIR, both, SPANS, T).findings;
  assert.deepEqual([f.rule, f.severity, f.alsoBreached.sort()], ['regression', 'high', ['heavy', 'step']]);
});

test('acceptance: a sampled signature gets only the pages-per-call rule', () => {
  const quiet = { instance: PROD, maxBlocked: 0, maxConnPct: 0.1, deadlocks: 0, maxIdleInTxnSeconds: 5, timeNsByDb: { compliance_mono: 1e15 } };
  const sampled = (sig, win, base) => ({ ...q(sig, win, base), sampled: true });
  const data = parseCollectorOutput({
    db: 'compliance_mono', instances: [PROD], instanceStats: [quiet], tables: [],
    queries: [
      // 2026-10-27: a signature shared with other databases dominated the db-tagged slice
      // (97% of its time) at 17.5k pages/call — share, regression and step must not fire.
      sampled('2afe7f44d8ebc0f3', stats(794, 32, 17572), stats(100, 8, 17000)),
      // A shared signature still reading ~48k pages a call is heavy whatever its counts.
      sampled('c8183c1d0e8a9836', stats(441, 42.5, 47907), stats(400, 41, 47000)),
      q('filler', stats(1e4, 0.1), stats(1e4, 0.1)),
    ],
  }, PAIR);
  assert.ok(data.ok, data.error);
  const { findings } = evaluate(PAIR, data.value, SPANS, T);
  assert.deepEqual(findings.map((f) => [f.querySignature, f.rule, f.measure.name]), [['c8183c1d0e8a9836', 'heavy', 'blocksPerCall']]);
  assert.equal(findings[0].metrics.sampled, true);
  assert.match(findings[0].why, /call counts sampled/);
  assert.match(parseCollectorOutput({ ...PROD_FIXTURE, queries: [{ ...PROD_FIXTURE.queries[0], sampled: 'yes' }] }, PAIR).error, /sampled: not a boolean/);
});

test('pressure: an issue when our database is the busiest on the instance', () => {
  const data = { ...PROD_FIXTURE, queries: [], instanceStats: [{ ...PROD_FIXTURE.instanceStats[0], timeNsByDb: { compliance_mono: 9e15, text_resource: 1e12 } }] };
  const { findings, notes } = evaluate(PAIR, data, SPANS, T);
  assert.deepEqual(findings.map((f) => [f.rule, f.severity, f.fingerprint]), [['pressure', 'high', fingerprint('pressure', PROD, 'compliance_mono')]]);
  assert.deepEqual(notes, []);
});

test('hygiene: dead tuples past the floor and above live rows', () => {
  const data = { ...PROD_FIXTURE, queries: [], instanceStats: [], tables: [
    { instance: PROD, table: 'outbox.inbox_state', deadRows: 140000, liveRows: 0 },
    { instance: PROD, table: 'risk.match', deadRows: 150000, liveRows: 900000 },
  ] };
  assert.deepEqual(evaluate(PAIR, data, SPANS, T).findings.map((f) => [f.table, f.severity]), [['outbox.inbox_state', 'low']]);
});

test('overrides win per key; unknown keys and non-numbers are rejected', () => {
  assert.equal(thresholdsFor({ heavyBlocksPerCall: 80000 }).heavyBlocksPerCall, 80000);
  assert.equal(thresholdsFor({ heavyBlocksPerCall: 80000 }).regressionRatio, DEFAULT_THRESHOLDS.regressionRatio);
  assert.throws(() => thresholdsFor({ heavyBlocks: 1 }), /unknown threshold/);
  assert.throws(() => thresholdsFor({ heavyBlocksPerCall: '1' }), /must be a number/);
  // 9b67 drops under the raised page bar but still owns ~22% of the database's time.
  const quiet = { ...PROD_FIXTURE, instanceStats: [] };
  const { findings } = evaluate(PAIR, quiet, SPANS, thresholdsFor({ heavyBlocksPerCall: 50000 }));
  assert.deepEqual(findings.map((f) => [f.querySignature, f.measure.name]), [
    ['c985631ee7416fa1', 'blocksPerCall'], ['9b67ccf583e62815', 'shareOfDbTime'],
  ]);
});

test('collector output is validated strictly', () => {
  assert.equal(parseCollectorOutput({ ...PROD_FIXTURE, db: 'other' }, PAIR).ok, false);
  assert.match(parseCollectorOutput({ error: 'Datadog 401' }, PAIR).error, /collector reported: Datadog 401/);
  const badQ = { ...PROD_FIXTURE, queries: [{ ...PROD_FIXTURE.queries[0], window: { timeNs: 1, calls: -1, blksHit: 0, blksRead: 0 } }] };
  assert.match(parseCollectorOutput(badQ, PAIR).error, /calls/);
  const strayInstance = { ...PROD_FIXTURE, queries: [{ ...PROD_FIXTURE.queries[0], instance: 'x' }] };
  assert.match(parseCollectorOutput(strayInstance, PAIR).error, /not in instances/);
  assert.deepEqual(parseCollectorOutput({ ...PROD_FIXTURE, tables: undefined }, PAIR).value.tables, []);
});

test('fingerprint is the agreed wire format', () => {
  assert.equal(fingerprint('heavy', PROD, 'compliance_mono', 'c985631ee7416fa1').length, 12);
  assert.notEqual(fingerprint('heavy', PROD, 'compliance_mono', 'a'), fingerprint('regression', PROD, 'compliance_mono', 'a'));
  assert.notEqual(fingerprint('pressure', PROD, 'compliance_mono'), fingerprint('pressure', 'reader-1', 'compliance_mono'));
});

const finding = { fingerprint: 'abc123def456', measure: { name: 'blocksPerCall', value: 75373 } };

test('marker round-trips and a body cannot smuggle a second one', () => {
  const body = composeIssueBody(finding, 'text <!-- dd-dbm: {"fp":"zzz"} --> more');
  assert.equal(body.match(/dd-dbm/g).length, 1);
  assert.deepEqual(parseMarker(body), { fp: 'abc123def456', measure: 'blocksPerCall', value: 75373 });
});

test('classify: new, open, accepted, accepted-but-worse, closed-as-fixed', () => {
  const issue = (number, state, extra = {}) => ({ number, state, body: composeIssueBody(finding, 'x'), closed_at: '2026-10-01T00:00:00Z', labels: [], ...extra });
  assert.equal(classify(undefined, 1, T).kind, 'NEW');
  const idx = (...xs) => indexIssues(xs)[finding.fingerprint];
  assert.deepEqual(classify(idx(issue(1, 'closed'), issue(2, 'open')), 1, T), { kind: 'ALREADY_OPEN', number: 2 });
  assert.equal(classify(idx(issue(3, 'closed', { state_reason: 'not_planned' })), 100000, T).kind, 'ACCEPTED');
  assert.equal(classify(idx(issue(3, 'closed', { labels: [{ name: 'wontfix' }] })), 150746, T).kind, 'REOPEN_ACCEPTED');
  assert.deepEqual(classify(idx(issue(4, 'closed', { state_reason: 'completed' })), 1, T), { kind: 'REGRESSION_CHECK', number: 4, closedAt: '2026-10-01T00:00:00Z' });
  assert.equal(indexIssues([{ ...issue(5, 'open'), pull_request: {} }])[finding.fingerprint], undefined);
});

test('acceptance: a closed issue whose fix is not in the deployed commit is held', () => {
  assert.equal(gateDecision({ deployedSha: '0e789f0a', compareStatus: 'behind' }).reopen, false);
  assert.equal(gateDecision({ deployedSha: '0e789f0a', compareStatus: 'diverged' }).reopen, false);
  assert.equal(gateDecision({ deployedSha: '0e789f0a', compareStatus: 'ahead' }).reopen, true);
  assert.equal(gateDecision({ deployedSha: '0e789f0a', compareStatus: 'identical' }).reopen, true);
  assert.equal(gateDecision({ deployedSha: '0e789f0a', deployedCommitDate: '2026-09-30T00:00:00Z', closedAt: '2026-10-01T00:00:00Z' }).reopen, false);
  assert.equal(gateDecision({ deployedSha: '0e789f0a', deployedCommitDate: '2026-10-02T00:00:00Z', closedAt: '2026-10-01T00:00:00Z' }).reopen, true);
  assert.equal(gateDecision({ deployedSha: null }).reopen, false);
});

test('verdicts: shape per kind, and no @mentions outside code', () => {
  const body = 'A long enough body describing the finding and the code path.';
  assert.ok(validateVerdict({ actionable: true, reason: 'r', title: 't', body }, 'NEW').ok);
  assert.ok(!validateVerdict({ actionable: true, reason: 'r', title: 't' }, 'NEW').ok);
  assert.ok(!validateVerdict({ actionable: true, reason: 'r', title: 't', body }, 'REGRESSION_CHECK').ok);
  assert.ok(validateVerdict({ actionable: true, reason: 'r', title: 't', comment: 'still breaching, see numbers', deployedSha: '0e789f0' }, 'REGRESSION_CHECK').ok);
  assert.match(validateVerdict({ actionable: true, reason: 'r', title: 't', body: `${body} cc @harrison-nguyenng` }, 'NEW').error, /@mentions/);
  assert.ok(validateVerdict({ actionable: true, reason: 'r', title: 't', body: `${body} \`@types/node\`` }, 'NEW').ok);
  assert.ok(validateVerdict({ actionable: false, reason: 'deliberate nightly batch' }, 'NEW').ok);
  assert.ok(!validateVerdict({ actionable: true, reason: 'r', title: 't', body, deployedSha: 'main' }, 'NEW').ok);
});

test('config: pairs are repo+db, one state issue per repo, overrides validated', () => {
  const c = parseConfig('{"stateIssues":{"a/B":7},"pairs":[{"repo":"a/B","db":"compliance_mono","overrides":{"heavyBlocksPerCall":5}},{"repo":"c/d","db":"x"}]}');
  assert.equal(c.pairs[0].thresholds.heavyBlocksPerCall, 5);
  assert.deepEqual(c.stateIssues, { 'a/B': 7 });
  assert.equal(c.ddSite, 'https://ap2.datadoghq.com');
  assert.deepEqual(parseConfig('{"stateIssues":{"A/b":7},"pairs":[{"repo":"a/B","db":"x"}]}').stateIssues, { 'a/B': 7 });
  assert.throws(() => parseConfig('{"pairs":[]}'), /at least one/);
  assert.throws(() => parseConfig('{"pairs":[{"repo":"a/b","db":"x"},{"repo":"A/b","db":"x"}]}'), /spells|repeats/);
  assert.throws(() => parseConfig('{"stateIssues":{"a/b":"7"},"pairs":[{"repo":"a/b","db":"x"}]}'), /issue number/);
  assert.throws(() => parseConfig('{"stateIssues":{"z/z":7},"pairs":[{"repo":"a/b","db":"x"}]}'), /no pair uses/);
  assert.throws(() => parseConfig('{"stateRepo":"a/b","pairs":[{"repo":"a/b","db":"x"}]}'), /replaced by stateIssues/);
  assert.throws(() => parseConfig('{"pairs":[{"repo":"a/b","db":"x; drop"}]}'), /database name/);
});

test('rank: severity first, then total time', () => {
  const r = rankFindings([
    { severity: 'low', metrics: { totalSeconds: 999 } }, { severity: 'med', metrics: { totalSeconds: 1 } },
    { severity: 'high', metrics: { totalSeconds: 0 } }, { severity: 'med', metrics: { totalSeconds: 5 } },
  ]);
  assert.deepEqual(r.map((f) => `${f.severity}${f.metrics.totalSeconds}`), ['high0', 'med5', 'med1', 'low999']);
});

test('state marker round-trips', () => {
  assert.deepEqual(parseSweepState(buildStateBody(NOW)), { last_successful_tick: NOW });
  assert.equal(parseSweepState('no marker'), null);
});
