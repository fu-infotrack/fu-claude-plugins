// Pure logic for the DB perf sweep: windows, the finding rules, severity,
// fingerprints, dedup and the reopen gate's decision. No I/O, no clock, no
// network — routine.mjs owns all of that and passes values in.
import { createHash } from 'node:crypto';

const DAY_MS = 24 * 3600 * 1000;
export const WEEK_MS = 7 * DAY_MS;

// ---- Windows ------------------------------------------------------------------
// The window runs from the end of the last completed sweep to now: at least 7
// days, at most 28 (a missed or failed week is swept again, not skipped). The
// baseline is the same length straight before it; the drift baseline is the 28
// days before it.
export function windows(lastTickMs, nowMs) {
  const floor = nowMs - WEEK_MS;
  const cap = nowMs - 4 * WEEK_MS;
  const start = lastTickMs ? Math.max(cap, Math.min(lastTickMs, floor)) : floor;
  const len = nowMs - start;
  const iso = (ms) => new Date(ms).toISOString();
  return {
    window: { from: iso(start), to: iso(nowMs) },
    baseline: { from: iso(start - len), to: iso(start) },
    drift: { from: iso(start - 4 * WEEK_MS), to: iso(start) },
  };
}

export const daysOf = (span) => (Date.parse(span.to) - Date.parse(span.from)) / DAY_MS;

// ---- Thresholds ---------------------------------------------------------------
// Defaults; a pair's `overrides` in the routine CONFIG wins key by key.
export const DEFAULT_THRESHOLDS = Object.freeze({
  heavyMinCallsPerDay: 3,
  heavyBlocksPerCall: 20000,
  heavyShareOfDbTime: 0.2,
  heavyShareMinAvgMs: 10,
  regressionMinCallsPerDay: 15,
  regressionMinBaseCalls: 20,
  regressionRatio: 2,
  regressionHighRatio: 5,
  regressionHighCallsPerDay: 100,
  regressionMinAvgMs: 5,
  stepRatio: 3,
  stepMinCallsPerDay: 150,
  stepMinTotalSeconds: 60,
  pressureBlocked: 5,
  pressureConnPct: 0.8,
  pressureDeadlocks: 5,
  pressureIdleInTxnSeconds: 600,
  hygieneDeadRows: 100000,
  wontfixWorsenRatio: 2,
});

export function thresholdsFor(overrides) {
  const out = { ...DEFAULT_THRESHOLDS };
  for (const [k, v] of Object.entries(overrides || {})) {
    if (!(k in DEFAULT_THRESHOLDS)) throw new Error(`unknown threshold "${k}"`);
    if (typeof v !== 'number' || !Number.isFinite(v)) throw new Error(`threshold "${k}" must be a number`);
    out[k] = v;
  }
  return out;
}

// ---- Collector output -----------------------------------------------------------
// One file per (repo, db) pair. Strict: one malformed entry rejects the file,
// because a finding computed from half the data is worse than none.
const isNum = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;
const STATS = ['timeNs', 'calls', 'blksHit', 'blksRead'];

function checkStats(s, where) {
  if (!s || typeof s !== 'object') throw new Error(`${where}: missing`);
  for (const k of STATS) if (!isNum(s[k])) throw new Error(`${where}.${k}: not a non-negative number`);
}

