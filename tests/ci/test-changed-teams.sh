#!/usr/bin/env bash
# Tests for scripts/changed-teams.sh, the CI change detection, using throwaway git repos.
# Run: make test-ci
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/changed-teams.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    failures=$((failures + 1))
  fi
}

set_teams() { { echo "teams:"; for t in "$@"; do echo "  - $t"; done; } >teams.yaml; }
add_folder() { mkdir -p "live/team-$1" && touch "live/team-$1/terragrunt.hcl" "live/team-$1/team.yaml"; }
commit() { git add -A && git commit -q -m "$1"; }

new_repo() { # new_repo <team>...: fresh repo with those teams committed, sets BASE
  cd "$(mktemp -d "$WORK/repo.XXXX")" || exit 1
  git init -q -b main && git config user.email ci@example.com && git config user.name ci
  mkdir -p modules/team_infrastructure live
  echo module >modules/team_infrastructure/main.tf
  echo readme >README.md
  set_teams "$@"
  for t in "$@"; do add_folder "$t"; done
  commit init
  BASE="$(git rev-parse HEAD)"
}

detect() { OUT="$("$SCRIPT" "$BASE" HEAD 2>/dev/null)"; RC=$?; } # sets OUT, RC
val() { sed -n "s/^$1=//p" <<<"$OUT"; }

echo "changed-teams.sh"

new_repo alpha beta
echo "owner: new" >live/team-alpha/team.yaml && commit "alpha edits its file"
detect
check "team edits its own file -> only that team" '["alpha"]' "$(val apply)"

new_repo alpha beta
echo "module v2" >modules/team_infrastructure/main.tf && commit "module change"
detect
check "module change -> every team" '["alpha","beta"]' "$(val apply)"

new_repo alpha beta
echo docs >>README.md && commit "docs only"
detect
check "docs-only change -> nothing" '[] []' "$(val apply) $(val destroy)"

new_repo alpha
set_teams alpha gamma && add_folder gamma && commit "onboard gamma"
detect
check "team added -> only the new team" '["gamma"]' "$(val apply)"

new_repo alpha beta
set_teams alpha && commit "offboard beta, folder kept"
detect
check "team removed -> reported for destroy, nothing applied" '["beta"] []' "$(val destroy) $(val apply)"

new_repo alpha beta
set_teams alpha && git rm -r -q live/team-beta && commit "offboard beta and delete folder"
detect
check "team removed and folder deleted in one change -> rejected" 1 "$RC"

new_repo alpha
evil="live/team-\$(touch pwned)"
mkdir -p "$evil" && touch "$evil/team.yaml" && commit "malicious folder name"
detect
check "malicious folder name -> rejected and never executed" "1 no" "$RC $([ -e pwned ] && echo yes || echo no)"

# shellcheck disable=SC2046 # generated names t001..t250 contain no spaces or globs
new_repo $(seq -f "t%03g" 1 250)
echo "module v2" >modules/team_infrastructure/main.tf && commit "module change, 250 teams"
detect
check "250 teams -> <=200 matrix jobs covering every team once" "true 250" \
  "$(val apply_batches | jq -r '(length <= 200 | tostring) + " " + ([.[] | split(" ")[]] | unique | length | tostring)')"

echo "  $failures failure(s)"
[ "$failures" -eq 0 ]
