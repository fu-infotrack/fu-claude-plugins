# fu-db-sweep

A weekly cloud routine: Datadog **Database Monitoring** for a list of
`(repo, db)` pairs → de-duped, report-only GitHub issues for prod query and
instance problems, plus a weekly summary comment in each repo.

It contributes nothing to a local session — no command, skill or hook. It
exists to be cloned by a Claude Code routine; set that up from
[`routines/db-sweep.md`](routines/db-sweep.md).

## What it reports

| Rule | Fires when (defaults) | Severity |
|---|---|---|
| heavy | ≥ 20,000 buffer pages per call, or ≥ 20% of the database's query time at ≥ 10 ms avg; ≥ 3 calls/day | med |
| regression | avg ≥ 2× the previous window or the 28 days before it; ≥ 5 ms, ≥ 15 calls/day | med; high at ≥ 5× and > 100 calls/day |
| step | calls/day ≥ 3× the previous window; ≥ 150/day, ≥ 60 s total | low |
| pressure | blocked sessions ≥ 5, connections ≥ 80%, deadlocks ≥ 5, or a transaction idle ≥ 10 min — and this database is the busiest on the instance | high |
| hygiene | dead rows ≥ 100,000 and above live rows (only where DBM collects table metrics) | low |

A neighbour database's pressure is a summary line, never an issue, and on an
instance under neighbour pressure the time-based findings (regressions, share
of time) become summary lines too — contention inflates them. Thresholds are
`DEFAULT_THRESHOLDS` in `scripts/db-sweep-lib.mjs`, overridable per pair.

## Tests

```bash
node --test plugins/fu-db-sweep/scripts/*.test.mjs
```
