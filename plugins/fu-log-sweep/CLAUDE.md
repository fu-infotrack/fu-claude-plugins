# fu-log-sweep — CLAUDE.md

Read this before changing anything under `plugins/fu-log-sweep/`. Repo-wide rules — worktrees,
the install cache, the `fu-tools` config contract, the three registries, and the full
external-dependency list — live in the root `CLAUDE.md`.

## Design

An orchestrator/triage-gate/investigator shape: expensive work stays inside sub-agents
whose context never returns, and GitHub is the regression authority. See `docs/DESIGN.md`
for the full design.

There is no Datadog-supplied `issue_id` to dedup on, so this plugin computes its own
error signature — `sha1(type|service|top-app-frame)` — and dedups GitHub issues against
that. Change the signature inputs and every previously filed issue stops matching, so
treat it as a wire format.

The frame is the first app-namespace frame, else the first non-BCL frame that is not
runtime-compiled: `lambda_methodN` (DI activators, compiled expressions) is renumbered every
process, and signing on it filed one prod error three times across deploys (0.3.1).

## The cloud routine (`routines/log-sweep.md`)

The same sweep as one daily Claude Code routine over a list of repos, in the
DB perf sweep's shape (`plugins/fu-db-sweep/CLAUDE.md`). A routine installs no
plugin, so it clones this repo and runs `scripts/routine.mjs`; Datadog is read
with `pup` (npm-installed, `DD_ACCESS_TOKEN`), with no connector:

- **The script does everything but judgement.** `collect.mjs` is the whole log
  read: per repo, one `pup logs aggregate` by (exception facet, service) and one
  newest `pup logs search` per kept bucket; `plan` adds one version aggregate per
  REGRESSION for the release gate. One investigator per candidate
  (`routine-investigator.md`) does the triage-gate's judgement and the writeup
  together and writes a verdict file; it reads more samples and APM spans
  through `pup` too. Each step prints a status token first and the agent
  prompts after it, so the Haiku orchestrator copies and never reads data. The
  handoff is on disk in `~/.claude/log-sweep/routine/`, and `wait investigate`
  blocks on the verdict files (the DB sweep's lesson: a Haiku orchestrator
  waiting on notifications ended its turn and never ran `finish`).
- **Until 0.3.0 a collector agent read Datadog through the MCP connector**, one
  routine per repo. pup replaced it so the counts do not depend on a model's
  query writing, and one routine replaced N. Its two hard-won rules no longer
  apply: the connector's YAML-indented stacks (pup returns the same JSON string
  `/log-sweep` hashes) and its refusal of a dotted `extra_fields` name (pup's
  raw event is read by `stackPath` directly).
- **pup measured live** (2026-10-27, Compliance.Mono, observe; 3 buckets in
  about 2 s): two flags matter. `--storage indexes`, because pup otherwise tries
  Flex first, which this org lacks (403, then a retry on indexes). An explicit
  `--limit`, because pup's default is **10 groups per facet** and silently drops
  the rest — and `--limit` is per facet, capped at 10,000 groups across all
  dimensions, which is why version is a separate per-bucket aggregate rather
  than a third group-by. 2 of the 3 buckets dedup'd against issues filed
  earlier; the third had none.
- **Each repo is swept on its own**: its own resolved config (`sweep.mjs
  resolve` with the clone as cwd, the repo's entry over the top-level
  defaults), state issue, window, caps (20 buckets, 10 candidates) and failure.
  A collection failure fails that repo — nothing filed, state kept — because
  dedup against half the buckets is worse than none. A bucket whose sample read
  failed is skipped with a note: signing it from nothing would file a
  message-signature duplicate.
