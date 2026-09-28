#!/usr/bin/env bash
# Minimal assertion helpers for tests/ci (sourced; no bats dependency).
PASS=0
FAIL=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi
}

assert_eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected: $2 | actual: $3"; fi
}

assert_contains() { # <name> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else not_ok "$1" "expected to contain: $2 | actual: $3"; fi
}

assert_fails() { # <name> <exit code>
  if [ "$2" -ne 0 ]; then ok "$1"; else not_ok "$1" "expected a non-zero exit code"; fi
}

assert_succeeds() { # <name> <exit code> [details]
  if [ "$2" -eq 0 ]; then ok "$1"; else not_ok "$1" "exit code $2 ${3:-}"; fi
}

finish() {
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
