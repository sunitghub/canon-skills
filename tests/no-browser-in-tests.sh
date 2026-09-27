#!/usr/bin/env bash
# no-browser-in-tests — every test script that starts the Go board server must set
# SPRINT_CHECK_NO_BROWSER=1 (t-269d).
#
# The Go server opens the developer's real browser at startup (`open`/`xdg-open`,
# tools/sprint-check-go/main.go) unless that variable is set. Two scripts forgot it and every
# suite run opened real tabs pointing at ports that died seconds later (~26 accumulated in one
# session). scripts/test.sh exports the variable for the suite; this keeps each script safe when
# run by hand, and fails when a NEW script starts the Go server without it.
#
# File-level on purpose: a start spans continuation lines in several scripts, so "the setting
# appears in the file" avoids brittle line-window parsing while still catching a script that
# forgot it entirely.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${NO_BROWSER_TESTS_DIR:-$ROOT/tests}"   # overridable so the guard can be reverted on a scratch copy
SELF="$(basename "${BASH_SOURCE[0]}")"

# Ways a test starts the Go board server: the built binary ($GO_BIN, sc-go, sprint-check-go[-bin])
# or `go run` of the package.
START_RE='"\$GO_BIN" "|/sc-go" |/sprint-check-go" |go run \./tools/sprint-check-go'

offenders=""
checked=0
for f in "$TESTS_DIR"/*.sh; do
  [[ "$(basename "$f")" == "$SELF" ]] && continue
  grep -qE "$START_RE" "$f" || continue
  checked=$((checked + 1))
  grep -q 'SPRINT_CHECK_NO_BROWSER=1' "$f" || offenders="$offenders $(basename "$f")"
done

[[ "$checked" -gt 0 ]] || { echo "FAIL: no test script starting the Go server was found — the match pattern is stale (t-269d)" >&2; exit 1; }
if [[ -n "$offenders" ]]; then
  echo "FAIL: these tests start the Go board server without SPRINT_CHECK_NO_BROWSER=1, so each run opens real browser tabs:$offenders" >&2
  exit 1
fi
echo "no-browser-in-tests: ok ($checked scripts start the Go server; all set SPRINT_CHECK_NO_BROWSER=1)"
