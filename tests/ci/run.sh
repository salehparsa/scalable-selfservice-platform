#!/usr/bin/env bash
# Runs every tests/ci/test-*.sh; exits non-zero if any test fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

rc=0
for t in test-*.sh; do
  bash "$t" || rc=1
done
[ "$rc" -eq 0 ] && echo "all CI tests passed" || echo "CI tests failed"
exit "$rc"
