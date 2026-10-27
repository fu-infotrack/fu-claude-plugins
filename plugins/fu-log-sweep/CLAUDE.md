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