export function parseCollectorOutput(raw, expect) {
  try {
    if (!raw || typeof raw !== 'object') throw new Error('not an object');
    if (raw.error) return { ok: false, error: `collector reported: ${String(raw.error).slice(0, 300)}` };
    if (raw.db !== expect.db) throw new Error(`db is ${JSON.stringify(raw.db)}, expected ${JSON.stringify(expect.db)}`);
    if (!Array.isArray(raw.instances)) throw new Error('instances: not an array');
    for (const i of raw.instances) if (typeof i !== 'string' || !i) throw new Error('instances: every entry must be a name');
    if (!Array.isArray(raw.queries)) throw new Error('queries: not an array');
    raw.queries.forEach((q, n) => {
      if (!raw.instances.includes(q.instance)) throw new Error(`queries[${n}].instance: not in instances`);
      if (typeof q.querySignature !== 'string' || !q.querySignature) throw new Error(`queries[${n}].querySignature: missing`);
      checkStats(q.window, `queries[${n}].window`);
      checkStats(q.baseline, `queries[${n}].baseline`);
      checkStats(q.drift, `queries[${n}].drift`);
      if (q.sampled !== undefined && typeof q.sampled !== 'boolean') throw new Error(`queries[${n}].sampled: not a boolean`);
    });
    if (!Array.isArray(raw.instanceStats)) throw new Error('instanceStats: not an array');
    raw.instanceStats.forEach((s, n) => {
      if (typeof s.instance !== 'string' || !s.instance) throw new Error(`instanceStats[${n}].instance: missing`);
      for (const k of ['maxBlocked', 'maxConnPct', 'deadlocks', 'maxIdleInTxnSeconds']) {
        if (s[k] !== null && !isNum(s[k])) throw new Error(`instanceStats[${n}].${k}: not a number or null`);
      }
      if (!s.timeNsByDb || typeof s.timeNsByDb !== 'object') throw new Error(`instanceStats[${n}].timeNsByDb: missing`);
      for (const [db, v] of Object.entries(s.timeNsByDb)) if (!isNum(v)) throw new Error(`instanceStats[${n}].timeNsByDb.${db}: not a number`);
    });
    const tables = raw.tables ?? [];
    if (!Array.isArray(tables)) throw new Error('tables: not an array');
    tables.forEach((t, n) => {
      if (typeof t.instance !== 'string' || typeof t.table !== 'string') throw new Error(`tables[${n}]: instance and table required`);
      if (!isNum(t.deadRows) || !isNum(t.liveRows)) throw new Error(`tables[${n}]: deadRows and liveRows must be numbers`);
    });
    return { ok: true, value: { ...raw, tables } };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ---- Rules ----------------------------------------------------------------------
const SEV_RANK = { high: 3, med: 2, low: 1 };
const avgMs = (s) => (s.calls ? s.timeNs / 1e6 / s.calls : 0);
const blocksPerCall = (s) => (s.calls ? (s.blksHit + s.blksRead) / s.calls : 0);
const round = (v, d = 2) => Math.round(v * 10 ** d) / 10 ** d;

// Every finding for one pair. `spans` are the collector's {window, baseline,
// drift} periods; `t` the resolved thresholds. A query that breaches several
// rules yields one finding — the most severe — so one query never files twice
// in a run.
export function evaluate(pair, data, spans, t) {
  const days = daysOf(spans.window);
  const baseDays = daysOf(spans.baseline);
  const findings = [];
  const notes = [];

  const neighbourPressure = new Set();
  // Instance pressure — an issue only when this database is the main load on
  // the instance; a neighbour's pressure is one summary line.
  for (const s of data.instanceStats) {
    const reasons = [];
    if (s.maxBlocked !== null && s.maxBlocked >= t.pressureBlocked) reasons.push(`up to ${round(s.maxBlocked, 1)} blocked sessions`);
    if (s.maxConnPct !== null && s.maxConnPct >= t.pressureConnPct) reasons.push(`connections at ${Math.round(s.maxConnPct * 100)}% of max`);
    if (s.deadlocks !== null && s.deadlocks >= t.pressureDeadlocks) reasons.push(`${s.deadlocks} deadlocks`);
    if (s.maxIdleInTxnSeconds !== null && s.maxIdleInTxnSeconds >= t.pressureIdleInTxnSeconds) reasons.push(`a transaction idle for ${Math.round(s.maxIdleInTxnSeconds)} s`);
    if (!reasons.length) continue;
    const ranked = Object.entries(s.timeNsByDb).filter(([db]) => db !== '_other').sort((a, b) => b[1] - a[1]);
    const top = ranked[0]?.[0] ?? null;
    const ours = s.timeNsByDb[pair.db] || 0;
    const aas = (ns) => round(ns / (days * DAY_MS * 1e6), 3);
    if (top === pair.db) {
      findings.push({
        kind: 'instance', rule: 'pressure', severity: 'high', repo: pair.repo, db: pair.db, instance: s.instance,
        fingerprint: fingerprint('pressure', s.instance, pair.db), measure: { name: 'activeSessions', value: aas(ours) },
        why: `${reasons.join(', ')}; ${pair.db} is the busiest database on the instance (${aas(ours)} active sessions)`,
        metrics: { ...s, activeSessionsByDb: Object.fromEntries(ranked.slice(0, 5).map(([db, ns]) => [db, aas(ns)])) },
        alsoBreached: [],
      });
    } else {
      neighbourPressure.add(s.instance);
      notes.push(`neighbour pressure on ${s.instance}: ${reasons.join(', ')} — busiest database ${top ?? 'unknown'} (${top ? aas(s.timeNsByDb[top]) : '?'} active sessions), ${pair.db} at ${aas(ours)}`);
    }
  }

  const dbTimeByInstance = {};
  for (const q of data.queries) dbTimeByInstance[q.instance] = (dbTimeByInstance[q.instance] || 0) + q.window.timeNs;

  for (const q of data.queries) {
    const w = q.window;
    const perDay = w.calls / days;
    const cur = avgMs(w);
    const metrics = {
      callsPerDay: round(perDay, 1), avgMs: round(cur, 3), baselineAvgMs: round(avgMs(q.baseline), 3),
      driftAvgMs: round(avgMs(q.drift), 3), blocksPerCall: Math.round(blocksPerCall(w)),
      totalSeconds: round(w.timeNs / 1e9, 1), shareOfDbTime: round(dbTimeByInstance[q.instance] ? w.timeNs / dbTimeByInstance[q.instance] : 0, 3),
      baselineCallsPerDay: round(q.baseline.calls / baseDays, 1),
      ...(q.sampled ? { sampled: true } : {}),
    };
    const hits = [];

    // A sampled query (its signature also runs in another database) has only
    // the db-tagged slice of its rows, and that slice swings day to day: its
    // counts, time and even its average are noise. Pages per call is the one
    // number a sample keeps, so it is the only rule it gets.
    if (q.sampled) {
      const bpc = blocksPerCall(w);
      if (bpc >= t.heavyBlocksPerCall && w.calls > 0) {
        findings.push({
          rule: 'heavy', severity: 'med', measure: { name: 'blocksPerCall', value: Math.round(bpc) },
          why: `${Math.round(bpc).toLocaleString('en-US')} buffer pages per call (~${Math.round(bpc * 8 / 1024)} MB), avg ${round(cur, 1)} ms (call counts sampled)`,
          kind: 'query', repo: pair.repo, db: pair.db, instance: q.instance, querySignature: q.querySignature,
          fingerprint: fingerprint('heavy', q.instance, pair.db, q.querySignature), metrics, alsoBreached: [],
        });
      }
      continue;
    }

    // Latency regression against the same-length baseline, or slow drift
    // against the 28 days before the window — whichever is the lower bar.
    const refs = [q.baseline, q.drift].filter((s) => s.calls >= t.regressionMinBaseCalls).map(avgMs).filter((v) => v > 0);
    if (refs.length && perDay >= t.regressionMinCallsPerDay && cur >= t.regressionMinAvgMs) {
      const ref = Math.min(...refs);
      const ratio = cur / ref;
      if (ratio >= t.regressionRatio) {
        const high = ratio >= t.regressionHighRatio && perDay > t.regressionHighCallsPerDay;
        hits.push({ rule: 'regression', severity: high ? 'high' : 'med', measure: { name: 'avgMs', value: round(cur, 3) },
          why: `avg ${round(cur, 1)} ms vs ${round(ref, 1)} ms before (${round(ratio, 1)}×) at ${round(perDay)}/day` });
      }
    }

    // Heavy: reads a lot of buffer pages per call, or owns a big slice of the
    // database's time while not being trivially fast.
    if (perDay >= t.heavyMinCallsPerDay) {
      const bpc = blocksPerCall(w);
      const share = metrics.shareOfDbTime;
      if (bpc >= t.heavyBlocksPerCall) {
        hits.push({ rule: 'heavy', severity: 'med', measure: { name: 'blocksPerCall', value: Math.round(bpc) },
          why: `${Math.round(bpc).toLocaleString('en-US')} buffer pages per call (~${Math.round(bpc * 8 / 1024)} MB) at ${round(perDay)}/day, avg ${round(cur, 1)} ms` });
      } else if (share >= t.heavyShareOfDbTime && cur >= t.heavyShareMinAvgMs) {
        hits.push({ rule: 'heavy', severity: 'med', measure: { name: 'shareOfDbTime', value: share },
          why: `${Math.round(share * 100)}% of the database's query time, avg ${round(cur, 1)} ms at ${round(perDay)}/day` });
      }
    }

    // Throughput step change: the same query is suddenly called far more often.
    const basePerDay = q.baseline.calls / baseDays;
    if (basePerDay > 0 && perDay >= t.stepMinCallsPerDay && perDay / basePerDay >= t.stepRatio && w.timeNs / 1e9 >= t.stepMinTotalSeconds) {
      hits.push({ rule: 'step', severity: 'low', measure: { name: 'callsPerDay', value: round(perDay, 1) },
        why: `${round(perDay)}/day vs ${round(basePerDay)}/day before (${round(perDay / basePerDay, 1)}×)` });
    }

    // On an instance a neighbour was loading, anything measured in time — a
    // latency regression, a share of query time — is likely the neighbour's
    // contention, not this query: a note, not an issue. Page counts do not move
    // with contention, so heavy-by-pages still stands.
    if (neighbourPressure.has(q.instance)) {
      for (const h of hits.filter((x) => x.rule === 'regression' || x.measure.name === 'shareOfDbTime')) {
        notes.push(`${h.rule} on ${q.querySignature} not filed: ${h.why}, during neighbour pressure on ${q.instance}`);
        hits.splice(hits.indexOf(h), 1);
      }
    }
    if (!hits.length) continue;
    hits.sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity]);
    const top = hits[0];
    findings.push({
      ...top, kind: 'query', repo: pair.repo, db: pair.db, instance: q.instance, querySignature: q.querySignature,
      fingerprint: fingerprint(top.rule, q.instance, pair.db, q.querySignature), metrics,
      alsoBreached: hits.slice(1).map((h) => h.rule),
    });
  }

  // Hygiene: dead tuples outnumber live ones past a floor — autovacuum is not
  // keeping up. Only where the agent collects table metrics.
  for (const tb of data.tables) {
    if (tb.deadRows >= t.hygieneDeadRows && tb.deadRows > tb.liveRows) {
      findings.push({
        kind: 'table', rule: 'hygiene', severity: 'low', repo: pair.repo, db: pair.db, instance: tb.instance, table: tb.table,
        fingerprint: fingerprint('hygiene', tb.instance, pair.db, tb.table), measure: { name: 'deadRows', value: tb.deadRows },
        why: `${tb.deadRows.toLocaleString('en-US')} dead rows vs ${tb.liveRows.toLocaleString('en-US')} live in ${tb.table}`,
        metrics: tb, alsoBreached: [],
      });
    }
  }
  return { findings, notes };
}

