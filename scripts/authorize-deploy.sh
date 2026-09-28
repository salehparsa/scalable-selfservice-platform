#!/usr/bin/env bash
# Approval gate for manual deploys. GitHub environments can't require reviewers on a
# private repository on the Free plan, so the workflow enforces approval itself.
# Reads (all from the workflow):
#   ACTOR           login that started (or re-ran) the run: github.triggering_actor
#   ALLOWED_ACTORS  repository variable DEPLOY_ALLOWED_ACTORS, comma- or space-separated
#   REF             github.ref; deploys only run from main
#   DESTROY         JSON list of teams this deploy would offboard
#   ALLOW_OFFBOARD  "true" when the allow_offboard box was ticked
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

[ "${REF:-}" = "refs/heads/main" ] || fail "deploys only run from main (got '${REF:-}')"

actor="$(lower "${ACTOR:-}")"
allowed=" $(lower "$(tr ',' ' ' <<<"${ALLOWED_ACTORS:-}")") "
[ -n "$actor" ] || fail "no actor"
[[ "$allowed" == *" $actor "* ]] || fail "'${ACTOR}' is not allowed to deploy (repository variable DEPLOY_ALLOWED_ACTORS)"

destroy="${DESTROY:-[]}"
count="$(jq 'length' <<<"$destroy")"
if [ "$count" -gt 0 ] && [ "${ALLOW_OFFBOARD:-false}" != "true" ]; then
  fail "this deploy would destroy: $(jq -r 'join(", ")' <<<"$destroy"). Run it again with allow_offboard ticked to confirm."
fi

echo "authorized: ${ACTOR} (offboarding $count team(s))"
