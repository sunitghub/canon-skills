#!/usr/bin/env bash
# sprint-check-server — Host allowlist + no cross-origin CORS on the board API

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-server: python3/curl absent — skipped"
  exit 0
fi

SERVER="$ROOT/tools/sprint-check-app/server.py"
WORK="$(mktemp -d)"
PID=""
cleanup() { [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/.tickets"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

SPRINT_CHECK_ROOT="$WORK" python3 "$SERVER" "$PORT" >/dev/null 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true   # silence the shell's job-kill notice on cleanup

# wait for the port to accept connections
ready=0
for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/git"; then ready=1; break; fi
  sleep 0.1
done
[[ "$ready" -eq 1 ]] || fail "server did not start on port $PORT"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# legit Host (curl default Host is 127.0.0.1:PORT) → 200
assert_eq "200" "$(code "http://127.0.0.1:$PORT/api/git")"

# explicit localhost Host → 200
assert_eq "200" "$(code -H 'Host: localhost' "http://127.0.0.1:$PORT/api/git")"

# foreign Host (DNS-rebinding) → 403
assert_eq "403" "$(code -H 'Host: evil.example.com' "http://127.0.0.1:$PORT/api/git")"

# no Access-Control-Allow-Origin header on GET
hdrs="$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/api/git")"
[[ "$hdrs" != *"Access-Control-Allow-Origin"* ]] || fail "ACAO header should be absent"

printf 'sprint-check-server: ok\n'
