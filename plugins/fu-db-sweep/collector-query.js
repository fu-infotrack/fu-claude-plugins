// Body of one Datadog MCP `execute_code` call: everything the rules need for one
// database, as the JSON shape db-sweep-lib.mjs parseCollectorOutput() checks.
// The collector agent replaces the PARAMS line and sends the rest verbatim.
import { client, v2 } from "@datadog/datadog-api-client";

const PARAMS = { db: "__DB__", window: { from: "__W_FROM__", to: "__W_TO__" }, baseline: { from: "__B_FROM__", to: "__B_TO__" }, drift: { from: "__D_FROM__", to: "__D_TO__" } };

const api = new v2.MetricsApi(client.createConfiguration());
const ms = (iso) => Date.parse(iso);

// One scalar query -> [{tags: {key: value}, value}] (group-less -> one row, tags {}).
async function scalar(span, query, aggregator, limit = 1000) {
  const res = await api.queryScalarData({ body: { data: { type: "scalar_request", attributes: {
    from: ms(span.from), to: ms(span.to),
    queries: [{ name: "a", dataSource: "metrics", aggregator, query }],
    formulas: [{ formula: "a", limit: { count: limit, order: "desc" } }],
  } } } });
  const cols = res.data.attributes.columns || [];
  const groups = cols.filter((c) => c.type === "group");
  const num = cols.find((c) => c.type === "number");
  if (!num) return [];
  return (num.values || []).map((v, i) => ({
    tags: Object.fromEntries(groups.map((g) => [g.name, (g.values[i] || []).join(",")])),
    value: v === null || v === undefined ? null : Number(v),
  }));
}

const db = PARAMS.db;

// The Datadog agent's own monitoring query runs in every database; it is never ours.
// Boolean syntax throughout: Datadog rejects `IN (...)` mixed with comma filters.
const NOT_AGENT = "env:prod AND NOT user:datadog";

// Every prod instance this database reported query stats from in the window.
const found = await scalar(PARAMS.window, `sum:postgresql.queries.count{db:${db} AND ${NOT_AGENT}} by {database_instance}.as_count()`, "sum", 50);
const instances = found.filter((r) => r.value > 0 && r.tags.database_instance).map((r) => r.tags.database_instance);

// DBM tags most query rows db:_other, so db:X alone is a small sample whose size
// swings day to day: per-call ratios hold, counts and shares do not. A signature
// seen only under db:X (and _other) is attributed in full — its _other rows are
// ours; one seen under another database too stays a sample (`sampled: true`).
// query_signature has an `_other` rollup bucket of its own; it is no query.
const METRICS = { timeNs: "postgresql.queries.time", calls: "postgresql.queries.count", blksHit: "postgresql.queries.shared_blks_hit", blksRead: "postgresql.queries.shared_blks_read" };
const PERIODS = { window: PARAMS.window, baseline: PARAMS.baseline, drift: PARAMS.drift };
const zero = () => ({ timeNs: 0, calls: 0, blksHit: 0, blksRead: 0 });
const chunks = (xs, n) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));
const inList = (xs) => `(${xs.join(",")})`;

