#!/usr/bin/env bash
# Tests for connect.sh's --export failure contract.
# No framework — run: bash plugins/fu-pg-stage/test/export-guard.test.sh
#
# The bug being locked down: every failure in connect.sh writes to stderr and
# nothing to stdout, so `eval "$(connect.sh --export)"` eval'd an EMPTY string —
# which succeeds with $? = 0 and leaves PG* unset. psql then falls back to the
# local unix socket and the error reads as "the server is down".
#
# Hermetic: `vault` is stubbed on PATH (so nothing reaches a real Vault) and HOME
# is a throwaway dir, which both redirects the credential cache and makes the
# fu-tools config resolve empty. cwd is moved out of the repo too, since
# fu-config.sh walks up from the process cwd looking for .claude/.fu-tools.json.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECT="$HERE/../skills/pg-stage/connect.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/cwd"

# ── vault stub ───────────────────────────────────────────────────────────────
# VAULT_STUB=ok   -> serve a config + creds read
# VAULT_STUB=fail -> exit non-zero like an unreachable / unauthenticated Vault
cat > "$TMP/bin/vault" <<'STUB'
#!/usr/bin/env bash
if [ "${VAULT_STUB:-fail}" != ok ]; then
  echo "Error making API request. (stubbed failure)" >&2
  exit 2
fi
case "$*" in
  *config/*)
    cat <<'J'
{"data":{"connection_details":{"connection_url":"postgresql://{{username}}:{{password}}@db.example.com:5433/appdb?sslmode=require"},"allowed_roles":["appdb_rw"]}}
J
    ;;
  *creds/*)
    # password deliberately carries a quote, a space and a slash — it has to
    # survive both sq() (eval-safety) and urlenc() (URI-safety).
    cat <<'J'
{"data":{"username":"v-ldap-fu-abc123","password":"p@ss w/or'd\"x"},"lease_duration":3600}
J
    ;;
esac
STUB
chmod +x "$TMP/bin/vault"

# run <extra-env...> -- <args...>  -> sets RC, OUT, ERR
run() {
  local env=()
  while [ "$1" != -- ]; do env+=("$1"); shift; done
  shift
  OUT=$(cd "$TMP/cwd" && env "HOME=$TMP/home" "PATH=$TMP/bin:$PATH" "${env[@]}" \
        bash "$CONNECT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
}

# eval_run <args...> -> sets EVAL_RC and PGHOST_SEEN, running the guard the way a
# user does. Runs in a subshell so a `false`/`exit` can't take the suite with it.
eval_run() {
  local out rc
  out=$(cd "$TMP/cwd" && env "HOME=$TMP/home" "PATH=$TMP/bin:$PATH" \
        VAULT_STUB="${VAULT_STUB:-fail}" VAULT_ADDR=https://vault.example.com \
        bash "$CONNECT" "$@" 2>/dev/null)
  ( eval "$out" >/dev/null 2>&1; echo "rc=$? PGHOST=${PGHOST:-unset}" ) > "$TMP/ev"
  rc=$(sed -n 's/^rc=\([0-9]*\).*/\1/p' "$TMP/ev")
  EVAL_RC=$rc
  PGHOST_SEEN=$(sed -n 's/.*PGHOST=//p' "$TMP/ev")
  EXPORT_OUT=$out
}

echo "== a failing --export must not eval to a silent success =="

VAULT_STUB=fail eval_run somedb --export
[ "${EVAL_RC:-}" != 0 ] && ok || bad "eval of a failed --export must be non-zero (got $EVAL_RC)"
[ "$PGHOST_SEEN" = unset ] && ok || bad "PGHOST must stay unset on failure (got <$PGHOST_SEEN>)"
[ -n "$EXPORT_OUT" ] && ok || bad "failed --export must write SOMETHING to stdout to eval"

# `exit` in eval'd output would close the caller's interactive shell.
grep -qw exit <<<"$EXPORT_OUT" && bad "failed --export must never emit 'exit' (kills caller's shell)" || ok
grep -qw false <<<"$EXPORT_OUT" && ok || bad "failed --export should emit 'false' to carry the non-zero"
# No PG* assignment may leak from a failure.
grep -q 'export PG' <<<"$EXPORT_OUT" && bad "failed --export must not emit any PG* assignment" || ok

echo "== the real cause still reaches stderr =="

