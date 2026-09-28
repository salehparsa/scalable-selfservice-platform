#!/usr/bin/env bash
# Tests for scripts/sync-teams.sh (make teams / make check-teams) in a scratch layout.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

new_layout() { # new_layout <team>...
  cd "$(mktemp -d "$WORK/layout.XXXX")" || exit 1
  mkdir -p scripts live
  cp "$REPO_ROOT/scripts/sync-teams.sh" scripts/
  { echo "teams:"; for t in "$@"; do echo "  - $t"; done; } >teams.yaml
}

valid_team_yaml() {
  cat >"live/team-$1/team.yaml" <<'EOF'
owner: team@example.com
cost_center: cc-0001
buckets:
  - { suffix: data, visibility: private }
trusted_principal_arns:
  - "arn:aws:iam::{account_id}:root"
tags:
  ManagedBy: terraform
EOF
}

sync() { OUT="$(scripts/sync-teams.sh sync 2>&1)"; RC=$?; }
check() { OUT="$(scripts/sync-teams.sh check 2>&1)"; RC=$?; }

echo "sync-teams.sh"

new_layout alpha
sync
assert_succeeds "sync creates a new team" "$RC" "$OUT"
if [ -f live/team-alpha/terragrunt.hcl ] && [ -f live/team-alpha/team.yaml ]; then
  ok "sync writes terragrunt.hcl and team.yaml"
else
  not_ok "sync writes terragrunt.hcl and team.yaml"
fi
assert_contains "starter team.yaml has trusted_principal_arns" '{account_id}:root' "$(cat live/team-alpha/team.yaml)"
assert_contains "starter team.yaml has ManagedBy tag" 'ManagedBy: terraform' "$(cat live/team-alpha/team.yaml)"
check
assert_fails "check fails while starter team.yaml is unfilled" "$RC"
assert_contains "check names the missing owner" "owner is required" "$OUT"

valid_team_yaml alpha
check
assert_succeeds "check passes once team.yaml is filled in" "$RC" "$OUT"
sync
assert_eq "second sync is a no-op" "" "$OUT"

echo '# edit' >>live/team-alpha/terragrunt.hcl
check
assert_fails "hand-edited terragrunt.hcl -> check fails" "$RC"
sync
check
assert_succeeds "sync restores terragrunt.hcl" "$RC" "$OUT"

echo 'owner: kept' >live/team-alpha/team.yaml
sync
assert_eq "sync never overwrites team.yaml" "owner: kept" "$(cat live/team-alpha/team.yaml)"
valid_team_yaml alpha

for field in 'del(.trusted_principal_arns)' 'del(.tags)' '.tags.ManagedBy = "manual"' '.buckets[0].visibility = "internal"' 'del(.buckets[0].visibility)'; do
  valid_team_yaml alpha
  yq -i "$field" live/team-alpha/team.yaml
  check
  assert_fails "check rejects team.yaml with: $field" "$RC"
done
valid_team_yaml alpha

new_layout alpha Bad_Name ci alpha this-name-is-way-too-long
check
assert_fails "invalid, reserved, duplicate, too-long names -> check fails" "$RC"
for msg in "duplicate team names" "invalid team name 'Bad_Name'" "'ci' is reserved" "invalid team name 'this-name-is-way-too-long'"; do
  assert_contains "reports: $msg" "$msg" "$OUT"
done

new_layout alpha beta
sync >/dev/null
valid_team_yaml alpha
valid_team_yaml beta
{ echo "teams:"; echo "  - alpha"; } >teams.yaml
check
assert_succeeds "folder removed from teams.yaml -> check still passes" "$RC" "$OUT"
assert_contains "folder removed from teams.yaml -> pending offboarding notice" "pending offboarding" "$OUT"
sync
if [ -d live/team-beta ]; then ok "sync never deletes a team folder"; else not_ok "sync never deletes a team folder"; fi

new_layout alpha
echo "not_teams: []" >teams.yaml
check
assert_fails "teams.yaml without a teams list -> error" "$RC"

finish
