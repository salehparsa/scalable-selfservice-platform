#!/usr/bin/env bash
# Decides what CI runs for a change between two commits.
# Usage: scripts/changed-teams.sh <base-commit> [<head-commit>]   (head defaults to HEAD)
#
#   files under live/team-<name>/             -> apply <name>
#   name added to teams.yaml                  -> apply <name>
#   live/root.hcl, tool versions              -> apply every team in teams.yaml
#   name removed from teams.yaml              -> destroy <name>
#   no usable base (first push, new branch)   -> apply every team
# A change to modules/ selects no team: teams run a released module version, which the release
# workflow rolls out (canary team first, then everyone).
#
# Prints key=value lines for $GITHUB_OUTPUT:
#   apply=<json>          teams to plan (PR) or apply (main)
#   apply_batches=<json>  the same teams grouped into at most BATCH_LIMIT matrix jobs
#   destroy=<json>        teams removed from teams.yaml (plan-destroy on PRs; destroyed
#                         only by the separate terraform-destroy workflow)
# Reads only git objects, so any two commits can be compared.
#
# SKIP_DESTROY_CHECKS=true skips the offboarding checks (folder kept, MAX_OFFBOARD). The apply
# workflow sets it on main: the change is already merged, and blocking it would only stop the
# other teams' applies. PRs keep the checks, so a bad offboarding change can't be merged.
set -euo pipefail
export LC_ALL=C

BASE="${1:-}"
HEAD="${2:-HEAD}"
MAX_OFFBOARD="${MAX_OFFBOARD:-3}"
SKIP_DESTROY_CHECKS="${SKIP_DESTROY_CHECKS:-false}"
BATCH_LIMIT="${BATCH_LIMIT:-200}"
NAME_RE='^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$'
PLATFORM_RE='^(live/root\.hcl$|\.terraform-version$|\.terragrunt-version$)'

cd "$(git rev-parse --show-toplevel)"

errors=0
err() {
  echo "error: $*" >&2
  errors=$((errors + 1))
}

teams_at() { # team names in teams.yaml at a commit, sorted
  local content
  content="$(git show "$1:teams.yaml" 2>/dev/null)" || return 0
  yq -r '.teams // [] | .[]' <<<"$content" | sort -u
}

has_folder() {
  git cat-file -e "$HEAD:live/team-$1/terragrunt.hcl" 2>/dev/null &&
    git cat-file -e "$HEAD:live/team-$1/team.yaml" 2>/dev/null
}

nonempty() { sed '/^$/d' <<<"$1"; }
only_in() { comm -23 <(nonempty "$1") <(nonempty "$2"); } # lines of $1 not in $2
in_both() { comm -12 <(nonempty "$1") <(nonempty "$2"); }
to_json() { nonempty "$1" | jq -R . | jq -sc .; }

head_teams="$(teams_at "$HEAD")"
while IFS= read -r t; do
  [[ "$t" =~ $NAME_RE ]] || err "invalid team name in teams.yaml: '$t'"
done < <(nonempty "$head_teams")

if [ -z "$BASE" ] || [[ "$BASE" =~ ^0+$ ]] || ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  echo "no usable base commit: selecting every team" >&2
  apply="$head_teams"
  destroy=""
else
  base_teams="$(teams_at "$BASE")"
  changed="$(git diff --name-only "$BASE" "$HEAD")"

  touched="$(sed -nE 's#^live/team-([^/]+)/.*#\1#p' <<<"$changed" | sort -u)"
  while IFS= read -r t; do
    [[ "$t" =~ $NAME_RE ]] || err "invalid team folder name: 'live/team-$t'"
  done < <(nonempty "$touched")

  if grep -Eq "$PLATFORM_RE" <<<"$changed"; then
    echo "platform files changed: selecting every team" >&2
    apply="$head_teams"
  else
    added="$(only_in "$head_teams" "$base_teams")"
    # Folders no longer in teams.yaml (pending offboarding) are ignored.
    apply="$(in_both "$(printf '%s\n%s\n' "$touched" "$added" | sort -u)" "$head_teams")"
  fi
  destroy="$(only_in "$base_teams" "$head_teams")"
fi

while IFS= read -r t; do
  has_folder "$t" || err "team '$t' is in teams.yaml but live/team-$t/ is missing (run: make teams)"
done < <(nonempty "$apply")

while IFS= read -r t; do
  [[ "$t" =~ $NAME_RE ]] || err "invalid removed team name: '$t'"
  if [ "$SKIP_DESTROY_CHECKS" != true ] && ! has_folder "$t"; then
    err "team '$t' was removed from teams.yaml and live/team-$t/ was deleted too; keep the folder until terraform-destroy has destroyed the team"
  fi
done < <(nonempty "$destroy")

count="$(nonempty "$destroy" | wc -l | tr -d ' ')"
if [ "$SKIP_DESTROY_CHECKS" != true ] && [ "$count" -gt "$MAX_OFFBOARD" ]; then
  err "$count teams removed in one change; at most $MAX_OFFBOARD allowed (raise MAX_OFFBOARD deliberately to offboard more)"
fi

[ "$errors" -eq 0 ] || exit 1

apply_json="$(to_json "$apply")"
destroy_json="$(to_json "$destroy")"
batches_json="$(jq -c --argjson limit "$BATCH_LIMIT" '
  if length == 0 then []
  else (length / $limit | ceil) as $size
    | [range(0; length; $size) as $i | .[$i:$i + $size] | join(" ")]
  end' <<<"$apply_json")"

echo "apply: $(jq -r 'join(" ")' <<<"$apply_json")" >&2
echo "destroy: $(jq -r 'join(" ")' <<<"$destroy_json")" >&2
echo "apply=$apply_json"
echo "apply_batches=$batches_json"
echo "destroy=$destroy_json"
