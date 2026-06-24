# et-sweep — Datadog Error Tracking → GitHub issues

User-level Claude Code tool. Watches a service's Datadog Error Tracking, files
de-duped GitHub issues with drafted root-cause writeups, and reopens regressions.
Generic: the service, env, and target repo are arguments.

## Requirements

- The `pup` Datadog CLI on PATH and authenticated (`pup auth login`; re-auth on a
  `401`). All Error Tracking reads go through `pup` — no MCP server. See the
  `datadog-pup` skill for the CLI.
- `gh` CLI authenticated for the target repo.
- Node (uses the built-in `node:test` runner; no npm install).
- Run it in a live Claude Code session (so `pup`/`gh` auth is available).

## Usage

```
/et-sweep [--observe|--live|--baseline] [--service NAME] [--env ENV] [--repo OWNER/NAME] [--count N]
```

Defaults: `--observe`, `--service entityplatform-api`, `--env prod`,
`--repo InfoTrackGlobal/EntityPlatform`, `--count 1`.

- `--observe` (default) — prints what it WOULD file; files nothing. Use this to
  calibrate noise and the count threshold.
- `--live` — files new issues and reopens regressions for real.
- `--baseline` — one-time: records existing issues as known stubs (label
  `et-baseline`) without writeups, so the first live run does not flood.

## Self-paced watch

`/loop /et-sweep --live` — self-paces ~daily, shortening when a tick files
something and lengthening when quiet.

## How de-dup works

Each filed issue carries a hidden marker `<!-- dd-et-issue: <id> -->` and the
`datadog-error-tracking` label. Before filing, the sweep searches all GitHub
issues for the Datadog `issue_id`: an open match is skipped, a closed match is
reopened + commented. One Datadog issue maps to at most one GitHub issue, ever.

## Pieces

- `~/.claude/commands/et-sweep.md` — the per-tick orchestrator (stays context-thin).
- `~/.claude/agents/et-triage-gate.md` — metadata-only noise filter (no tools).
- `~/.claude/agents/et-investigator.md` — deep-dive + file/reopen (token-isolated;
  its big context never returns to the loop).
- `~/.claude/scripts/et-sweep/sweep-lib.mjs` (+ `sweep-lib.test.mjs`) — pure
  window/filter/dedup/title/marker logic, unit-tested.
- `~/.claude/scripts/et-sweep/sweep.mjs` — thin CLI the command shells out to.
- State: `~/.claude/et-sweep-state-<service>-<env>.json` (per service+env).

## Token / context design

The loop holds only the capped search list, candidate tags, and one-line receipts.
A metadata-only triage gate drops noise before the expensive investigator runs;
the investigator's stack traces / sample events / source reads stay in its own
subagent context and never accumulate in the loop. See `DESIGN.md`.

## Tests

```
node --test ~/.claude/scripts/et-sweep/sweep-lib.test.mjs
```

Design + plan: `DESIGN.md`, `PLAN.md` in this directory.
