# fu-log-sweep

One tick of a self-paced sweep: a service's Datadog **error-level Logs**
(`status:error`) → de-duped GitHub issues with drafted root-cause writeups,
deduping on a **computed signature** (`type | service | top-app-frame` sha1)
rather than an Error Tracking `issue_id`.

## Requirements (on PATH, authenticated in a live session)

- `pup` — the Datadog CLI (`pup auth login`; a `401` needs re-login).
- `gh` — authenticated for the target repo.
- `node` — runs the bundled `scripts/` and the `node --test` suite.

## Usage

```
/log-sweep --observe            # dry run: prints the candidate table, files nothing
/log-sweep                      # live: files/reopens GitHub issues
/log-sweep --baseline           # one-time: record existing signatures as known stubs
/loop 24h /log-sweep            # self-paced watch
```

Flags: `--service <a,b>`, `--env <env>`, `--repo <owner/name>`, `--count N`
override the config-resolved defaults.

## Config (`fu-tools`, tool key `log-sweep`)

`services` (auto from k8_settings `app_name`), `env` (prod), `repo` (auto from
git remote), `count_threshold` (1), `app_namespace` (stack-frame app prefix, e.g.
`["Acme"]`), `status_query` (`status:error`), `logs_url_base` (Logs Explorer URL
prefix for the issue link), `version_tag` (Datadog tag with the deployed build, `version`; closed issues reopen only if the error recurs on a build released after the close).

## Cloud routine

The same sweep as one daily Claude Code routine over a list of repos, in the
DB perf sweep's shape: no plugin, Datadog through `pup` (npm-installed,
`DD_ACCESS_TOKEN`), filing through GitHub REST.
Setup and the prompt to paste are in [`routines/log-sweep.md`](routines/log-sweep.md).

## Alert triage (`alert-watch` → cloud routine)

Triages Datadog **monitor alerts** as they fire. A Power Automate flow copies
each Datadog → Teams alert message (a Microsoft Graph channel message, JSON)
into a OneDrive folder. `alert-watch`, a systemd user service, polls that
folder and runs `alert-triage.mjs fire` on each file. That step reads no
Datadog and starts no local session; it only sorts:

| `[state]` in the summary | What happens |
|---|---|
| `Triggered`, `Re-Triggered` | POSTed to the triage routine's `/fire` endpoint, then archived |
| `Recovered`, `Warn`, `No Data` | archived |
| out of scope, older than `max_age_hours`, unparseable | archived |

Archiving moves the JSON to `processed/` next to `inbox/`. That move is what
stops an alert being sent twice. The note `<id>.md` beside it links the
routine's session. A 429, a 5xx or a network error leaves the alert in the
inbox for the next poll. Any other refusal counts as an attempt, and after 3
the alert is archived with a "Not sent" note.

The fire payload is `{"text": …}`: the alert's ids, state, title, monitor,
alert window and the Teams team/channel/message ids, as a JSON block. The
routine gets everything it needs from that, so it never has to search OneDrive.

The routine's bearer token is read from `$ALERT_TRIAGE_FIRE_TOKEN`. The watcher
loads it from `~/.claude/alert-triage/env` (`KEY=value` lines). Create that
file yourself and `chmod 600` it; nothing in this plugin writes it.

```bash
ALERT_TRIAGE_DRY_RUN=1 bash plugins/fu-log-sweep/scripts/alert-watch --once   # nothing moved, nothing sent
bash ~/.claude/plugins/cache/fu-claude-plugins/fu-log-sweep/<version>/scripts/alert-watch install
loginctl enable-linger "$USER"
tail -f ~/.claude/alert-triage/log
```

`install` copies the watcher to `~/.claude/alert-triage/` and enables
`fu-alert-watch.service`. The plugin cache path changes with every version, so
the unit can't point there. The watcher instead finds the newest installed
scripts on each poll, so you only need to reinstall when `alert-watch` itself
changes. The unit's `PATH` holds `node`'s resolved directory, not a shell's
per-session fnm link.

Config is the `fu-tools` tool key `alert-triage` (user config):

| Key | Default | Meaning |
|---|---|---|
| `inbox` | — (required) | the folder the flow writes to; `processed/` is its sibling |
| `fire_url` | — (required) | the routine's `…/routines/<trig_id>/fire` URL |
| `monitors` | all | monitor ids in scope; others are archived untouched |
| `max_age_hours` | `24` | older alerts (a backlog after downtime) are archived unsent |

### Local triage (manual)

The 0.4.0 local triage is still there for a run by hand:
`alert-triage.mjs handle <file>` writes `<id>.facts.json` (monitor via `pup`,
error logs signed with log-sweep's `buildSignature`, matched against the repo's
`datadog-logs` issues through the release gate), then
`claude -p "/fu-log-sweep:alert-triage <facts>"` judges it (link, reopen or file,
and whether an upstream Authority is down), and `alert-triage.mjs finish`
validates the verdict, notifies (`toast`, `teams_webhook`) and archives. Its
keys: `repo_root`, `mode`, `teams_webhook`, `authority_prompt`, `toast`, `model`.

## Tests

```
node --test plugins/fu-log-sweep/scripts/*.test.mjs
```
