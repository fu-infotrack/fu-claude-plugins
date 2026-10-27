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
  a model's query writing. It was last run live on 2026-10-27, across the three
  routine databases together: 104 API calls in about 7 s. The query lists came
  out at 23 KB for compliance_mono, 68 KB for entityplatform and 12 KB for
  infotrackcredit. Only queries a rule could fire on are kept: at least 1 ms
  avg, at least 1,000 pages per call, or among the 50 most called. That pre-filter
  dropped 739 of entityplatform's ~930 signatures; without it the result was
  236 KB from 287 calls, too big for the agent to copy. Change a query
  in it and re-run it live before merging; the hermetic tests cannot reach
  Datadog. Values are rounded and the per-instance database list trimmed to the
  top 10 so the agent can copy the result into its file faithfully.
- **DBM tags most query rows `db:_other`.** On our shared RDS cluster a `db:X`
  filter sees a small slice of a database's rows, and the slice's size swings
  about 10× from day to day. Risk's `9b67…` had ~4,000 calls/day under `_other`
  vs 3–289/day under `db:compliance_mono`. Per-call ratios survive that; counts,
  totals and shares do not. So the collector finds the signatures under `db:X`
  and then checks which databases each one appears under. A signature seen only
  under `X` (and `_other`) is summed over `db IN (X,_other)`. One shared with
  another database stays the db-tagged slice, marked `sampled: true`, and gets
  only the pages-per-call rule.
  - `query_signature` has an `_other` bucket of its own; it is dropped.
  - Every query excludes `user:datadog`. The agent's own monitoring query
    (`2afe7f44…`) runs in every database and looks like 97–99% of the time of an
    idle reader.
  - Metric filters use `AND`/`NOT` syntax, because Datadog rejects `IN (...)`
    mixed with comma filters.
  - The acceptance fixtures below are db-tagged slices from before attribution:
    they still test the rules, not today's prod numbers.
- **The rules are pure** (`db-sweep-lib.mjs` `evaluate`) and the acceptance
  fixtures in `db-sweep-lib.test.mjs` are real prod numbers from the hand
  analysis that designed them: the Risk `monitoring_event` window scan must file
  as med, the `text_resource` blocking incident must stay a summary line, the
  inbox cleanup must not file — including the week it averaged 54 ms because the
  neighbour was blocking the instance.
- **Each repo is swept on its own**: its own state issue, window, summary and
  cap of 5. Any of its collectors failing fails that repo — a failed summary in
  it, nothing filed, its state kept — because a finding from half the data is
  worse than none; the other repos carry on. A repo with nothing to file gets its
  summary (and state advance) from `plan`; the rest from `finish`.
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
observe (summary with drafts, no filing, no state), per-repo summaries and
state, a failed collector failing only its repo, every repo failing, a bad
verdict, the per-repo cap, NO_WORK, state-issue bootstrap, skipped pairs, two
instances. The stub serves two repos, with fixtures under `$FX/<repo name>/`.
