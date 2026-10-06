# fu-log-sweep — design summary + issue templates

Sweeps a service's Datadog **error-level Logs** (`status:error`) into de-duped
GitHub issues. Unlike Error Tracking, logs are not pre-grouped, so the sweep
computes its own stable **signature** per distinct error and dedups on it.

**Signature (dedup key):** `sha1(errorKind | service | topAppFrame)` truncated to
12 hex chars. Top app frame = first stack frame under the configured
`app_namespace` (BCL/framework frames skipped), normalized (async/lambda
unwrapped, generic arity dropped). Fallback ladder: no app frame → first non-BCL
frame; no stack → normalized message.

## GitHub issue format

**Title:** `[Datadog] <errorKind>: <topFrame | message truncated ~80 chars>`

**Labels:** `datadog-logs`, `auto-filed`, `sev:low|med|high`. Baseline run also
adds `log-baseline`.

**Body** (no `#` headers — bold labels, per repo prose convention):

```markdown
<!-- dd-log-sig: <sig> -->

**Datadog:** <Logs Explorer URL for this query+window>

**Error**
- Type: `<errorKind>`
- Message: <errorMessage>
- Service: `<service>` · env `<env>`
- Failing frame: `<topFrame>`   (or "unresolved — signature via <confidence>")

**Occurrence**
- Count (window): <count>
- Last seen: <last-seen ISO from newest sample>
- First seen: not tracked for log-sourced errors — window ≥ <window start ISO>

**Suspected root cause** *(drafted, verify before acting)*
<LLM writeup — 1-3 short paras: what throws, why, the traced code path>

**Suspected code location**
- `<path>:<line>` (codegraph trace, when source is indexed this session)

**Recent changes to `<path>`** *(suspects, not cause — default-branch history, not the deployed build)*
- `<short-sha>` <date> <author-login> — <commit subject> (#<pr>)

---
*Auto-filed by /log-sweep. Regressions reopen this issue rather than filing a
new one. The root-cause section is a draft, not a verdict.*
```

## Regression comment (when reopening a closed issue)

```markdown
**Regressed** — recurred after close.
- Seen again: <last-seen ISO>
- Count this window: <count>
- Datadog: <Logs Explorer URL>
<one-line note if the suspected root cause shifted vs the original>

**Changed since close** *(prime suspects)*
- `<short-sha>` <date> <author-login> — <commit subject> (#<pr>)
```

## Recent changes (author context)

Both sections above list commits touching the suspected file so a reader can see
who has context — they are **context, not attribution**:

- **Never `@`-mention, never assign.** Author logins are written bare (no `@`),
  so GitHub sends no notification. The suspected location is a draft and the last
  toucher of a line is often a reformat or rename, so a ping would routinely land
  on the wrong person.
- **Only with a real location.** Emitted only when the investigator resolved a
  repo-relative `path` and `confidence` is `app-frame`; otherwise the section is
  omitted entirely (no empty heading).
- **Source:** `gh api repos/<repo>/commits?path=<path>&until=<lastSeen>`, which
  needs no local checkout. Body: last 3–5 commits. Regression comment: commits
  with `since=<issue closedAt>`; omit the section if there are none.
- Bot authors (`[bot]` suffix, `type: Bot`) are skipped. The PR number comes from
  `repos/<repo>/commits/<sha>/pulls` when one exists.
- History is the default branch, not the deployed build — hence "suspects".