// ---- Fingerprint, marker, dedup -------------------------------------------------
// The fingerprint is a wire format: change its inputs and every filed issue
// stops matching.
export function fingerprint(rule, instance, db, key) {
  const parts = key === undefined ? [rule, instance, db] : [rule, instance, db, key];
  return createHash('sha1').update(parts.join('|')).digest('hex').slice(0, 12);
}

const MARKER_RE = /<!--\s*dd-dbm:\s*(\{.*?\})\s*-->/s;

export function buildMarker(finding) {
  return `<!-- dd-dbm: ${JSON.stringify({ fp: finding.fingerprint, measure: finding.measure.name, value: finding.measure.value })} -->`;
}

export function parseMarker(body) {
  const m = (body || '').match(MARKER_RE);
  if (!m) return null;
  try {
    const v = JSON.parse(m[1]);
    return typeof v.fp === 'string' ? v : null;
  } catch { return null; }
}

export function composeIssueBody(finding, body) {
  const clean = (body || '').replace(new RegExp(MARKER_RE.source, 'gs'), '').trim();
  return `${buildMarker(finding)}\n\n${clean}`;
}

// A query finding's body ends with a link that opens its DBM query panel, so a
// person lands on the statement and its plans in one click. DBM rejects a
// week-long range as "Invalid Query", so it shows the window's last two days.
export function withDbmPointer(finding, body, ddSite, span) {
  if (!finding.querySignature) return body;
  return `${body.trimEnd()}\n\nDBM: [query ${finding.querySignature}](${dbmQueryUrl(finding, ddSite, span)})`;
}

