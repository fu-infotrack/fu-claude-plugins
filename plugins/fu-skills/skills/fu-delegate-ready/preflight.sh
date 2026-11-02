#!/usr/bin/env bash
# Read-only readiness check for the three tasks cloud sessions delegate to a local one:
# merge queue (gh), GitHub GraphQL (gh), stage DB (vault + psql, via fu-pg).
#
# Prints one line per check: `ok   <check>  <detail>` or `fail <check>  <detail>`.
# Exit 0 when every check passes, 1 otherwise. Never mints DB credentials and never
# prints a token.
#
# Usage: preflight.sh [--only gh|db]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="${FU_CONFIG:-$HERE/../../scripts/fu-config.sh}"

only=""
case "${1:-}" in
  --only) only="${2:-}" ;;
  "") ;;
  *) echo "usage: preflight.sh [--only gh|db]" >&2; exit 2 ;;
esac

failures=0
report() {
  local status=$1 check=$2 detail=$3
  printf '%-4s %-14s %s\n' "$status" "$check" "$detail"
  [ "$status" = ok ] || failures=$((failures + 1))
}

check_github() {
  if ! command -v gh >/dev/null; then
    report fail gh "gh not on PATH — merge queue and GraphQL need it"
    return
  fi
  if ! gh auth status >/dev/null 2>&1; then
    report fail gh-auth "gh is not signed in — run: gh auth login"
    return
  fi
  report ok gh-auth "signed in"
  local login
  if login=$(gh api graphql -f query='query{viewer{login}}' --jq .data.viewer.login 2>/dev/null) && [ -n "$login" ]; then
    report ok gh-graphql "viewer $login"
  else
    report fail gh-graphql "GraphQL call failed — check the token's scopes (gh auth status)"
  fi
}

check_stage_db() {
  command -v jq >/dev/null || { report fail jq "jq not on PATH — fu-pg needs it"; return; }
  command -v psql >/dev/null && report ok psql "$(psql --version | head -1)" \
                             || report fail psql "psql not on PATH — install postgresql-client"
  if ! command -v vault >/dev/null; then
    report fail vault "vault not on PATH — fu-pg needs it"
    return
  fi
  local db_config vault_addr
  db_config=$("$RESOLVE" pg-stage dbConfig 2>/dev/null || true)
  vault_addr=$("$RESOLVE" pg-stage vaultAddr 2>/dev/null || true)
  [ -n "$vault_addr" ] && export VAULT_ADDR="$vault_addr"
  if [ -n "$db_config" ]; then
    report ok pg-config "pg-stage.dbConfig=$db_config"
  else
    report fail pg-config "pg-stage.dbConfig unset in fu-tools config — a request must name the db-config"
  fi
  if [ -z "${VAULT_ADDR:-}" ]; then
    report fail vault-addr "no pg-stage.vaultAddr and no \$VAULT_ADDR"
    return
  fi
  if vault token lookup -format=json >/dev/null 2>&1; then
    report ok vault-token "valid at $VAULT_ADDR"
  else
    report fail vault-token "no valid token at $VAULT_ADDR — run: vault login -method=ldap username=<you>"
  fi
}

case "$only" in
  gh) check_github ;;
  db) check_stage_db ;;
  "") check_github; check_stage_db ;;
  *) echo "usage: preflight.sh [--only gh|db]" >&2; exit 2 ;;
esac

[ "$failures" -eq 0 ]
