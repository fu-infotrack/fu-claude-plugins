#!/usr/bin/env bash
# Tests for fu-delegate-ready/preflight.sh.
# No framework — run: bash plugins/fu-skills/test/delegate-preflight.test.sh
#
# Hermetic: gh, vault and psql are stubs on PATH, HOME is a throwaway dir, cwd is
# outside the repo (fu-config.sh walks up from cwd), and the config resolver is a
# stub driven by env vars.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$HERE/../skills/fu-delegate-ready/preflight.sh"

pass=0 fail=0
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
expect() {
  local name=$1 pattern=$2 haystack=$3
  if grep -qE -- "$pattern" <<<"$haystack"; then pass=$((pass + 1)); else bad "$name — no match for /$pattern/ in:"$'\n'"$haystack"; fi
}
refute() {
  local name=$1 pattern=$2 haystack=$3
  if grep -qE -- "$pattern" <<<"$haystack"; then bad "$name — unexpected /$pattern/ in:"$'\n'"$haystack"; else pass=$((pass + 1)); fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/cwd"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) [ "${GH_AUTH:-ok}" = ok ] ;;
  api)  [ "${GH_GRAPHQL:-ok}" = ok ] && echo octocat ;;
  *) exit 9 ;;
esac
STUB
cat > "$TMP/bin/vault" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "token lookup -format=json" ] || { echo "unexpected vault call: $*" >&2; exit 9; }
[ -n "${VAULT_ADDR:-}" ] || exit 8
[ "${VAULT_TOKEN_OK:-ok}" = ok ] && echo '{"data":{}}'
STUB
cat > "$TMP/bin/psql" <<'STUB'
#!/usr/bin/env bash
echo "psql (PostgreSQL) 16.4"
STUB
cat > "$TMP/bin/resolve" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  dbConfig)  [ -n "${CFG_DB:-}" ]    && echo "$CFG_DB" ;;
  vaultAddr) [ -n "${CFG_VAULT:-}" ] && echo "$CFG_VAULT" ;;
esac
true
STUB
chmod +x "$TMP/bin/"*
for tool in jq bash grep head printf; do ln -sf "$(command -v "$tool")" "$TMP/bin/$tool"; done
ln -sf "$(command -v dirname)" "$TMP/bin/dirname"

run() {
  (cd "$TMP/cwd" && env -i HOME="$TMP/home" PATH="$TMP/bin" FU_CONFIG="$TMP/bin/resolve" "$@" "$BASH" "$PREFLIGHT" ${ARGS:-})
}

out=$(run CFG_DB=entityplatform CFG_VAULT=https://vault.example) ; rc=$?
[ $rc -eq 0 ] && pass=$((pass + 1)) || bad "all ok should exit 0 (got $rc)"
expect "graphql ok" '^ok +gh-graphql +viewer octocat' "$out"
expect "pg config ok" '^ok +pg-config +pg-stage.dbConfig=entityplatform' "$out"
expect "vault ok" '^ok +vault-token +valid at https://vault.example' "$out"
refute "no fail lines" '^fail' "$out"

out=$(run GH_AUTH=no CFG_DB=x CFG_VAULT=https://v) ; rc=$?
[ $rc -eq 1 ] && pass=$((pass + 1)) || bad "gh unauthenticated should exit 1 (got $rc)"
expect "gh auth fail" '^fail +gh-auth .*gh auth login' "$out"
refute "graphql skipped when unauthenticated" 'gh-graphql' "$out"

out=$(run GH_GRAPHQL=no CFG_DB=x CFG_VAULT=https://v)
expect "graphql fail" '^fail +gh-graphql' "$out"

out=$(run VAULT_TOKEN_OK=no CFG_DB=x CFG_VAULT=https://v)
expect "vault token fail names the login" '^fail +vault-token .*vault login -method=ldap' "$out"

out=$(run)
expect "no dbConfig" '^fail +pg-config' "$out"
expect "no vault addr" '^fail +vault-addr' "$out"

out=$(run VAULT_ADDR=https://from-env CFG_DB=x)
expect "env VAULT_ADDR is used" '^ok +vault-token +valid at https://from-env' "$out"

out=$(ARGS="--only gh" run)
refute "--only gh skips db" 'vault|pg-config|psql' "$out"
expect "--only gh runs gh" 'gh-auth' "$out"

out=$(ARGS="--only db" run CFG_DB=x CFG_VAULT=https://v)
refute "--only db skips gh" 'gh-' "$out"

rm "$TMP/bin/psql"
out=$(ARGS="--only db" run CFG_DB=x CFG_VAULT=https://v)
expect "missing psql reported" '^fail +psql' "$out"

ARGS="--bogus" run >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && pass=$((pass + 1)) || bad "bad flag should exit 2 (got $rc)"

printf 'delegate-preflight: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
