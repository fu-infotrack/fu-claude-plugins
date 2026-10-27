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

// Every prod instance this database reported query stats from in the window.
const found = await scalar(PARAMS.window, `sum:postgresql.queries.count{db:${db},env:prod} by {database_instance}.as_count()`, "sum", 50);
const instances = found.filter((r) => r.value > 0 && r.tags.database_instance).map((r) => r.tags.database_instance);

// Per-query sums over each period, joined on (instance, query_signature).
const METRICS = { timeNs: "postgresql.queries.time", calls: "postgresql.queries.count", blksHit: "postgresql.queries.shared_blks_hit", blksRead: "postgresql.queries.shared_blks_read" };
const zero = () => ({ timeNs: 0, calls: 0, blksHit: 0, blksRead: 0 });
const byKey = new Map();
for (const [period, span] of Object.entries({ window: PARAMS.window, baseline: PARAMS.baseline, drift: PARAMS.drift })) {
  const results = await Promise.all(Object.entries(METRICS).map(async ([k, m]) =>
    [k, await scalar(span, `sum:${m}{db:${db},env:prod} by {database_instance,query_signature}.as_count()`, "sum")]));
  for (const [k, rows] of results) {
    for (const r of rows) {
      const inst = r.tags.database_instance, sig = r.tags.query_signature;
      if (!inst || !sig || !instances.includes(inst)) continue;
      const key = `${inst}|${sig}`;
      if (!byKey.has(key)) byKey.set(key, { instance: inst, querySignature: sig, window: zero(), baseline: zero(), drift: zero() });
      byKey.get(key)[period][k] = Math.max(0, Math.round(r.value || 0));
    }
  }
}
const queries = [...byKey.values()].filter((q) => q.window.calls > 0);

// Instance pressure over the window, and which databases load each instance.
const one = async (q, agg) => { const r = await scalar(PARAMS.window, q, agg, 1); return r.length && r[0].value !== null ? r[0].value : null; };
const instanceStats = await Promise.all(instances.map(async (inst) => {
  const f = `database_instance:${inst}`;
  const [maxBlocked, maxConnPct, deadlocks, maxIdleInTxnSeconds, byDb] = await Promise.all([
    one(`sum:postgresql.activity.blocked_connections{${f}}`, "max"),
    one(`max:postgresql.percent_usage_connections{${f}}`, "max"),
    one(`sum:postgresql.deadlocks.count{${f}}.as_count()`, "sum"),
    one(`max:postgresql.locks.idle_in_transaction_age{${f}}`, "max"),
    scalar(PARAMS.window, `sum:postgresql.queries.time{${f}} by {db}.as_count()`, "sum", 100),
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

return { db, instances, queries, instanceStats, tables };
