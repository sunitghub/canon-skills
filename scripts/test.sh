#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  "$ROOT/tests/tkt.sh"
  "$ROOT/tests/sprint.sh"
  "$ROOT/tests/skills-add-sprint.sh"
  "$ROOT/tests/skills-std.sh"
  "$ROOT/tests/install-target.sh"
  "$ROOT/tests/sprint-check-server.sh"
)

for test_file in "${tests[@]}"; do
  printf '==> %s\n' "${test_file#$ROOT/}"
  bash "$test_file"
done

printf '\nAll tests passed.\n'