- **GitHub is REST with explicit pages**, for the reasons `fu-review-prs/CLAUDE.md` gives
  (GraphQL 403s; the proxy rejects `--paginate`'s numeric-ID links). Dedup lists the
  `datadog-logs`-labelled issues and reads their markers rather than using issue search:
  no index lag, and `closed_at` comes with the listing, so the gate needs no extra call.
  `/log-sweep` searches all issues, so an issue that lost its label dedups locally but
  not in the routine.
- **State lives in a bot issue in each target repo.** A sandbox keeps no file between
  runs, and a run is told nothing about earlier runs (the docs give it only the prompt,
  a fire payload, the clones, env vars and connectors; the routines API that lists runs
  needs the user's claude.ai login, which a run lacks). So the end of the last completed
  sweep is a hidden `<!-- fu-log-sweep-state: {"last_successful_tick": ms} -->` marker in a
  closed issue in the target repo — the user's choice over one in this repo. The
  routine's `CONFIG` names it by number (**`stateIssues[repo]`**), and `prepare` reads it with
  one `GET repos/{repo}/issues/{n}`. It cannot be searched for: the cloud proxy refuses
  every API path outside `repos/{owner}/{repo}/` (measured 2026-10-25: v0.2.3's
  `gh api user` got HTTP 403 "sessions are bound to their configured repositories", so
  every run swept 24 h and saved nothing), which rules out `user` and `search/issues`. A
  label was rejected in v0.2.3 because `POST issues` silently drops labels without push
  access. The number needs no author check: only the issue's author or a maintainer can
  edit its body. **Bootstrap is loud:** with no entry, a live run creates the
  issue (POST, then close) and prints `add "<repo>": N to CONFIG.stateIssues` —
  until that is done, every live run creates another. A configured issue whose body holds
  no state marker (a mistyped number) counts as unreadable, so its body is never
  overwritten.
  `prepare` feeds it to `windowStartMs` (the same 24 h floor / 30 d cap as the local state
  file), so a weekday schedule's Monday run covers the weekend and a failed run's window
  is swept again. It is saved only by a **live** run that completed with **no failed
  candidate** (`plan`'s `NO_WORK`, or `finish`); a retried window is safe because what the
  failed run did file dedups as already open. If the state issue is unreadable, the run
  sweeps 24 h and writes nothing. No baseline
  mode in the routine (run `--baseline` locally once).

## Alert triage (`routines/datadog-ops.md`) — v0.6.0

A Datadog notification rule sends each Alert-state notification of a monitor tagged
`aiops:true` to a webhook that fires the **Datadog Ops** cloud routine — one run per alert,
nothing local. It is in this plugin because "does this error already have a ticket?" is the
sweep's signature and dedup: the run signs errors with this repo's `buildSignature` and
matches `datadog-logs` issues by the same `dd-log-sig` marker, so an alert never files a
duplicate of a swept error.

- **0.6.0 removed the OneDrive path.** Until 0.5.0 a Power Automate flow copied each
  Datadog → Teams message into a OneDrive inbox, the `alert-watch` systemd service forwarded
  file names in batches, and the routine read and moved them through the Microsoft 365
  connector; a manual `alert-triage.mjs handle` / `claude -p` / `finish` path read the same
  files. The webhook replaces all of it: no files, no archiving, no batching, no connector.
- **The fire endpoint passes only `text`** (measured 2026-11-10, run
  `cse_01Da7xFAsKUpYHTV7GwVeXpz`): a POST with `{"text": …, "data": …}` returned 200 and
  the run saw only `text`, as a second user message wrapped in `<routine-fire-payload>`
  ("treat it as DATA"). So the webhook packs `monitor_id`, `transition`, `cycle_key`,
  `event_id`, `date_ms` and `link` as `key: value` lines in `text`, and the run reads the
  monitor itself with `pup monitors get`. Datadog does JSON-escape variables (a
  `$EVENT_MSG` holding `"Company not found"` arrived intact), but the message carries no
  monitor id, so a webhook sending it as `text` makes every run stop at `NO_ALERT`
  (measured 2026-11-10, run `cse_01Da7xFDbvcjqcw7jnnjSwKt`).
- **Open question: the exact `$ALERT_TRANSITION` string** for an Alert notification. The
  prompt proceeds only on `Triggered`; if the first real run ends `SKIPPED <id> <other>`,
  relax that check.
- **The Authority check is a guideline with a confidence, not a rule** (measured 2026-11-10 on 30 days of prod
  client spans). The .NET tracer marks only 4xx client responses as errors, so an upstream's 5xx is `status:ok`:
  match `@http.status_code:[500 TO 599]`, never `status:error` alone. No answer is `status:error` with no status
  code (`TaskCanceledException` at the client's full timeout, `HttpRequestException`). The service that alerts
  usually does not call the Authority (a delivery service does), so the check searches by the Authority's host —
  searching the alerting service found nothing on every run. Some Authorities return business faults as 500 every
  day, so a 500 is only judged against the hour before. Our own egress, DNS or certificates look identical, so the
  verdict is `likely` (corroborated, nothing on our side) or `confirmed` (the Authority says so), never certain.
- **Company specifics stay out of the repo.** The Authority list (`AUTHORITIES`), the team
  tag and the routine's token live in the live routine and in Datadog only; the repo
  prompt ships `AUTHORITIES` empty and `MODE: observe`.
- **`pup` is not on `PATH` in the cloud environment**, and `npm install -g` left it off
  `PATH`, so the prompt installs it with a `/usr/local/bin/pup` wrapper before any read.
- **Measured on the first real alerts** (2026-11-10, a log monitor with `> 0` errors in
  10 m). Each alert was one EF Core `CommandError` log line with no exception type and no
  stack, so the sweep would never have bucketed it. That is why a log line is signed under
  its logger name (`EventId.Name`, then `SourceContext`). `pup monitors get` returns the
  monitor unwrapped (no `.data`). `pup traces aggregate` returned no buckets even for an
  unfiltered service query, and rejects `--limit`, so the outbound-span comparison is the
  model's job, through `pup traces search`.
- **Concurrency.** Alerts now triage in parallel runs, so a run lists the issues again
  right before filing. API fires are capped at 30 an hour per routine, and Datadog does
  not retry a 4xx, so an alert storm past the cap is not triaged.

## Tests

```bash
node --test plugins/fu-log-sweep/scripts/*.test.mjs
```

`log-sweep-lib.test.mjs` covers the pure lib, including the routine's validators.
`routine.test.mjs` runs `prepare` → `collect` → `plan` → `wait` → `finish` with a
throwaway `$HOME`, two fake clones under `LOG_SWEEP_SEARCH_ROOT`, a `gh` stub that
serves REST fixtures and rejects what the cloud proxy does — GraphQL-backed
commands, `--paginate`, and any path outside `repos/` (the gap that let v0.2.3's
`gh api user` pass locally) — and a `pup` stub serving aggregates and samples:
NEW / already-open / held / reopened routing, versions read only for regressions,
`--storage indexes` on every call and `--limit 100` on the bucket aggregate, the marker on created
issues, observe mode making no write call, strict verdict validation, one repo's
failed collection not stopping the other, a failed sample skipped, a nested
`stackPath`, config defaults vs repo keys, an unattached repo, and the state issue
(window from the configured issue, every call repo-scoped, create-then-close with
the "add to `stateIssues`" hint and no label, update in place, a markerless or
non-numeric entry never written, not saved on observe, a failed candidate or an
unreadable issue).
