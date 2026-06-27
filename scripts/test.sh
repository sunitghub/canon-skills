#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  "$ROOT/tests/tkt.sh"
  "$ROOT/tests/sprint.sh"
  "$ROOT/tests/skills-add-sprint.sh"
  "$ROOT/tests/skills-refresh.sh"
  "$ROOT/tests/skills-uninstall.sh"
  "$ROOT/tests/skills-std.sh"
  "$ROOT/tests/install-target.sh"
  "$ROOT/tests/install-sh.sh"
  "$ROOT/tests/copy-todo-walkthrough.sh"
  "$ROOT/tests/sprint-check-server.sh"
  "$ROOT/tests/sprint-check-app.sh"
)

for test_file in "${tests[@]}"; do
  printf '==> %s\n' "${test_file#$ROOT/}"
  bash "$test_file"
done

if command -v go >/dev/null 2>&1; then
  printf '==> %s\n' "tools/sprint-check-go"
  (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-check-go)
else
  printf '==> %s\n' "tools/sprint-check-go skipped (go absent)"
fi

printf '\nAll tests passed.\n'