const DBM_RANGE_MS = 2 * 86400e3;

export function dbmQueryUrl({ querySignature: qs, instance }, ddSite, span) {
  const p = new URLSearchParams({
    query: `database_instance:${instance} query_signature:${qs}`,
    dbPanels: JSON.stringify([{ t: 'dbQueryPanel', qs, dbType: 'PostgreSQL', h: instance }]),
    dbType: 'PostgreSQL',
  });
  if (span) {
    const end = Date.parse(span.to);
    p.set('start', String(Math.max(Date.parse(span.from), end - DBM_RANGE_MS)));
    p.set('end', String(end));
    p.set('paused', 'true');
  }
  return `${ddSite}/databases/queries?${p.toString().replace(/\+/g, '%20')}`;
}

// The issue index: {fp: [{number, state, closedAt, notPlanned, value}]}, from
// the REST listing of `datadog-dbm` issues.
export function indexIssues(issues) {
  const out = {};
  for (const it of issues || []) {
    if (it.pull_request) continue;
    const mk = parseMarker(it.body);
    if (!mk) continue;
    const labels = (it.labels || []).map((l) => (typeof l === 'string' ? l : l.name));
    (out[mk.fp] ||= []).push({
      number: it.number, state: it.state === 'open' ? 'OPEN' : 'CLOSED', closedAt: it.closed_at || null,
      notPlanned: it.state_reason === 'not_planned' || labels.includes('wontfix'), value: mk.value ?? null,
    });
  }
  return out;
}

