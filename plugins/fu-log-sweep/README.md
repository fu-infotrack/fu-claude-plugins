# fu-log-sweep

One tick of a self-paced sweep: a service's Datadog **error-level Logs**
(`status:error`) → de-duped GitHub issues with drafted root-cause writeups.
Sibling to `fu-et-sweep`; the difference is the source (raw Logs, not Error
Tracking) and therefore the dedup key — a **computed signature**
(`type | service | top-app-frame` sha1) instead of an ET `issue_id`.

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
prefix for the issue link).

## Tests

```
node --test plugins/fu-log-sweep/scripts/log-sweep-lib.test.mjs
```
