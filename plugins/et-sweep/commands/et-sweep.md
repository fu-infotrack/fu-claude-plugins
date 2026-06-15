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
- RESOLVED = `node "$LIB" resolve '<cli-override-json>'` → `{services, env, repo, mcpName, issueUrlBase, query}`. `services`/`repo` auto-detect (k8_settings app_name / git remote) unless overridden; `env` defaults to prod.
- REPO = RESOLVED.repo; QUERY = RESOLVED.query (spans ALL monitored services in one search); ISSUE_URL_BASE = RESOLVED.issueUrlBase.
- KEY = REPO with every non-alphanumeric char replaced by "-"; STATE_FILE = "$HOME/.claude/et-sweep-state-<KEY>.json" (holds {last_successful_tick, baseline_done} in epoch ms; one file per repo since a sweep spans all its services).

If REPO is empty (no GitHub remote and no --repo/config), STOP and report: cannot file issues without a target repo.

Procedure:

1. Read state: `cat "$STATE_FILE" 2>/dev/null`. Parse {last_successful_tick, baseline_done}. Missing/empty file = first run (last_successful_tick = null, baseline_done = false).

2. Compute window: `node "$LIB" window <last_successful_tick|null>`. Capture startMs, startIso, nowMs.

3. Search: mcp__au-datadog-mcp__search_datadog_error_tracking_issues with query=QUERY, from=startIso, to="now", order_by="TOTAL_COUNT", max_tokens=8000. One call covers every monitored service. If the result is truncated, remember remaining_items for the summary.

4. Map each returned issue to {issueId, service, errorType, errorMessage, firstSeenIso, isRegression, totalCount, firstSeenVersion, lastSeenIso, lastSeenVersion, functionName, platform, datadogUrl}. Then filter: `node "$LIB" filter-batch '<issuesJson>' <startMs> <threshold>`. Survivors = the printed array. (BASELINE mode: skip filtering — take all issues in the window with totalCount >= threshold.)

5. Dedup each survivor: `gh issue list --repo "$REPO" --state all --search "<issueId>" --json number,state,title` then `node "$LIB" classify '<matchesJson>'` (map gh state values to OPEN/CLOSED). Drop survivors classified ALREADY_OPEN. Sort the rest by totalCount desc; if more than 10, keep the top 10 and record "dropped <k> over cap".

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