async function sums(filter, keep) {
  const byKey = new Map();
  for (const [period, span] of Object.entries(PERIODS)) {
    const results = await Promise.all(Object.entries(METRICS).map(async ([k, m]) =>
      [k, (await Promise.all(filter.map((f) => scalar(span, `sum:${m}{${f}} by {database_instance,query_signature}.as_count()`, "sum")))).flat()]));
    for (const [k, rows] of results) {
      for (const r of rows) {
        const inst = r.tags.database_instance, sig = r.tags.query_signature;
        if (!inst || !sig || sig === "_other" || !keep(inst, sig)) continue;
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
// the API calls and the result small enough for the agent to copy. Thresholds
// overridden below these floors never see the dropped queries.
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
const whole = { from: PARAMS.drift.from, to: PARAMS.window.to };
const owners = new Map();
for (const c of chunks(sigs, 100)) {
  for (const r of await scalar(whole, `sum:postgresql.queries.count{${NOT_AGENT} AND query_signature IN ${inList(c)}} by {query_signature,db}.as_count()`, "sum")) {
    if (!r.value) continue;
    if (!owners.has(r.tags.query_signature)) owners.set(r.tags.query_signature, new Set());
    owners.get(r.tags.query_signature).add(r.tags.db);
  }
}
const ours = sigs.filter((s) => [...(owners.get(s) || [])].every((d) => d === db || d === "_other"));
const full = ours.length
  ? await sums(chunks(ours, 100).map((c) => `${NOT_AGENT} AND db IN (${db},_other) AND query_signature IN ${inList(c)}`), (inst) => instances.includes(inst))
  : new Map();
const oursSet = new Set(ours);
const queries = [...sampled.values()]
  .filter((q) => kept.has(q.querySignature))
  .map((q) => (oursSet.has(q.querySignature) ? { ...(full.get(`${q.instance}|${q.querySignature}`) || q), sampled: false } : { ...q, sampled: true }))
  .filter((q) => q.window.calls > 0);

// Instance pressure over the window, and which databases load each instance.
const one = async (q, agg) => { const r = await scalar(PARAMS.window, q, agg, 1); return r.length && r[0].value !== null ? r[0].value : null; };
const instanceStats = await Promise.all(instances.map(async (inst) => {
  const f = `database_instance:${inst}`;
  const [maxBlocked, maxConnPct, deadlocks, maxIdleInTxnSeconds, byDb] = await Promise.all([
    one(`sum:postgresql.activity.blocked_connections{${f}}`, "max"),
    one(`max:postgresql.percent_usage_connections{${f}}`, "max"),
    one(`sum:postgresql.deadlocks.count{${f}}.as_count()`, "sum"),
    one(`max:postgresql.locks.idle_in_transaction_age{${f}}`, "max"),
    scalar(PARAMS.window, `sum:postgresql.queries.time{${f} AND NOT user:datadog} by {db}.as_count()`, "sum", 100),
  ]);
  // The ten busiest databases plus this one keep the file small enough to copy.
  const ranked = byDb.filter((r) => r.tags.db && r.value !== null).sort((a, b) => b.value - a.value);
  const keep = ranked.filter((r, i) => i < 10 || r.tags.db === db);
  const timeNsByDb = Object.fromEntries(keep.map((r) => [r.tags.db, Math.max(0, Math.round(r.value))]));
  const r2 = (v) => (v === null ? null : Math.round(v * 100) / 100);
  return { instance: inst, maxBlocked: r2(maxBlocked), maxConnPct: r2(maxConnPct), maxIdleInTxnSeconds: r2(maxIdleInTxnSeconds), deadlocks: deadlocks === null ? null : Math.round(deadlocks), timeNsByDb };
}));

// Table hygiene, where the agent collects relation metrics (often it does not).
const tables = [];
for (const inst of instances) {
  const f = `database_instance:${inst},db:${db}`;
  const [dead, live] = await Promise.all([
    scalar(PARAMS.window, `avg:postgresql.dead_rows{${f}} by {schema,table}`, "last", 200),
    scalar(PARAMS.window, `avg:postgresql.live_rows{${f}} by {schema,table}`, "last", 200),
  ]);
  const liveBy = new Map(live.map((r) => [`${r.tags.schema}.${r.tags.table}`, r.value]));
  for (const r of dead) {
    if (r.value === null || !r.tags.table) continue;
    const name = `${r.tags.schema}.${r.tags.table}`;
    tables.push({ instance: inst, table: name, deadRows: Math.round(r.value), liveRows: Math.round(liveBy.get(name) || 0) });
  }
}

return { db, instances, queries, fastQueriesDropped: perSig.size - sigs.length, instanceStats, tables };
