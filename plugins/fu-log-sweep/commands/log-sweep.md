---
description: One tick of a Datadog error-Logs sweep -> de-duped GitHub issues with drafted root-cause writeups. Run via /loop for a self-paced watch.
---

You are running ONE tick of the log-error sweep. Keep YOUR context tiny: never read stack traces or draft writeups yourself — that is the log-investigator subagent's job. You only orchestrate.

Arguments: $ARGUMENTS
- mode: "--observe" (default), "--live", or "--baseline".
- "--service <a,b>" optional override of monitored services (comma-separated). Default: ALL services auto-detected from the repo.
- "--env <env>" optional. Default: prod.
- "--repo <owner/name>" optional override of the target GitHub repo. Default: auto-detected from the git remote.
- "--count N" overrides the count threshold (default: 1).

Derived:
- LIB = "${CLAUDE_PLUGIN_ROOT}/scripts/sweep.mjs". If that path does not exist (variable not expanded), set LIB to the first match of `find "$HOME/.claude" -path '*plugins/fu-log-sweep/scripts/sweep.mjs' 2>/dev/null | head -1`.
- Build a CLI-override JSON from any flags given: `{ "services": [...from --service], "env": "...", "repo": "..." }` (omit keys not passed).
- RESOLVED = `node "$LIB" resolve '<cli-override-json>'` → `{services, env, repo, statusQuery, appNamespace, query, logsUrlBase}`. `services`/`repo` auto-detect (k8_settings app_name / git remote) unless overridden; `env` defaults to prod.
- REPO = RESOLVED.repo; QUERY = RESOLVED.query (spans ALL monitored services in one search); APPNS = RESOLVED.appNamespace (JSON array); LOGS_URL_BASE = RESOLVED.logsUrlBase; ENV = RESOLVED.env.
- ERRORFACET = RESOLVED.errorFacet (Datadog facet the exception TYPE is indexed under; default `@Properties.exception.type` for the C#/Serilog stack — the generic `@error.kind`/`@error.stack` facets are usually EMPTY). STACKPATH = RESOLVED.stackPath (dotted path to the full stack on a log event; default `attributes.attributes.Exception`). MSGPATH = RESOLVED.messagePath (default `attributes.message`). All three overridable via config for other log shapes.
- KEY = REPO with every non-alphanumeric char replaced by "-"; STATE_FILE = "$HOME/.claude/log-sweep-state-<KEY>.json" (holds {last_successful_tick, baseline_done} in epoch ms; one file per repo).

Datadog access is the `pup` CLI (see the `datadog-pup` skill) — not an MCP server. All log reads run through `pup` via Bash. If `pup auth status` shows no valid token, STOP and report: run `pup auth login` first (re-auth also needed on a `401`). `pup` wraps responses as `{status,data,metadata}` — read the payload under `.data`.

If REPO is empty (no GitHub remote and no --repo/config), STOP and report: cannot file issues without a target repo.

Procedure:

1. Read state: `cat "$STATE_FILE" 2>/dev/null`. Parse {last_successful_tick, baseline_done}. Missing/empty = first run (last_successful_tick = null, baseline_done = false).

2. Compute window: `node "$LIB" window <last_successful_tick|null>`. Capture startMs, startIso, nowMs.

3. Aggregate (one call, all services, Datadog groups server-side): `pup logs aggregate --query "$QUERY" --from "<startIso>" --to now --compute count --group-by "<ERRORFACET>,service"`. NOTE the group-by dimensions are ONE comma-separated flag — `pup` rejects a repeated `--group-by`. Read `.data.buckets`; each bucket's `by` has keys `<ERRORFACET>` and `service`, count under `computes.c0`. Build `[{errorKind, service, count}]`. **If buckets come back empty but a plain `--group-by service` shows counts, the exception-type facet name is wrong for this index** — pull one sample (`pup logs search ... --limit 1 --no-agent`), inspect its attributes for where the exception type lives, set `errorFacet` in config accordingly, and re-run. (Events with no exception-type attribute are simply not bucketed — expected; note the unclassified remainder in the summary.)

4. Prune + cap buckets (no samples yet):
   - Count-prune: drop buckets with `count < threshold`.
   - Sort by `count` desc; if more than 20, keep the top 20 and record "dropped <k> buckets over pre-sample cap".

5. Per surviving bucket, fetch ONE sample + compute the signature. **Throttle: space these `pup logs search` calls out (~3-4s apart) and do them SEQUENTIALLY, not in a burst — firing all buckets at once trips Datadog's `429 Too many requests`. On a 429, back off a few seconds and retry (a few tries, exponential). A driver script that loops with a sleep between calls is the reliable way; the signature step needs the stack, so pass it via argv (execFileSync) rather than shell-interpolating a multi-line stack.**
   - BUCKET_Q = `service:<service> env:<ENV> status:error <ERRORFACET>:"<errorKind>"` (single-quote the whole `--query` — errorKind may contain backticks/brackets for generic types like `` ApiException`1[...] ``).
   - `pup logs search --query '<BUCKET_Q>' --from "<startIso>" --to now --limit 1 --no-agent` (newest). Read the stack from `<STACKPATH>`, the message from `<MSGPATH>` (rendered) or `attributes.attributes.MessageTemplate` (template), and the event timestamp (`attributes.timestamp` → lastSeenIso).
   - `node "$LIB" signature '{"errorKind":"<errorKind>","service":"<service>","stack":"<stack>","message":"<message>","appNamespace":<APPNS>}'` → `{sig, frame, confidence}`.
   - Carry `{sig, errorKind, service, count, frame, confidence, errorMessage, lastSeenIso}`.

6. Dedup classification (regression authority): for each bucket, `gh issue list --repo "$REPO" --state all --search "<sig>" --json number,state,title` then `node "$LIB" classify '<matchesJson>'` (map gh state values to OPEN/CLOSED) → NEW / ALREADY_OPEN / REGRESSION. **Drop ALREADY_OPEN.** For REGRESSION keep the gh number. Sort survivors by `count` desc; if more than 10, keep the top 10 and record "dropped <k> over cap".

7. Triage gate (skipped in BASELINE mode): dispatch the `log-triage-gate` agent once per survivor, passing metadata + `service` + `frame` + `confidence`. Keep survivors whose result has actionable=true; remember each verdict + reason.

8. Mode handling:

   BASELINE mode: for each survivor classified NEW, create a stub: title via `node "$LIB" title '<errorKind>' '<frame or errorMessage>'`, marker via `node "$LIB" marker '<sig>'`, then `gh issue create --repo "$REPO" --title "<title>" --label datadog-logs,log-baseline --body "<marker>\n\n**Datadog:** <link or BUCKET_Q>"` (NO writeup). Leave REGRESSION/ALREADY_OPEN untouched. Set baseline_done=true. Skip the investigator.

   LIVE mode: for each actionable survivor, dispatch the `log-investigator` agent with {sig, errorKind, service, env: ENV, classification (+gh number if REGRESSION), mode:"live", repo: REPO, logsUrlBase: LOGS_URL_BASE, errorFacet: ERRORFACET, stackPath: STACKPATH, messagePath: MSGPATH, metadata:{errorMessage, count, lastSeenIso, windowStartIso: startIso, topFrame: frame, confidence}}. Collect the one-line receipts. The investigator creates/reopens the issue itself. To avoid Datadog `429`s, dispatch in small batches (~3-4 at a time) rather than all survivors at once.

   OBSERVE mode: do NOT dispatch the investigator and do NOT touch GitHub. Print a table: sig (short) | service | error_kind | count | frame | confidence | classification | triage (actionable + reason) | would-be-action (create / reopen #N / drop-noise).

9. State write: if the tick COMPLETED (even with per-candidate skips) AND mode is not observe, write `echo '{"last_successful_tick": <nowMs>, "baseline_done": <bool>}' > "$STATE_FILE"`. Do NOT write state if the tick aborted before aggregate returned, and never in observe mode.

10. Summary line: counts {buckets, pruned, deduped, actionable, filed/observed, dropped-over-cap} and the list of services monitored.

Resilience:
- Wrap each per-bucket operation so one failing bucket (aggregate/search/signature/gh/subagent error) is logged with its errorKind+service and skipped — never abort the whole tick.
- Pre-sample bucket cap is 20; per-tick survivor cap is 10 (top by count); always log the dropped count, never truncate silently.

Self-pace (only when invoked under /loop):
- After the summary, schedule the next wake ~24h out. Shorten toward a few hours if this tick filed anything (active period); lengthen when quiet. The runtime clamps the delay.

Never circumvent a blocked tool call (e.g. a commit hook) by injecting bypass tokens — report the blocker instead.
