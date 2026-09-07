# fu-dev-guards — CLAUDE.md

Read this before changing anything under `plugins/fu-dev-guards/`. Repo-wide rules — worktrees,
the install cache, the `fu-tools` config contract, the three registries, and the full
external-dependency list — live in the root `CLAUDE.md`.

## Design

- **Matching a command in a Bash hook** — never `grep` the raw command string. `^\s*git\s+commit` only sees the FIRST token, so `git fetch && git commit` bypasses it; an unanchored `\bgit\s+commit\b` instead false-blocks the verb in quoted prose. All four git guards share `fu-dev-guards/src/hooks/lib/git-guard.sh`: `cmd_invokes "$cmd" 'git commit'` segments on **unquoted** boundaries, peels leading assignments/wrappers/`\`, and head-matches. The governing rule is **data is not a command** — quoted strings and heredoc bodies are inert, while `$( )`, backticks, and `sh -c` payloads are commands wherever they appear. Extend the tests in `test/git-guard.test.sh` when touching it.
- **Advisory hooks vs enforcement** — `stamp-session-sessionstart.sh` (v0.4.0) joins `notify-worktree-sessionstart.sh` as the plugin's **second advisory hook**: the PreToolUse guards are the enforcement, these two only inform. It hands the session its own `session_id` via `additionalContext` and asks for `<!-- claude-session: <uuid> -->` at the bottom of every PR body. Two reasons not to add a deny backstop, both measured against the raw-command rule above: finding the marker means grepping the **raw** command string (the marker is *data*, so `cmd_invokes` deliberately discards it along with the heredoc body it usually lives in), and a deny would fire in every drive-by repo that never heard of the convention. The cost of not enforcing is asymmetric and worth stating honestly — a missed stamp loses the trace **outright**, because the id you would search by is the thing that went missing; recovery means content-grepping every transcript under `~/.claude/projects`. Registered with **no matcher** so it re-fires on `clear`/`compact`/`resume` — load-bearing, since a compaction would otherwise leave every later PR in the session unstamped. Ungated (every session, every directory), unlike its siblings: the id is a v4 UUID, inert without this machine's `~/.claude`. **The marker text is a wire format** — older PRs are found by grepping it, so changing it orphans them, which is why the hook refuses any id outside `[A-Za-z0-9._-]` rather than emit a marker split across lines or closed early by a stray `>`. Placement is the **bottom of the body, below** the `🤖 Generated with Claude Code` footer — deliberately *not* "the last line", since the harness separately requires that footer to end the body and two rules claiming last place get resolved at random. Bottom also lands the marker in trailer position **if** the repo is configured to prefill squash commit bodies from the PR description; GitHub's default prefills from commit messages instead, so don't expect `git log --grep 'claude-session'` to find it.

## Tests

`fu-dev-guards` ships a plain-bash suite for the shared git-guard helper (segment + head-match) and the hooks that source it — unit cases plus env-seam-driven end-to-end denials:

```bash
bash plugins/fu-dev-guards/test/git-guard.test.sh
```

It also ships a suite for the SessionStart session-id stamper (payload shape, the
marker wire format, silence on a missing id, and that a hostile id stays inert).
Hermetic with nothing to stub — the hook's only input is the JSON on stdin:

```bash
bash plugins/fu-dev-guards/test/stamp-session.test.sh
```

