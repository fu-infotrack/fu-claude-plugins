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

The same sweep as a daily Claude Code routine. A routine installs no plugin and has no
`pup` or keychain; its only Datadog access is the **Datadog MCP connector**, which only a
model can call. That fixes the split:

- **Agents do what needs Datadog or judgement.** A collector (`routine-collector.md`) runs
  one DDSQL query through `analyze_datadog_logs` — `GROUP BY` exception type, service,
  `version`, so bucket counts and the release gate's per-version counts come from one
  call — then one `search_datadog_logs` sample per bucket, and writes `buckets.json`. One
  investigator per candidate (`routine-investigator.md`) does the triage-gate's judgement
  and the writeup together and writes a verdict file. Neither touches GitHub's write API.
- **`scripts/routine.mjs` does everything else**: config (via `sweep.mjs resolve`), the
  issue index, signatures, dedup, the release gate, the caps, and filing. Each step prints
  a status token first and the agent prompts after it, so the Haiku orchestrator copies
  and never reads data. The handoff is on disk in `~/.claude/log-sweep/routine/`.
- **GitHub is REST with explicit pages**, for the reasons `fu-review-prs/CLAUDE.md` gives
  (GraphQL 403s; the proxy rejects `--paginate`'s numeric-ID links). Dedup lists the
  `datadog-logs`-labelled issues and reads their markers rather than using issue search:
  no index lag, and `closed_at` comes with the listing, so the gate needs no extra call.
  `/log-sweep` searches all issues, so an issue that lost its label dedups locally but
  not in the routine.
- **State lives in a bot issue in the target repo.** A sandbox keeps no file between
  runs, and a run is told nothing about earlier runs (the docs give it only the prompt,
  a fire payload, the clones, env vars and connectors; the routines API that lists runs
  needs the user's claude.ai login, which a run lacks). So the end of the last completed
  sweep is a hidden `<!-- fu-log-sweep-state: {"last_successful_tick": ms} -->` marker in a
  closed issue in the target repo — the user's choice over one in this repo. It is found
  by **REST search on the marker**, not a label: GitHub search indexes HTML-comment text
  (measured: a `dd-log-sig` value that appears only inside the comment found its one
  issue), whereas a label must exist first and `POST issues` documents only that labels
  are "silently dropped" without push access — a dropped label would have orphaned the
  state issue and created a new one every run. Since anyone can open an issue quoting the
  marker, only issues **authored by the routine's own account** (`gh api user`) count.
  Search's index lag is irrelevant at a daily cadence: a run writes at its end and the
  next reads a day later.
  `prepare` feeds it to `windowStartMs` (the same 24 h floor / 30 d cap as the local state
  file), so a weekday schedule's Monday run covers the weekend and a failed run's window
  is swept again. It is saved only by a **live** run that completed with **no failed
  candidate** (`plan`'s `NO_WORK`, or `finish`); a retried window is safe because what the
  failed run did file dedups as already open. If the state listing fails, the run sweeps
  24 h and writes nothing, since a write would create a second state issue. No baseline
  mode in the routine (run `--baseline` locally once).
- **Signature parity is measured, not assumed.** The connector returns the stack as an
  indented YAML block; `parseFrames` trims each line, so the collector's verbatim copy
  hashes the same as pup's JSON string. Checked 2026-10-23 on a live bucket: the
  MCP-shaped sample matched an issue the pup-based `/log-sweep` had filed. The collector
  brief insists on a verbatim, whole stack because a reworded frame files a duplicate.
- **A nested stack attribute needs its parent in `extra_fields`.** `search_datadog_logs`
  returns nothing for `extra_fields: ["error.stack"]`; it takes `["error"]` and shows the
  object as `custom.error`. So `prepare` passes `STACK_FIELD` as the path under the
  event's attributes (`stackPath` minus `attributes.attributes.`) and the briefs ask for
  its first segment. v0.2.0 passed the last segment (`stack`), which would have dropped
  every `error.stack` service to message signatures and refiled its issues.
- **Measured in the cloud** (2026-10-23, Compliance.Mono, observe): the routine's
  sub-agents do get its MCP connectors, and all 4 buckets dedup'd against issues the
  local sweep had filed.

## Tests

```bash
node --test plugins/fu-log-sweep/scripts/*.test.mjs
```

`log-sweep-lib.test.mjs` covers the pure lib, including the routine's validators.
`routine.test.mjs` runs `prepare` → `plan` → `finish` with a throwaway `$HOME`, a fake
target clone, and a `gh` stub that serves REST fixtures and rejects GraphQL-backed commands
and `--paginate`: NEW / already-open / held / reopened routing, the marker on created
issues, observe mode making no write call, strict verdict and bucket validation, and the
state issue (window from it, another author's marker ignored, create-then-close with no
label, update in place, not saved on observe, a failed collector, a failed candidate or
an unreadable search).
