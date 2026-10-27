// One database's DBM numbers, read through the `pup` CLI: everything the rules
// need, as the JSON shape db-sweep-lib.mjs parseCollectorOutput() checks.
// collectDb() takes its metric reader as an argument, so tests run it without
// Datadog; pupScalar() is the real one.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ms = (iso) => Date.parse(iso);
const sleep = (n) => new Promise((r) => setTimeout(r, n));

function runPup(args, env) {
  return new Promise((resolve, reject) => {
    execFile('pup', ['--no-agent', ...args], { env, maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) reject(new Error(`pup ${args[0]} ${args[1]}: ${String(stderr || err.message).trim().split('\n').filter((l) => !/Secret Service|keyring/.test(l))[0] || err.message}`));
      else resolve(stdout);
    });
  });
}

// pup has no scalar query, so a scalar is a timeseries reduced here. Buckets are
// hourly: Datadog aligns a bucket to multiples of its interval, so one
// period-long bucket starts mid-period and drops everything before it.
// Returns [{tags: {key: value}, value}] (group-less -> one row, tags {}).
export function pupScalar({ site, tmpDir = os.tmpdir() } = {}) {
  const env = { ...process.env, ...(site && !process.env.DD_SITE ? { DD_SITE: site.replace(/^https?:\/\//, '') } : {}) };
  let n = 0;
  return async (span, query, aggregator, limit = 1000) => {
    // A "last" value is the period's final hour; a "max" is the peak of raw points.
    const from = aggregator === 'last' ? ms(span.to) - 3600e3 : ms(span.from);
    const to = ms(span.to);
    const q = aggregator === 'max' && !query.includes('.rollup(') ? `${query}.rollup(max)` : query;
    const file = path.join(tmpDir, `db-sweep-ts-${process.pid}-${n++}.json`);
    fs.writeFileSync(file, JSON.stringify({ data: { type: 'timeseries_request', attributes: {
      from, to, interval: Math.max(3600e3, Math.ceil((to - from) / 1000 / 3600e3) * 3600e3),
      queries: [{ name: 'a', data_source: 'metrics', query: q }],
      formulas: [{ formula: 'a', limit: { count: limit, order: 'desc' } }],
    } } }));
    try {
      let out;
      for (let attempt = 1; ; attempt++) {
        try { out = await runPup(['metrics', 'timeseries', '--file', file], env); break; } catch (e) {
          if (attempt >= 3 || !/429|rate limit|timed out|5\d\d/i.test(e.message)) throw e;
          await sleep(5000 * attempt);
        }
      }
      const a = JSON.parse(out).data?.attributes || {};
      return (a.series || []).map((s, i) => {
        const vals = (a.values?.[i] || []).filter((v) => v !== null && v !== undefined).map(Number);
        const value = !vals.length ? null
          : aggregator === 'sum' ? vals.reduce((x, y) => x + y, 0)
            : aggregator === 'max' ? Math.max(...vals)
              : vals[vals.length - 1];
        const tags = Object.fromEntries((s.group_tags || []).map((t) => [t.slice(0, t.indexOf(':')), t.slice(t.indexOf(':') + 1)]));
        return { tags, value };
      });
    } finally { fs.rmSync(file, { force: true }); }
  };
}

// The Datadog agent's own monitoring query runs in every database; it is never ours.
// Boolean syntax throughout: Datadog rejects `IN (...)` mixed with comma filters.
const NOT_AGENT = 'env:prod AND NOT user:datadog';
const METRICS = { timeNs: 'postgresql.queries.time', calls: 'postgresql.queries.count', blksHit: 'postgresql.queries.shared_blks_hit', blksRead: 'postgresql.queries.shared_blks_read' };
const zero = () => ({ timeNs: 0, calls: 0, blksHit: 0, blksRead: 0 });
const chunks = (xs, n) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));
const inList = (xs) => `(${xs.join(',')})`;

// params: {db, window, baseline, drift}, each period {from, to} as ISO strings.
export async function collectDb(params, scalar) {
  const { db } = params;
  const periods = { window: params.window, baseline: params.baseline, drift: params.drift };

  // Every prod instance this database reported query stats from in the window.
  const found = await scalar(params.window, `sum:postgresql.queries.count{db:${db} AND ${NOT_AGENT}} by {database_instance}.as_count()`, 'sum', 50);
  const instances = found.filter((r) => r.value > 0 && r.tags.database_instance).map((r) => r.tags.database_instance);

  // DBM tags most query rows db:_other, so db:X alone is a small sample whose size
  // swings day to day: per-call ratios hold, counts and shares do not. A signature
  // seen only under db:X (and _other) is attributed in full — its _other rows are
  // ours; one seen under another database too stays a sample (`sampled: true`).
  // query_signature has an `_other` rollup bucket of its own; it is no query.
  async function sums(filters, keep) {
    const byKey = new Map();
    for (const [period, span] of Object.entries(periods)) {
      const results = await Promise.all(Object.entries(METRICS).map(async ([k, m]) =>
        [k, (await Promise.all(filters.map((f) => scalar(span, `sum:${m}{${f}} by {database_instance,query_signature}.as_count()`, 'sum')))).flat()]));
      for (const [k, rows] of results) {
        for (const r of rows) {
          const inst = r.tags.database_instance; const sig = r.tags.query_signature;
          if (!inst || !sig || sig === '_other' || !keep(inst, sig)) continue;
          const key = `${inst}|${sig}`;
          if (!byKey.has(key)) byKey.set(key, { instance: inst, querySignature: sig, window: zero(), baseline: zero(), drift: zero() });
          byKey.get(key)[period][k] += Math.max(0, Math.round(r.value || 0));
        }
      }
    }
    return byKey;
  }

  const sampled = await sums([`db:${db} AND ${NOT_AGENT}`], (inst) => instances.includes(inst));

  // Only queries a rule could fire on go further — slow-ish (>= 1 ms avg), page-hungry
  // (>= 1,000 pages/call) or among the 50 most called (step changes) — which keeps
  // the API calls down. Thresholds overridden below these floors never see the
  // dropped queries.
  const perSig = new Map();
  for (const q of sampled.values()) {
    const cur = perSig.get(q.querySignature) || { avgMs: 0, pages: 0, calls: 0 };
    for (const s of [q.window, q.baseline, q.drift]) {
      if (!s.calls) continue;
      cur.avgMs = Math.max(cur.avgMs, s.timeNs / 1e6 / s.calls);
      cur.pages = Math.max(cur.pages, (s.blksHit + s.blksRead) / s.calls);
    }
    cur.calls += q.window.calls;
    perSig.set(q.querySignature, cur);
  }
  const busiest = new Set([...perSig.entries()].sort((x, y) => y[1].calls - x[1].calls).slice(0, 50).map(([sig]) => sig));
  const sigs = [...perSig.entries()].filter(([sig, v]) => v.avgMs >= 1 || v.pages >= 1000 || busiest.has(sig)).map(([sig]) => sig);
  const kept = new Set(sigs);
  const whole = { from: params.drift.from, to: params.window.to };
  const owners = new Map();
  for (const c of chunks(sigs, 100)) {
    for (const r of await scalar(whole, `sum:postgresql.queries.count{${NOT_AGENT} AND query_signature IN ${inList(c)}} by {query_signature,db}.as_count()`, 'sum')) {
      if (!r.value) continue;
      if (!owners.has(r.tags.query_signature)) owners.set(r.tags.query_signature, new Set());
      owners.get(r.tags.query_signature).add(r.tags.db);
    }
  }
  const ours = sigs.filter((s) => [...(owners.get(s) || [])].every((d) => d === db || d === '_other'));
  const full = ours.length
    ? await sums(chunks(ours, 100).map((c) => `${NOT_AGENT} AND db IN (${db},_other) AND query_signature IN ${inList(c)}`), (inst) => instances.includes(inst))
    : new Map();
  const oursSet = new Set(ours);
  const queries = [...sampled.values()]
    .filter((q) => kept.has(q.querySignature))
    .map((q) => (oursSet.has(q.querySignature) ? { ...(full.get(`${q.instance}|${q.querySignature}`) || q), sampled: false } : { ...q, sampled: true }))
    .filter((q) => q.window.calls > 0);

  // Instance pressure over the window, and which databases load each instance.
  const one = async (q, agg) => { const r = await scalar(params.window, q, agg, 1); return r.length && r[0].value !== null ? r[0].value : null; };
  const r2 = (v) => (v === null ? null : Math.round(v * 100) / 100);
  const instanceStats = await Promise.all(instances.map(async (inst) => {
    const f = `database_instance:${inst}`;
    const [maxBlocked, maxConnPct, deadlocks, maxIdleInTxnSeconds, byDb] = await Promise.all([
      one(`sum:postgresql.activity.blocked_connections{${f}}`, 'max'),
      one(`max:postgresql.percent_usage_connections{${f}}`, 'max'),
      one(`sum:postgresql.deadlocks.count{${f}}.as_count()`, 'sum'),
      one(`max:postgresql.locks.idle_in_transaction_age{${f}}`, 'max'),
      scalar(params.window, `sum:postgresql.queries.time{${f} AND NOT user:datadog} by {db}.as_count()`, 'sum', 100),
    ]);
    // The ten busiest databases plus this one.
    const ranked = byDb.filter((r) => r.tags.db && r.value !== null).sort((a, b) => b.value - a.value);
    const keep = ranked.filter((r, i) => i < 10 || r.tags.db === db);
    const timeNsByDb = Object.fromEntries(keep.map((r) => [r.tags.db, Math.max(0, Math.round(r.value))]));
    return { instance: inst, maxBlocked: r2(maxBlocked), maxConnPct: r2(maxConnPct), maxIdleInTxnSeconds: r2(maxIdleInTxnSeconds), deadlocks: deadlocks === null ? null : Math.round(deadlocks), timeNsByDb };
  }));

  // Table hygiene, where the agent collects relation metrics (often it does not).
  const tables = [];
  for (const inst of instances) {
    const f = `database_instance:${inst},db:${db}`;
    const [dead, live] = await Promise.all([
      scalar(params.window, `avg:postgresql.dead_rows{${f}} by {schema,table}`, 'last', 200),
      scalar(params.window, `avg:postgresql.live_rows{${f}} by {schema,table}`, 'last', 200),
    ]);
    const liveBy = new Map(live.map((r) => [`${r.tags.schema}.${r.tags.table}`, r.value]));
    for (const r of dead) {
      if (r.value === null || !r.tags.table) continue;
      const name = `${r.tags.schema}.${r.tags.table}`;
      tables.push({ instance: inst, table: name, deadRows: Math.round(r.value), liveRows: Math.round(liveBy.get(name) || 0) });
    }
  }

  return { db, instances, queries, fastQueriesDropped: perSig.size - sigs.length, instanceStats, tables };
}

// The statement behind one signature, from a DBM query sample (obfuscated, as
// DBM stores it), or null when no sample was kept in the window.
export async function dbmStatement({ site, signature, instance, span }) {
  const env = { ...process.env, ...(site && !process.env.DD_SITE ? { DD_SITE: site.replace(/^https?:\/\//, '') } : {}) };
  const query = `@db.query_signature:${signature}${instance ? ` host:${instance}` : ''}`;
  const out = await runPup(['dbm', 'samples', 'search', '--query', query, '--from', span.from, '--to', span.to, '--limit', '1'], env);
  const ev = JSON.parse(out).result?.events?.[0]?.event?.custom?.db;
  return ev?.statement ? { sql: ev.statement, tables: ev.metadata?.tables || [] } : null;
}