run VAULT_STUB=fail VAULT_ADDR=https://vault.example.com -- somedb --export
[ "$RC" != 0 ] && ok || bad "script itself must exit non-zero on a vault failure (got $RC)"
grep -q 'stubbed failure' <<<"$ERR" && ok || bad "vault's own error must not be swallowed: <$ERR>"

echo "== the guard covers the pre-vault failure paths too =="

# Missing VAULT_ADDR: fails before any vault call, must still be loud.
OUT=$(cd "$TMP/cwd" && env -u VAULT_ADDR "HOME=$TMP/home" "PATH=$TMP/bin:$PATH" \
      bash "$CONNECT" somedb --export 2>/dev/null)
( eval "$OUT" >/dev/null 2>&1 ) ; [ $? != 0 ] && ok || bad "missing VAULT_ADDR must eval non-zero"

# No db-config and none configured: the first thing a new user hits.
VAULT_STUB=ok eval_run --export
[ "${EVAL_RC:-}" != 0 ] && ok || bad "missing db-config must eval non-zero (got $EVAL_RC)"

# A missing dependency is the same class of failure. Note the absolute
# "$BASH" — with PATH emptied, `env … bash` could not find bash itself and the
# probe would pass for the wrong reason.
OUT=$(cd "$TMP/cwd" && env "HOME=$TMP/home" "PATH=$TMP/cwd" \
      VAULT_ADDR=https://vault.example.com "$BASH" "$CONNECT" somedb --export 2>/dev/null)
( eval "$OUT" >/dev/null 2>&1 ) ; [ $? != 0 ] && ok || bad "missing vault CLI must eval non-zero"
grep -qw false <<<"$OUT" && ok || bad "missing vault CLI should emit 'false': <$OUT>"

echo "== a SUCCESSFUL --export is untouched by the guard =="

VAULT_STUB=ok eval_run appdb --export
[ "${EVAL_RC:-}" = 0 ] && ok || bad "eval of a good --export must be 0 (got $EVAL_RC)"
[ "$PGHOST_SEEN" = db.example.com ] && ok || bad "PGHOST should be db.example.com (got <$PGHOST_SEEN>)"
grep -qw false <<<"$EXPORT_OUT" && bad "a successful --export must not emit 'false'" || ok

# The awkward password has to survive the round trip intact. Sourced from a file
# rather than interpolated into a -c string: the password contains a single quote,
# which is exactly what breaks naive embedding (and what sq() exists to handle).
VAULT_STUB=ok run VAULT_ADDR=https://vault.example.com -- appdb --export
printf '%s\n' "$OUT" > "$TMP/ex.sh"
peek() { "$BASH" -c '. "$1"; printf "%s" "${!2}"' _ "$TMP/ex.sh" "$1"; }
got=$(peek PGPASSWORD)
EXPECT_PASS='p@ss w/or'\''d"x'   # must match the stub's JSON above, unescaped
[ "$got" = "$EXPECT_PASS" ] && ok || bad "PGPASSWORD mangled by sq(): <$got> != <$EXPECT_PASS>"
[ "$(peek PGPORT)" = 5433 ] && ok || bad "PGPORT should come from connection_url (got $(peek PGPORT))"
[ "$(peek PGDATABASE)" = appdb ] && ok || bad "PGDATABASE should be appdb"
[ "$(peek PGUSER)" = v-ldap-fu-abc123 ] && ok || bad "PGUSER should be the minted dynamic user"

echo "== --purge exits clean, so the guard stays quiet =="

VAULT_STUB=ok run VAULT_ADDR=https://vault.example.com -- --purge --export
[ "$RC" = 0 ] && ok || bad "--purge should exit 0 (got $RC)"
grep -qw false <<<"$OUT" && bad "--purge exits 0, guard must not fire" || ok

echo "== other modes: known, documented gap =="

# The connection-string mode CANNOT self-guard (its stdout is a URI, not shell
# code), so a failure is still an empty stdout — `psql "$(connect.sh)"` remains
# fail-open and the doc tells you to use `conn=$(connect.sh) || return`.
# Asserted so the gap is a decision, not a surprise.
VAULT_STUB=fail run VAULT_ADDR=https://vault.example.com -- somedb
[ -z "$OUT" ] && ok || bad "conn-string mode should print nothing on failure (got <$OUT>)"
[ "$RC" != 0 ] && ok || bad "conn-string mode must exit non-zero on failure"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
