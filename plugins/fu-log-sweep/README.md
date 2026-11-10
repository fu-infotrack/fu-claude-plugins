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

Triages Datadog **monitor alerts** as they fire. The judgement runs in a cloud routine; its setup and prompt are in [`routines/alert-triage.md`](routines/alert-triage.md). A Power Automate flow copies
each Datadog → Teams alert message (a Microsoft Graph channel message, JSON)
into `<folder>/inbox/` in OneDrive. `alert-watch`, a systemd user service,
polls that folder and runs `alert-triage.mjs dispatch`, which reads no file:

```text
<folder>/inbox/        the flow writes here
   │  alert-watch: move every *.json, then POST their names in one batch
   ▼
<folder>/processing/   owned by the routine run it was sent to
   │  routine (M365 connector): read, skip or triage, move
   ▼
<folder>/processed/    archive; alert-watch keeps the newest 100 records
```

The fire payload is `{"text": "{\"folder\":…,\"processing\":\"processing\",\"processed\":\"processed\",\"files\":[…]}"}`.
Which files are alerts, which are stale, and how to read Datadog's card are all
the routine's call, so a change to the card never breaks the watcher. The move
to `processing/` is the claim: a later poll can't send a file twice, and two
runs never get the same file. If the routine doesn't accept the batch (any
non-2xx or a network error), the files go back to `inbox/` for the next poll.
A file stays in `processing/` if its run dies before moving it; look there
when a run failed.

The routine's bearer token is read from `$ALERT_TRIAGE_FIRE_TOKEN`. The watcher
loads it from `~/.claude/alert-triage/env` (`KEY=value` lines). Create that
file yourself and `chmod 600` it; nothing in this plugin writes it.

```bash
ALERT_TRIAGE_DRY_RUN=1 bash plugins/fu-log-sweep/scripts/alert-watch --once   # prints the batch; nothing moved, nothing sent
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
| `inbox` | — (required) | the folder the flow writes to; `processing/` and `processed/` are its siblings, and the parent's name is the batch's `folder` |
| `fire_url` | — (required) | the routine's `…/routines/<trig_id>/fire` URL |
| `keep_processed` | `100` | records kept in `processed/` (a record is every file sharing an id) |

### Local triage (manual)

The 0.4.0 local triage is still there for a run by hand:
`alert-triage.mjs handle <file>` writes `<id>.facts.json` (monitor via `pup`,
error logs signed with log-sweep's `buildSignature`, matched against the repo's
`datadog-logs` issues through the release gate), then
`claude -p "/fu-log-sweep:alert-triage <facts>"` judges it (link, reopen or file,
and whether an upstream Authority is down), and `alert-triage.mjs finish`
validates the verdict, notifies (`toast`, `teams_webhook`) and archives. Its
keys: `monitors`, `repo_root`, `mode`, `max_age_hours`, `teams_webhook`, `authority_prompt`, `toast`, `model`.

## Tests

```
node --test plugins/fu-log-sweep/scripts/*.test.mjs
```