// NEW, ALREADY_OPEN, ACCEPTED (closed as not planned and not much worse — stay
// closed), REOPEN_ACCEPTED (closed as not planned but now worse by the
// worsen ratio — no fix to wait for), or REGRESSION_CHECK (closed as fixed —
// the reopen gate decides after the investigator finds the deployed commit).
export function classify(matches, value, t) {
  if (!matches?.length) return { kind: 'NEW' };
  const open = matches.find((m) => m.state === 'OPEN');
  if (open) return { kind: 'ALREADY_OPEN', number: open.number };
  const last = [...matches].sort((a, b) => Date.parse(b.closedAt || 0) - Date.parse(a.closedAt || 0))[0];
  if (last.notPlanned) {
    const worse = typeof last.value === 'number' && last.value > 0 && value >= last.value * t.wontfixWorsenRatio;
    return { kind: worse ? 'REOPEN_ACCEPTED' : 'ACCEPTED', number: last.number, recorded: last.value };
  }
  return { kind: 'REGRESSION_CHECK', number: last.number, closedAt: last.closedAt };
}

// Rank for the per-run cap: severity, then total time.
export function rankFindings(list) {
  return [...list].sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity]
    || (b.metrics?.totalSeconds ?? 0) - (a.metrics?.totalSeconds ?? 0));
}

// ---- Reopen gate ------------------------------------------------------------------
// Merged is not deployed. A closed issue reopens only when the commit serving
// the query contains the fix: GitHub's compare of fixSha...deployedSha is
// "ahead" or "identical". With no fix commit on the close event, the deployed
// commit must be newer than the close. With no deployed commit, hold.
export function gateDecision({ deployedSha, compareStatus, deployedCommitDate, closedAt }) {
  if (!deployedSha) return { reopen: false, reason: 'no deployed commit found in APM spans' };
  if (compareStatus) {
    return ['ahead', 'identical'].includes(compareStatus)
      ? { reopen: true, reason: `deployed ${deployedSha.slice(0, 7)} contains the fix` }
      : { reopen: false, reason: `fix not deployed yet (deployed ${deployedSha.slice(0, 7)} is ${compareStatus} of it)` };
  }
  if (deployedCommitDate && closedAt) {
    return Date.parse(deployedCommitDate) >= Date.parse(closedAt)
      ? { reopen: true, reason: `deployed ${deployedSha.slice(0, 7)} is newer than the close` }
      : { reopen: false, reason: `fix not deployed yet (deployed ${deployedSha.slice(0, 7)} predates the close)` };
  }
  return { reopen: false, reason: 'cannot tell whether the fix is deployed' };
}

