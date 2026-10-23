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
- **Stateless**: the window is the 24 h floor of `windowStartMs`, since a sandbox keeps
  no state file. Daily schedule; no baseline mode (run `--baseline` locally once).
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
issues, observe mode making no write call, and strict verdict and bucket validation.
