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

Queries the Datadog agent runs (`user:datadog`) are never counted. A query
signature that also runs in another database is only partly attributable, so it
is judged on pages per call alone (see `CLAUDE.md`).

## Closing stale issues

An open issue the sweep filed is closed (as completed, with a comment saying
why) after **2 consecutive complete runs** in which it is clear;
`closeAfterClearRuns` in `CONFIG` changes that, `0` turns it off. Clear means
it did not fire, and:

- regression / step: re-measured at or below the filed value ÷ the rule's ratio
  (its baseline moves, so not firing alone proves nothing);
- heavy / hygiene / pressure: nothing more — those rules are absolute;
- or its query is no longer among the collected ones.

A sampled query's regression, a missing table or instance, or a neighbour's
pressure holding a finding back is never clear, and resets the count. Each
run's summary lists the issues on their way to a close under **Stale**.

## Tests

```bash
node --test plugins/fu-db-sweep/scripts/*.test.mjs
```
