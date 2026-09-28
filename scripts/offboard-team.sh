#!/usr/bin/env bash
# Destroys an offboarded team: all its resources (buckets emptied, including every
# object version), then its state file. Safe to re-run after a partial failure.
# Usage: scripts/offboard-team.sh <team>
# Requires AWS credentials for the CI role; run by the `offboard` job after approval.
set -euo pipefail

NAME_RE='^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

team="${1:-}"
[[ "$team" =~ $NAME_RE ]] || { echo "usage: $0 <team>  (valid team name required)" >&2; exit 2; }

dir="$ROOT/live/team-$team"
if [ ! -f "$dir/terragrunt.hcl" ] || [ ! -f "$dir/team.yaml" ]; then
  echo "error: $dir is missing; destroy needs the team's config" >&2
  exit 1
fi
if yq -e ".teams // [] | contains([\"$team\"])" "$ROOT/teams.yaml" >/dev/null 2>&1; then
  echo "error: team '$team' is still in teams.yaml; refusing to destroy" >&2
  exit 1
fi

tg() { terragrunt run --non-interactive --no-color --working-dir "$dir" -- "$@"; }

# TG_OFFBOARDING makes live/root.hcl set force_destroy on the team's buckets.
export TG_OFFBOARDING=true

if [ -n "$(tg state list)" ]; then
  echo "== $team: enabling force_destroy on its buckets (in-place update, buckets only)"
  tg apply -auto-approve -input=false -lock-timeout=10m -target=aws_s3_bucket.this

  echo "== $team: destroying all resources"
  tg destroy -auto-approve -input=false -lock-timeout=10m
else
  echo "== $team: state is already empty, nothing to destroy"
fi

remaining="$(tg state list)"
if [ -n "$remaining" ]; then
  echo "error: resources still in state after destroy:" >&2
  echo "$remaining" >&2
  exit 1
fi

# Must match live/root.hcl: bucket <name_prefix>-tfstate-<account_id>, key <team-folder>/terraform.tfstate.
prefix="$(sed -nE 's/^[[:space:]]*name_prefix[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ROOT/live/root.hcl" | head -n1)"
account="$(aws sts get-caller-identity --query Account --output text)"
state="s3://$prefix-tfstate-$account/team-$team/terraform.tfstate"
echo "== $team: removing $state (kept as a noncurrent version for 90 days)"
aws s3 rm "$state"

echo "== $team: offboarded"
