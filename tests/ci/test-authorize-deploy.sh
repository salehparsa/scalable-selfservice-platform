#!/usr/bin/env bash
# Tests for scripts/authorize-deploy.sh (manual deploy gate).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/authorize-deploy.sh"

gate() { # gate VAR=value...: runs the gate with only these variables set
  OUT="$(env -i PATH="$PATH" "$@" "$SCRIPT" 2>&1)"
  RC=$?
}

echo "authorize-deploy.sh"

gate ACTOR=salehparsa ALLOWED_ACTORS=salehparsa REF=refs/heads/main DESTROY='[]'
assert_succeeds "allowed actor on main, nothing to destroy -> authorized" "$RC" "$OUT"

gate ACTOR=SalehParsa ALLOWED_ACTORS="alice, salehparsa" REF=refs/heads/main DESTROY='[]'
assert_succeeds "login match is case-insensitive, comma list" "$RC" "$OUT"

gate ACTOR=mallory ALLOWED_ACTORS=salehparsa REF=refs/heads/main DESTROY='[]'
assert_fails "actor not in allow-list -> refused" "$RC"
assert_contains "refusal names the variable" "DEPLOY_ALLOWED_ACTORS" "$OUT"

gate ACTOR=saleh ALLOWED_ACTORS=salehparsa REF=refs/heads/main DESTROY='[]'
assert_fails "prefix of an allowed login -> refused" "$RC"

gate ACTOR=salehparsa REF=refs/heads/main DESTROY='[]'
assert_fails "allow-list not set -> refused (deny by default)" "$RC"

gate ACTOR=salehparsa ALLOWED_ACTORS=salehparsa REF=refs/heads/feature DESTROY='[]'
assert_fails "run from a branch other than main -> refused" "$RC"

gate ACTOR=salehparsa ALLOWED_ACTORS=salehparsa REF=refs/heads/main DESTROY='["beta"]'
assert_fails "offboarding without allow_offboard -> refused" "$RC"
assert_contains "refusal lists the teams" "beta" "$OUT"

gate ACTOR=salehparsa ALLOWED_ACTORS=salehparsa REF=refs/heads/main DESTROY='["beta"]' ALLOW_OFFBOARD=true
assert_succeeds "offboarding with allow_offboard -> authorized" "$RC" "$OUT"

finish
