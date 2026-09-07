# fu-et-sweep — CLAUDE.md

Read this before changing anything under `plugins/fu-et-sweep/`. Repo-wide rules — worktrees,
the install cache, the `fu-tools` config contract, the three registries, and the full
external-dependency list — live in the root `CLAUDE.md`.

## Design

- **Token/context discipline** (et-sweep): the orchestrating command stays context-thin; expensive work (stack traces, source reads) is isolated inside subagents whose context never returns to the loop. A metadata-only triage gate drops noise before the investigator runs. See `plugins/fu-et-sweep/docs/DESIGN.md`.

`fu-et-sweep` reads Datadog Error Tracking through the **`pup` CLI** (run via Bash; see the `fu-pup` skill) — **no bundled MCP server** as of v0.2.0 — plus the `gh` CLI authenticated for the target repo. Run it in a live session so `pup auth login` / `gh` auth is available (a `401` needs an interactive re-login). Key design wrinkle: `pup`'s ET `issues search` is a **thin projection (id + total_count only)**, so the orchestrator count-prunes then **gh-dedups first** to bound the set to ≤10, and only then hydrates each survivor via `pup error-tracking issues get` for the rich fields. **Regression is derived from a closed GitHub match** (GH is the sole regression authority — `pup` has no Datadog regression flag). The investigator pulls a sample stack via `pup traces/logs search '@issue.id:<id>'` (replacing the old `analyze_*` MCP tool). The pure-logic `sweep-lib.mjs` is shape-agnostic and was untouched by the cutover.

## Tests

`sweep-lib.mjs` is the pure, dependency-free core; keep date/time and network out of it.

```bash
node --test plugins/fu-et-sweep/scripts/sweep-lib.test.mjs
```
