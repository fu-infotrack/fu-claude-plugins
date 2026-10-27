// collectDb() against a fake metric reader: the db:_other attribution, the
// fast-query pre-filter and the instance stats, without Datadog.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { collectDb } from './collect.mjs';

const P = {
  db: 'compliance_mono',
  window: { from: '2026-10-20T00:00:00Z', to: '2026-10-27T00:00:00Z' },
  baseline: { from: '2026-10-13T00:00:00Z', to: '2026-10-20T00:00:00Z' },
  drift: { from: '2026-09-22T00:00:00Z', to: '2026-10-20T00:00:00Z' },
};
const INST = 'pg-prod-1';
const per = { timeNs: 50e6, calls: 1, blksHit: 40000, blksRead: 0 }; // 50 ms, 40k pages per call
const metricOf = (q) => Object.keys(per).find((k) => q.includes({ timeNs: 'queries.time', calls: 'queries.count', blksHit: 'blks_hit', blksRead: 'blks_read' }[k]));

// heavy01 runs only here (its db:_other rows are ours); shared01 also runs in
// another database (stays a sample).
function fakeScalar(span, query) {
  const row = (tags, value) => ({ tags, value });
  if (query.includes('by {database_instance}')) return [row({ database_instance: INST }, 100)];
  if (query.includes('by {query_signature,db}')) {
    return [row({ query_signature: 'heavy01', db: 'compliance_mono' }, 10), row({ query_signature: 'heavy01', db: '_other' }, 90),
      row({ query_signature: 'shared01', db: 'billing' }, 50), row({ query_signature: 'shared01', db: 'compliance_mono' }, 5)];
  }
  if (query.includes('by {database_instance,query_signature}')) {
    const k = metricOf(query);
    const calls = query.includes('db IN (compliance_mono,_other)') ? 100 : 10; // full vs the db:X slice
    const out = [row({ database_instance: INST, query_signature: 'heavy01' }, per[k] * calls),
      row({ database_instance: INST, query_signature: '_other' }, 1e9)];
    if (!query.includes('db IN')) {
      out.push(row({ database_instance: INST, query_signature: 'shared01' }, per[k] * 5));
    }
    return out;
  }
  if (query.includes('by {db}')) return [row({ db: 'text_resource' }, 9e12), row({ db: 'compliance_mono' }, 5e11)];
  if (query.includes('by {schema,table}')) return [];
  if (query.includes('blocked_connections')) return [row({}, 21.7)];
  if (query.includes('percent_usage')) return [row({}, 0.123)];
  if (query.includes('deadlocks')) return [row({}, 1.4)];
  if (query.includes('idle_in_transaction')) return [row({}, null)];
  throw new Error(`unexpected query ${query}`);
}

test('collectDb: _other rows count in full for our own signatures, shared ones stay sampled', async () => {
  const out = await collectDb(P, async (...a) => fakeScalar(...a));
  assert.deepEqual(out.instances, [INST]);
  const bySig = Object.fromEntries(out.queries.map((q) => [q.querySignature, q]));
  assert.deepEqual(Object.keys(bySig).sort(), ['heavy01', 'shared01']);
  assert.equal(bySig.heavy01.sampled, false);
  assert.equal(bySig.heavy01.window.calls, 100);
  assert.equal(bySig.shared01.sampled, true);
  assert.equal(bySig.shared01.window.calls, 5);
  assert.deepEqual(out.instanceStats, [{ instance: INST, maxBlocked: 21.7, maxConnPct: 0.12, maxIdleInTxnSeconds: null, deadlocks: 1, timeNsByDb: { text_resource: 9e12, compliance_mono: 5e11 } }]);
  assert.deepEqual(out.tables, []);
});
