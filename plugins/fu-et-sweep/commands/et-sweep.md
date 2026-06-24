---
description: One sweep of a project's services' Datadog Error Tracking -> de-duped GitHub issues with drafted root-cause writeups. Run via /loop for a self-paced watch.
---

You are running ONE tick of the Error Tracking sweep. Keep YOUR context tiny: never read stack traces or draft writeups yourself — that is the et-investigator subagent's job. You only orchestrate.

Arguments: $ARGUMENTS
- mode: "--observe" (default), "--live", or "--baseline".
- "--service <a,b>" optional override of the monitored services (comma-separated). Default: ALL services auto-detected from the repo.
- "--env <env>" optional. Default: prod.
- "--repo <owner/name>" optional override of the target GitHub repo. Default: auto-detected from the git remote.
- "--count N" overrides the count threshold (default: 1).

Derived:
- LIB = "${CLAUDE_PLUGIN_ROOT}/scripts/sweep.mjs". If that path does not exist (variable not expanded), set LIB to the first match of `find "$HOME/.claude" -path '*plugins/et-sweep/scripts/sweep.mjs' 2>/dev/null | head -1`.
- Build a CLI-override JSON from any flags given: `{ "services": [...from --service], "env": "...", "repo": "..." }` (omit keys not passed).
- RESOLVED = `node "$LIB" resolve '<cli-override-json>'` → `{services, env, repo, issueUrlBase, query}`. `services`/`repo` auto-detect (k8_settings app_name / git remote) unless overridden; `env` defaults to prod.
- REPO = RESOLVED.repo; QUERY = RESOLVED.query (spans ALL monitored services in one search); ISSUE_URL_BASE = RESOLVED.issueUrlBase.
- KEY = REPO with every non-alphanumeric char replaced by "-"; STATE_FILE = "$HOME/.claude/et-sweep-state-<KEY>.json" (holds {last_successful_tick, baseline_done} in epoch ms; one file per repo since a sweep spans all its services).

Datadog access is the `pup` CLI (see the `datadog-pup` skill) — not an MCP server. All Error Tracking reads run through `pup` via Bash. If `pup auth status` shows no valid token, STOP and report: run `pup auth login` first (a re-auth is also needed on a `401`). `pup` auto-detects agent mode and wraps responses as `{status,data,metadata}` — read the payload under `.data`; for one-off `--jq` extraction, the ET search payload is a bare array (`.[]`).

If REPO is empty (no GitHub remote and no --repo/config), STOP and report: cannot file issues without a target repo.

Procedure:

1. Read state: `cat "$STATE_FILE" 2>/dev/null`. Parse {last_successful_tick, baseline_done}. Missing/empty file = first run (last_successful_tick = null, baseline_done = false).

2. Compute window: `node "$LIB" window <last_successful_tick|null>`. Capture startMs, startIso, nowMs.

3. Search (one call, all services): `pup error-tracking issues search --query "$QUERY" --track trace --from "<startIso>" --to now --order-by TOTAL_COUNT --limit 50`. `pup`'s ET search is a **thin projection** — each issue carries only its `id` and `total_count` (no first_seen/error_type/version). So the rich fields come from a `get` per survivor in step 5, not here. If you hit the `--limit`, record the count for the summary (raise `--limit` only if needed). Build a candidate list `[{issueId, totalCount}]`.

4. Prune + dedup + cap (no rich fields needed yet):
   - Count-prune: drop candidates with `totalCount < threshold`.
   - Dedup each remaining: `gh issue list --repo "$REPO" --state all --search "<issueId>" --json number,state,title` then `node "$LIB" classify '<matchesJson>'` (map gh state values to OPEN/CLOSED) → ALREADY_OPEN / NEW / REGRESSION. **Drop ALREADY_OPEN.** Set `isRegression = (classification == REGRESSION)` and keep the gh number for regressions. (This gh dedup — not a Datadog flag — is the regression authority now.)
   - Sort survivors by `totalCount` desc; if more than 10, keep the top 10 and record "dropped <k> over cap". This bounds the `get` calls in step 5 to ≤10.

5. Hydrate + recency filter: for each survivor (≤10), `pup error-tracking issues get "<issueId>"` and map `.data.attributes` to {issueId, service, errorType (error_type), errorMessage (error_message), firstSeenIso (from first_seen ms), isRegression (from step 4), totalCount, firstSeenVersion (first_seen_version), lastSeenIso, lastSeenVersion, functionName (function_name), platform, datadogUrl (`<ISSUE_URL_BASE><issueId>`)}. Then recency-filter: `node "$LIB" filter-batch '<hydratedJson>' <startMs> <threshold>` — survivors = the printed array (keeps issues first-seen in the window OR flagged regression). **BASELINE mode: skip the recency filter** — keep all hydrated candidates (count already pruned in step 4).

6. Triage gate (skipped in BASELINE mode): dispatch the `et-triage-gate` agent once per survivor, passing only the metadata + that issue's own `service`. Keep survivors whose result has actionable=true; remember each verdict + reason.

7. Mode handling:

   BASELINE mode: for each survivor classified NEW, create a stub: title via `node "$LIB" title '<errorType>' '<errorMessage>'`, marker via `node "$LIB" marker '<issueId>'`, then `gh issue create --repo "$REPO" --title "<title>" --label datadog-error-tracking,et-baseline --body "<marker>\n\n**Datadog:** <datadogUrl>"` (NO writeup). Leave REGRESSION/ALREADY_OPEN untouched. Set baseline_done=true. Skip the investigator.

   LIVE mode: for each actionable survivor, dispatch the `et-investigator` agent with {issue_id, service (the issue's own), classification (+gh number if REGRESSION), mode="live", repo=REPO, issueUrlBase=ISSUE_URL_BASE, metadata}. Collect the one-line receipts. The investigator creates/reopens the GitHub issue itself.

   OBSERVE mode: do NOT dispatch the investigator and do NOT touch GitHub (keeps token cost minimal). Print a table with columns: issue_id (short) | service | error_type | count | classification | triage (actionable + reason) | would-be-action (create / reopen #N / drop-noise).

8. State write: if the tick COMPLETED (even with per-candidate skips) AND mode is not observe, write `echo '{"last_successful_tick": <nowMs from step 2>, "baseline_done": <bool>}' > "$STATE_FILE"`. Do NOT write state if the tick aborted before search returned, and never in observe mode.

9. Summary line: counts {searched, candidates, deduped, actionable, filed/observed, dropped-over-cap, search-truncated-remaining} and the list of services monitored.

Resilience:
- Wrap each per-candidate operation so one failing issue (search/get/gh/subagent error) is logged with its issue_id and skipped — never abort the whole tick.
- Per-tick cap is 10 (top by total_count); always log the dropped count, never truncate silently.

Self-pace (only when invoked under /loop):
- After the summary, schedule the next wake ~24h out. Shorten toward a few hours if this tick filed anything (active period); lengthen when quiet. The runtime clamps the delay.

Never circumvent a blocked tool call (e.g. a commit hook) by injecting bypass tokens — report the blocker instead.
