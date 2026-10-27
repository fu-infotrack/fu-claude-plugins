# fu-db-sweep — CLAUDE.md

Read this before changing anything under `plugins/fu-db-sweep/`. Repo-wide rules
live in the root `CLAUDE.md`; the routine mechanics this copies (no plugin in a
routine, REST-only GitHub, repo-bound proxy, state in a closed issue, Haiku
orchestrator copying printed prompts) are explained in
`plugins/fu-log-sweep/CLAUDE.md` — read its cloud-routine section first.

## Shape

- **`collector-query.js` is the whole Datadog read.** `prepare` substitutes the
  `PARAMS` line per pair and the collector agent sends the file verbatim through
  the connector's `execute_code`, so the numbers the rules see do not depend on
  a model's query writing. It was run live against `compliance_mono` on
  2026-10-27 (27 API calls, ~2.4 s, 2 instances, 108 signatures). Change a query
  in it and re-run it live before merging; the hermetic tests cannot reach
  Datadog. Values are rounded and the per-instance database list trimmed to the
  top 10 so the agent can copy the result into its file faithfully.
- **The rules are pure** (`db-sweep-lib.mjs` `evaluate`) and the acceptance
  fixtures in `db-sweep-lib.test.mjs` are real prod numbers from the hand
  analysis that designed them: the Risk `monitoring_event` window scan must file
  as med, the `text_resource` blocking incident must stay a summary line, the
  inbox cleanup must not file — including the week it averaged 54 ms because the
  neighbour was blocking the instance.
- **Any collector failing fails the whole run** — a failed summary, nothing
  filed, state kept — because a finding from half the data is worse than none.
- **The fingerprint is a wire format**: `sha1(rule|instance|db|query_signature)`
  (or `|table`, or no key for instance pressure), carried with the measured
  value in a `<!-- dd-dbm: {...} -->` marker. The value is what *not planned*
  issues are compared against (reopen at 2× worse).
- **Reopen gate**: the investigator reports the `git.commit.sha` on the newest
  span for the statement; `finish` compares the close event's commit with it
  (`repos/{repo}/compare/{fix}...{deployed}`, `ahead`/`identical` = deployed),
  or with no close commit, the deployed commit's date against the close.

## Tests

```bash
node --test plugins/fu-db-sweep/scripts/*.test.mjs
```

`db-sweep-lib.test.mjs` covers windows, every rule, overrides, strict collector
parsing, the marker, classify, the gate and the verdict validator.
`routine.test.mjs` runs `prepare` → `plan` → `finish` with a throwaway `$HOME`,
fake clones under `DB_SWEEP_SEARCH_ROOT`, and the same proxy-faithful `gh` stub
as fu-log-sweep: live filing, held vs reopened, accepted and already-open,
observe (summary with drafts, no filing, no state), a failed collector, a bad
verdict, the cap, NO_WORK, state-issue bootstrap, skipped pairs, two instances.
