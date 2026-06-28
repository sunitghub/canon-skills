#!/usr/bin/env bash
# sprint-check-go-ui — Playwright parity checks against the Go sprint-check server

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v go >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-go-ui: go/node/curl absent — skipped"
  exit 0
fi

WORK="$(mktemp -d)"
PID=""
cleanup() { [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/.tickets"
git -C "$WORK" init -q

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

(
  cd "$ROOT"
  SPRINT_CHECK_ROOT="$WORK" SPRINT_CHECK_NO_BROWSER=1 GO111MODULE=off \
    go run ./tools/sprint-check-go "$PORT" >/dev/null 2>&1
) &
PID=$!
disown "$PID" 2>/dev/null || true

ready=0
for _ in $(seq 1 80); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/git"; then ready=1; break; fi
  sleep 0.1
done
[[ "$ready" -eq 1 ]] || fail "Go sprint-check server did not start on port $PORT"

html="$(curl -s "http://127.0.0.1:$PORT/")"
assert_contains "$html" "Archive ticket"
assert_contains "$html" "btn-ticket-next"

(
  cd "$ROOT"
  SPRINT_CHECK_BASE="http://127.0.0.1:$PORT" \
  SPRINT_CHECK_TEST_ROOT="$WORK" \
    npx playwright test tests/sprint-check-app.spec.js --grep "clicking an in-progress card|hovering the ready indicator|plan approach without sign-off|editing docs works for quoted numeric ticket ids|archive button|modal next"
)

printf 'sprint-check-go-ui: ok\n'
