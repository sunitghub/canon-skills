#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  "$ROOT/tests/tkt.sh"
  "$ROOT/tests/sprint.sh"
  "$ROOT/tests/frontmatter-lib.sh"
  "$ROOT/tests/skills-add-sprint.sh"
  "$ROOT/tests/skills-model-tiers-note.sh"
  "$ROOT/tests/skills-subagent-log-permission.sh"
  "$ROOT/tests/skills-refresh.sh"
  "$ROOT/tests/skills-uninstall.sh"
  "$ROOT/tests/git-precommit-hook.sh"
  "$ROOT/tests/subagent-log-cli.sh"
  "$ROOT/tests/skills-std.sh"
  "$ROOT/tests/install-target.sh"
  "$ROOT/tests/install-sh.sh"
  "$ROOT/tests/example-paths.sh"
  "$ROOT/tests/sprint-check-server.sh"
  "$ROOT/tests/sprint-check-app.sh"
  "$ROOT/tests/sprint-check-api-parity.sh"
  "$ROOT/tests/doc-mirror-parity.sh"
  "$ROOT/tests/jtbd-routing.sh"
  "$ROOT/tests/why-cap.sh"
  "$ROOT/tests/dsl-runner-comments.sh"
  "$ROOT/tests/sprint-headless.sh"
  "$ROOT/tests/sprint-headless-eval-tools.sh"
  "$ROOT/tests/sprint-headless-eval-criteria-only.sh"
)

for test_file in "${tests[@]}"; do
  printf '==> %s\n' "${test_file#$ROOT/}"
  bash "$test_file"
done

if command -v go >/dev/null 2>&1; then
  printf '==> %s\n' "tools/sprint-check-go"
  (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-check-go)
  printf '==> %s\n' "tools/sprint-headless-json-go"
  (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-headless-json-go)
else
  printf '==> %s\n' "tools/sprint-check-go skipped (go absent)"
  printf '==> %s\n' "tools/sprint-headless-json-go skipped (go absent)"
fi

if command -v node >/dev/null 2>&1; then
  printf '==> %s\n' "tests/sprint-check-gherkin.js"
  node "$ROOT/tests/sprint-check-gherkin.js"
  printf '==> %s\n' "tests/sprint-check-editor.js"
  node "$ROOT/tests/sprint-check-editor.js"
  printf '==> %s\n' "tests/sprint-check-seed.js"
  node "$ROOT/tests/sprint-check-seed.js"
else
  printf '==> %s\n' "tests/sprint-check-gherkin.js skipped (node absent)"
fi

printf '\nAll tests passed.\n'
