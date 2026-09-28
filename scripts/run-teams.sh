#!/usr/bin/env bash
# Runs one Terragrunt action for each given team and, in GitHub Actions, writes the
# output to the job summary. Continues past failures and exits 1 if any team failed.
# Usage: scripts/run-teams.sh <plan|apply|plan-destroy> <team>...
set -euo pipefail

NAME_RE='^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

action="${1:-}"
shift || true
case "$action" in
  plan) args=(plan -input=false -lock-timeout=10m) ;;
  apply) args=(apply -auto-approve -input=false -lock-timeout=10m) ;;
  plan-destroy) args=(plan -destroy -input=false -lock-timeout=10m) ;;
  *)
    echo "usage: $0 <plan|apply|plan-destroy> <team>..." >&2
    exit 2
    ;;
esac
[ "$#" -gt 0 ] || { echo "no teams given" >&2; exit 2; }

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi
}

rc=0
for team in "$@"; do
  if [[ ! "$team" =~ $NAME_RE ]]; then
    echo "error: invalid team name '$team'" >&2
    rc=1
    continue
  fi

  log="$(mktemp)"
  echo "::group::$action team-$team"
  if terragrunt run --non-interactive --no-color --working-dir "$ROOT/live/team-$team" -- \
    "${args[@]}" -no-color 2>&1 | tee "$log"; then
    status="succeeded"
  else
    status="FAILED"
    rc=1
  fi
  echo "::endgroup::"

  # Keep the summary readable and under GitHub's size limit: Terraform's result lines
  # plus the tail of the log.
  {
    printf '<details><summary><b>%s team-%s: %s</b></summary>\n\n```text\n' "$action" "$team" "$status"
    grep -E '^(Plan:|No changes\.|Apply complete!|Destroy complete!|Error:)' "$log" || true
    echo "..."
    tail -n 200 "$log" | tail -c 50000
    printf '\n```\n</details>\n\n'
  } | summary
  rm -f "$log"
done

exit "$rc"
