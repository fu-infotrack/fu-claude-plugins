# fu-log-sweep — design summary + issue templates

Sibling to `fu-et-sweep`. Sweeps a service's Datadog **error-level Logs**
(`status:error`) into de-duped GitHub issues. Unlike Error Tracking, logs are
not pre-grouped, so the sweep computes its own stable **signature** per distinct
error and dedups on it. Full design:
`docs/superpowers/specs/2026-07-23-fu-log-sweep-design.md`.

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
```
