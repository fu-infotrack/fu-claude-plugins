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

## Alert triage (`alert-watch` + `/alert-triage`)

Triages Datadog **monitor alerts** as they fire, against the same issues the
sweep files. A Power Automate flow copies each Datadog → Teams alert message
(a Microsoft Graph channel message, JSON) into a OneDrive folder. `alert-watch`,
a systemd user service, polls that folder and, for each file:

| `[state]` in the summary | What happens |
|---|---|
| `Triggered`, `Re-Triggered` | triaged (below), then archived |
| `Recovered` | a "Recovered at …" line is appended to the note of that monitor's latest trigger, then archived |
| `Warn`, `No Data` | archived |

Archiving moves the JSON to `processed/` next to `inbox/`. That move is what
stops an alert being handled twice. The note `<id>.md` is written beside it.

A triage runs in three steps:

1. **`alert-triage.mjs handle`** (deterministic) reads the monitor (`pup monitors
   get`), pulls the error logs for its query in the alert window, signs each
   error with log-sweep's `buildSignature`, and matches the signatures against
   the repo's `datadog-logs` issues. A closed issue goes through the sweep's
   release gate. It writes `<id>.facts.json`. The repo is the monitor's `repo:`
   tag, matched by name (case-insensitively) to a clone under `repo_root`. Its
   log shape and GitHub repo resolve as `/log-sweep`'s do, from the clone's
   `.claude/.fu-tools.json` and git remote.
2. **`claude -p "/fu-log-sweep:alert-triage <facts>"`** (judgement), a fresh
   headless session run from the clone:
   - an open issue is linked in the note;
   - a regression goes to the `log-investigator` agent, which reopens the issue;
   - a new error goes to `log-triage-gate`, then to the investigator, which
     files it;
   - an issue closed before its fix shipped is held.

   It also decides whether an upstream **Authority** is down, from the outbound
   spans (alert window against the hour before, and the last 10 minutes), other
   monitors that triggered within 15 minutes, and the error text. It writes the
   note and `<id>.verdict.json`.
3. **`alert-triage.mjs finish`** checks the verdict. Only an Authority-down
   verdict notifies, with a Windows toast and a reply on the alert's Teams
   message (`teams_webhook`). Then it archives the alert. When the verdict is
   missing it retries on the next poll, and archives the alert with a "Triage
   failed" note after 3 attempts.

A log line with no exception type, which the sweep never buckets, is signed
under its logger name (the EF Core `EventId`, or `SourceContext`). That gives it
one stable signature, and the alert files it.

```bash
ALERT_TRIAGE_DRY_RUN=1 bash plugins/fu-log-sweep/scripts/alert-watch --once   # observe: nothing moved, filed or sent
bash ~/.claude/plugins/cache/fu-claude-plugins/fu-log-sweep/<version>/scripts/alert-watch install
loginctl enable-linger "$USER"
tail -f ~/.claude/alert-triage/log
```

`install` copies the watcher to `~/.claude/alert-triage/` and enables
`fu-alert-watch.service`. The plugin cache path changes with every version, so
the unit can't point there. The watcher instead finds the newest installed
scripts on each poll, so you only need to reinstall when `alert-watch` itself
changes. Each headless run may use only `pup`, `gh`, `node`, `cat`, `jq`,
Read/Write/Grep/Glob and Agent (`--allowedTools`; in `-p` anything else is
refused, not prompted). Its output goes to
`~/.claude/alert-triage/run-<id>.log`.

Config is the `fu-tools` tool key `alert-triage` (user config):

| Key | Default | Meaning |
|---|---|---|
| `inbox` | — (required) | the folder the flow writes to; `processed/` is its sibling |
| `monitors` | all | monitor ids in scope; others are archived untouched |
| `repo_root` | `~/repo` | where the `repo:` tag's clone is looked up |
| `mode` | `live` | `observe`: the investigators touch nothing on GitHub |
| `teams_webhook` | none | Power Automate webhook that replies on the alert. It receives `{teamId, channelId, messageId, text}` (HTML); use the *Reply with a message in a channel* action. A credential, so `chmod 600` the config file |
| `authority_prompt` | none | free text naming the Authorities and their hosts, passed to the triage as-is |
| `toast` | `true` | Windows toast on an Authority-down verdict (`powershell.exe`, WSL) |
| `max_age_hours` | `24` | older alerts (a backlog after downtime) are archived untriaged |
| `model` | CLI default | model for the headless triage |

## Tests

```
node --test plugins/fu-log-sweep/scripts/*.test.mjs
```
