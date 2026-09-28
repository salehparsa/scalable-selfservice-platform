#!/usr/bin/env bash
# Tests for scripts/changed-teams.sh using throwaway git repositories.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/changed-teams.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

set_teams() {
  if [ "$#" -eq 0 ]; then echo "teams: []" >teams.yaml; return; fi
  { echo "teams:"; for t in "$@"; do echo "  - $t"; done; } >teams.yaml
}

add_folder() {
  mkdir -p "live/team-$1"
  echo 'include "root" {}' >"live/team-$1/terragrunt.hcl"
  echo "owner: $1@example.com" >"live/team-$1/team.yaml"
}

commit() { git add -A && git commit -q -m "$1"; }

# new_repo <team>...: fresh repo with those teams committed; sets BASE.
new_repo() {
  cd "$(mktemp -d "$WORK/repo.XXXX")" || exit 1
  git init -q -b main
  git config user.email ci@example.com
  git config user.name ci
  mkdir -p modules/team_infrastructure live
  echo 'module' >modules/team_infrastructure/main.tf
  echo 'root' >live/root.hcl
  echo 'readme' >README.md
  set_teams "$@"
  for t in "$@"; do add_folder "$t"; done
  commit init
  BASE="$(git rev-parse HEAD)"
}

detect() { # detect <base> [head]: sets OUT, ERR, RC
  OUT="$("$SCRIPT" "$@" 2>"$WORK/stderr")"
  RC=$?
  ERR="$(cat "$WORK/stderr")"
}

val() { sed -n "s/^$1=//p" <<<"$OUT"; }

echo "changed-teams.sh"

new_repo alpha beta
echo "owner: new@example.com" >live/team-alpha/team.yaml
commit "alpha edits its own file"
detect "$BASE" HEAD
assert_eq "team file change -> only that team" '["alpha"]' "$(val apply)"
assert_eq "team file change -> nothing destroyed" '[]' "$(val destroy)"

new_repo alpha beta
echo 'module v2' >modules/team_infrastructure/main.tf
commit "module change"
detect "$BASE" HEAD
assert_eq "module change -> every team" '["alpha","beta"]' "$(val apply)"

new_repo alpha beta
echo 'root v2' >live/root.hcl
commit "root change"
detect "$BASE" HEAD
assert_eq "root.hcl change -> every team" '["alpha","beta"]' "$(val apply)"

new_repo alpha beta
echo 'docs' >>README.md
commit "docs only"
detect "$BASE" HEAD
assert_eq "README-only change -> nothing to apply" '[]' "$(val apply)"
assert_eq "README-only change -> nothing to destroy" '[]' "$(val destroy)"
assert_eq "README-only change -> no batches" '[]' "$(val apply_batches)"

new_repo alpha
set_teams alpha gamma
add_folder gamma
commit "onboard gamma"
detect "$BASE" HEAD
assert_eq "team added with folder -> that team" '["gamma"]' "$(val apply)"

new_repo alpha
set_teams alpha gamma
commit "onboard gamma without folder"
detect "$BASE" HEAD
assert_fails "team added without folder -> error" "$RC"
assert_contains "team added without folder -> says run make teams" "make teams" "$ERR"

new_repo alpha beta
set_teams alpha
commit "offboard beta"
detect "$BASE" HEAD
assert_succeeds "team removed, folder kept -> ok" "$RC" "$ERR"
assert_eq "team removed, folder kept -> destroy that team" '["beta"]' "$(val destroy)"
assert_eq "team removed, folder kept -> nothing applied" '[]' "$(val apply)"

new_repo alpha beta
set_teams alpha
git rm -r -q live/team-beta
commit "offboard beta and delete folder"
detect "$BASE" HEAD
assert_fails "team removed and folder deleted -> error" "$RC"
assert_contains "team removed and folder deleted -> explains why" "keep the folder" "$ERR"

SKIP_DESTROY_CHECKS=true detect "$BASE" HEAD
assert_succeeds "same change on main (SKIP_DESTROY_CHECKS) -> not blocked" "$RC" "$ERR"
assert_eq "same change on main -> still reports the removed team" '["beta"]' "$(val destroy)"

new_repo alpha b1 b2 b3 b4
set_teams alpha
commit "remove four teams"
detect "$BASE" HEAD
assert_fails "4 teams removed at once -> error (MAX_OFFBOARD=3)" "$RC"
MAX_OFFBOARD=4 detect "$BASE" HEAD
assert_succeeds "4 teams removed with MAX_OFFBOARD=4 -> ok" "$RC" "$ERR"
SKIP_DESTROY_CHECKS=true detect "$BASE" HEAD
assert_succeeds "4 teams removed on main (SKIP_DESTROY_CHECKS) -> not blocked" "$RC" "$ERR"

new_repo alpha
evil="live/team-\$(touch pwned)"
mkdir -p "$evil"
echo x >"$evil/team.yaml"
commit "malicious folder name"
detect "$BASE" HEAD
assert_fails "malicious folder name -> rejected" "$RC"
if [ -e pwned ]; then not_ok "malicious folder name -> not executed"; else ok "malicious folder name -> not executed"; fi

new_repo alpha beta
set_teams alpha
commit "offboard beta"
echo "owner: still-here@example.com" >live/team-beta/team.yaml
commit "edit pending-offboarding folder"
detect "$(git rev-parse HEAD~1)" HEAD
assert_eq "edit to a folder not in teams.yaml -> ignored" '[]' "$(val apply)"

new_repo alpha beta
detect "" HEAD
assert_eq "no base commit -> every team" '["alpha","beta"]' "$(val apply)"
detect 0000000000000000000000000000000000000000 HEAD
assert_eq "all-zero base (new branch push) -> every team" '["alpha","beta"]' "$(val apply)"

# shellcheck disable=SC2046 # generated names t001..t250 contain no spaces or globs
new_repo $(for i in $(seq -w 1 250); do echo "t$i"; done)
echo 'module v2' >modules/team_infrastructure/main.tf
commit "module change with 250 teams"
detect "$BASE" HEAD
jobs="$(val apply_batches | jq 'length')"
if [ "$jobs" -le 200 ]; then ok "250 teams -> at most 200 matrix jobs ($jobs)"; else not_ok "250 teams -> at most 200 matrix jobs" "got $jobs"; fi
assert_eq "250 teams -> every team exactly once" "250 250" \
  "$(val apply_batches | jq -r '[.[] | split(" ")[]] | "\(length) \(unique | length)"')"

new_repo alpha beta
echo "owner: new@example.com" >live/team-alpha/team.yaml
commit "alpha edits its own file"
BATCH_LIMIT=1 detect "$BASE" HEAD
assert_eq "batches are space-separated team lists" '["alpha"]' "$(val apply_batches)"

finish
