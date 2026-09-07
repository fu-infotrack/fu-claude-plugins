# fu-log-sweep — CLAUDE.md

Read this before changing anything under `plugins/fu-log-sweep/`. Repo-wide rules — worktrees,
the install cache, the `fu-tools` config contract, the three registries, and the full
external-dependency list — live in the root `CLAUDE.md`.

## Design

Sibling to `fu-et-sweep` — same orchestrator/triage-gate/investigator shape, same
token discipline (expensive work stays inside sub-agents whose context never returns),
same GitHub-is-the-regression-authority rule. See `plugins/fu-et-sweep/CLAUDE.md` for
that shared design and `docs/DESIGN.md` here for what differs.

The one substantive difference: there is no Datadog-supplied `issue_id` to dedup on, so
this plugin computes its own error signature — `sha1(type|service|top-app-frame)` — and
dedups GitHub issues against that. Change the signature inputs and every previously
filed issue stops matching, so treat it as a wire format.

## Tests

No suite yet.
