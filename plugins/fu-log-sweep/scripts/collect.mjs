// One repo's error buckets, read through the `pup` CLI: the counts by
// (exception type, service) and the newest sample of each, as the JSON shape
// log-sweep-lib.mjs parseCollectorOutput() checks. The same calls /log-sweep
// makes, so a sample's stack is the same JSON string and hashes the same.
// collectRepo() and bucketVersions() take their pup runner as an argument, so
// tests run them without Datadog; pupRunner() is the real one.
import { execFile } from 'node:child_process';
import { buildBucketQuery } from './log-sweep-lib.mjs';

const sleep = (n) => new Promise((r) => setTimeout(r, n));

// Returns async (args) => parsed JSON. Retries rate limits and 5xx: the logs
// APIs allow about 10 calls per 10 s.
export function pupRunner({ site, retryMs = 5000 } = {}) {
  const env = { ...process.env, ...(site && !process.env.DD_SITE ? { DD_SITE: site.replace(/^https?:\/\//, '') } : {}) };
  const once = (args) => new Promise((resolve, reject) => {
    execFile('pup', ['--no-agent', ...args], { env, maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) reject(new Error(`pup ${args[0]} ${args[1]}: ${String(stderr || err.message).trim().split('\n').filter((l) => !/Secret Service|keyring/.test(l))[0] || err.message}`));
      else resolve(stdout);
    });
  });
  return async (args) => {
    for (let attempt = 1; ; attempt++) {
      try { return JSON.parse(await once(args)); } catch (e) {
        if (attempt >= 4 || !/429|rate limit|timed out|5\d\d/i.test(e.message)) throw e;
        await sleep(retryMs * attempt);
      }
    }
  };
}

// Indexed storage only: without it pup tries Flex first, which this org lacks.
// --limit is per facet; pup's default (10) silently drops the rest.
const aggregate = (query, from, to, groupBy, limit) => ['logs', 'aggregate', '--storage', 'indexes', '--query', query,
  '--from', from, '--to', to, '--compute', 'count', '--group-by', groupBy, '--limit', String(limit)];

const getPath = (obj, dotted) => dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
const str = (v) => (typeof v === 'string' && v ? v : null);

// params: {query, env, statusQuery, errorFacet, stackPath, messagePath, from, to, threshold, cap}.
// stackPath/messagePath are paths on pup's raw event (`attributes.attributes.Exception`).
export async function collectRepo(params, pup) {
  const { query, errorFacet, from, to } = params;
  const agg = await pup(aggregate(query, from, to, `${errorFacet},service`, 100));
  const all = (agg.data?.buckets || []).map((b) => ({
    errorKind: b.by?.[errorFacet], service: b.by?.service, count: Math.round(Number(b.computes?.c0) || 0),
  })).filter((b) => str(b.errorKind) && str(b.service));
  const kept = all.filter((b) => b.count >= params.threshold).sort((a, b) => b.count - a.count).slice(0, params.cap);

  const buckets = [];
  for (const b of kept) {
    // A failed sample is recorded as none: plan skips a bucket it cannot sign.
    let samples = [];
    try {
      const res = await pup(['logs', 'search', '--storage', 'indexes', '--query', buildBucketQuery(b.service, params.env, params.statusQuery, errorFacet, b.errorKind), '--from', from, '--to', to, '--limit', '1']);
      const ev = (Array.isArray(res.data) ? res.data : [])[0];
      if (ev) {
        const s = { timestamp: str(getPath(ev, 'attributes.timestamp')) };
        s.message = str(getPath(ev, params.messagePath)) || str(getPath(ev, 'attributes.attributes.MessageTemplate'));
        const stack = str(getPath(ev, params.stackPath));
        if (stack) s.stack = stack;
        samples = [s];
      }
    } catch { /* samples stays [] */ }
    buckets.push({ ...b, versions: [], samples });
  }
  return { buckets, total: all.length };
}

// The release gate's per-version counts for one bucket: [{version, count}].
export async function bucketVersions({ bucketQuery: q, versionTag, from, to }, pup) {
  const res = await pup(aggregate(q, from, to, versionTag, 50));
  return (res.data?.buckets || []).map((b) => ({ version: b.by?.[versionTag], count: Math.round(Number(b.computes?.c0) || 0) }))
    .filter((v) => str(v.version) && v.count > 0);
}