// ---- Investigator verdict -----------------------------------------------------------
export function validateVerdict(v, kind) {
  if (!v || typeof v !== 'object') return { ok: false, error: 'not an object' };
  if (typeof v.actionable !== 'boolean') return { ok: false, error: 'actionable must be true or false' };
  if (typeof v.reason !== 'string' || !v.reason.trim()) return { ok: false, error: 'reason is required' };
  if (v.deployedSha !== undefined && v.deployedSha !== null && !/^[0-9a-f]{7,40}$/.test(v.deployedSha)) {
    return { ok: false, error: 'deployedSha must be a commit sha or null' };
  }
  if (!v.actionable) return { ok: true, value: v };
  if (typeof v.title !== 'string' || !v.title.trim() || v.title.length > 200) return { ok: false, error: 'title is required (≤200 chars)' };
  if (kind === 'NEW' && (typeof v.body !== 'string' || v.body.trim().length < 40)) return { ok: false, error: 'body is required for a new issue' };
  if (kind !== 'NEW' && (typeof v.comment !== 'string' || v.comment.trim().length < 20)) return { ok: false, error: 'comment is required to reopen' };
  if (/@[A-Za-z0-9-]{2,}/.test(`${v.body || ''}\n${v.comment || ''}`.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, ''))) {
    return { ok: false, error: 'no @mentions outside code spans' };
  }
  return { ok: true, value: v };
}

// ---- Run state --------------------------------------------------------------------
const STATE_RE = /<!--\s*fu-db-sweep-state:\s*(\{.*?\})\s*-->/s;

export function parseSweepState(body) {
  const m = (body || '').match(STATE_RE);
  if (!m) return null;
  try {
    const s = JSON.parse(m[1]);
    return Number.isFinite(s.last_successful_tick) ? { last_successful_tick: s.last_successful_tick } : null;
  } catch { return null; }
}

export function buildStateBody(lastTickMs) {
  return [
    'State for the DB perf sweep cloud routine (fu-db-sweep): when its last completed sweep ended.',
    'The next run reads Datadog DBM from that point (at least 7 days back, at most 28).',
    'The routine edits this and posts each run\'s summary as a comment; leave it closed.',
    '',
    `Last completed sweep: ${new Date(lastTickMs).toISOString()}`,
    '',
    `<!-- fu-db-sweep-state: ${JSON.stringify({ last_successful_tick: lastTickMs })} -->`,
  ].join('\n');
}

// ---- Config -----------------------------------------------------------------------
// {stateIssues?: {"<owner>/<repo>": N}, ddSite?, pairs: [{repo, db, overrides?}]}.
// Each repo keeps its own state issue (window + weekly summary); repo keys are
// matched case-insensitively and normalised to the spelling the pairs use.
export function parseConfig(raw) {
  let c;
  try { c = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { throw new Error(`CONFIG is not JSON: ${e.message}`); }
  const repoRe = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
  if (!c || typeof c !== 'object') throw new Error('CONFIG must be an object');
  if ('stateRepo' in c || 'stateIssue' in c) throw new Error('CONFIG.stateRepo/stateIssue were replaced by stateIssues: {"<owner>/<repo>": N} — one state issue per repo');
  if (!Array.isArray(c.pairs) || !c.pairs.length) throw new Error('CONFIG.pairs must list at least one {repo, db}');
  const seen = new Set();
  const spelling = new Map();
  const pairs = c.pairs.map((p, n) => {
    if (!repoRe.test(p?.repo || '')) throw new Error(`pairs[${n}].repo must be "<owner>/<repo>"`);
    if (!/^[A-Za-z0-9_]+$/.test(p.db || '')) throw new Error(`pairs[${n}].db must be a database name`);
    const lower = p.repo.toLowerCase();
    if (spelling.has(lower) && spelling.get(lower) !== p.repo) throw new Error(`pairs[${n}].repo spells ${p.repo} differently from an earlier pair`);
    spelling.set(lower, p.repo);
    const key = `${lower}|${p.db}`;
    if (seen.has(key)) throw new Error(`pairs[${n}] repeats ${p.repo} ${p.db}`);
    seen.add(key);
    return { repo: p.repo, db: p.db, thresholds: thresholdsFor(p.overrides) };
  });
  const stateIssues = {};
  for (const [repo, n] of Object.entries(c.stateIssues || {})) {
    const canonical = spelling.get(repo.toLowerCase());
    if (!canonical) throw new Error(`CONFIG.stateIssues names ${repo}, which no pair uses`);
    if (!Number.isInteger(n) || n < 1) throw new Error(`CONFIG.stateIssues["${repo}"] must be an issue number`);
    stateIssues[canonical] = n;
  }
  return { stateIssues, ddSite: (c.ddSite || 'https://ap2.datadoghq.com').replace(/\/$/, ''), pairs };
}
