#!/usr/bin/env bash
# Approval gate for the terraform-destroy workflow. GitHub environments can't require
# reviewers on a private repository on the Free plan, so the workflow enforces it here.
# Reads (all from the workflow):
#   ACTOR      login that started (or re-ran) the run: github.triggering_actor
#   APPROVERS  repository variable DESTROY_APPROVERS, comma- or space-separated logins
#   REF        github.ref; destroys only run from main
#   TEAM       workflow input: team to destroy
#   CONFIRM    workflow input: the team name typed again
set -euo pipefail

NAME_RE='^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "error: $*" >&2
  exit 1
}

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

[ "${REF:-}" = "refs/heads/main" ] || fail "destroys only run from main (got '${REF:-}')"

actor="$(lower "${ACTOR:-}")"
approvers=" $(lower "$(tr ',' ' ' <<<"${APPROVERS:-}")") "
[ -n "$actor" ] || fail "no actor"
[[ "$approvers" == *" $actor "* ]] || fail "'${ACTOR}' is not an approver (repository variable DESTROY_APPROVERS)"

team="${TEAM:-}"
[[ "$team" =~ $NAME_RE ]] || fail "invalid team name '${team}'"
[ "${CONFIRM:-}" = "$team" ] || fail "confirmation '${CONFIRM:-}' does not match team '${team}'; type the team name exactly"

if yq -e ".teams // [] | contains([\"$team\"])" "$ROOT/teams.yaml" >/dev/null 2>&1; then
  fail "team '$team' is still in teams.yaml; remove it there (PR + merge) before destroying"
fi
[ -f "$ROOT/live/team-$team/terragrunt.hcl" ] ||
  fail "live/team-$team/ does not exist: nothing to destroy (already offboarded?)"

echo "authorized: ${ACTOR} may destroy team '$team'"
