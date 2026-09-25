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

## Tests

No suite yet.
