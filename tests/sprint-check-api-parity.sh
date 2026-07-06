#!/usr/bin/env bash
# sprint-check-api-parity — assert server.py and main.go expose the same /api/
# routes, return equivalent /api/tickets payloads, and serve identical
# /api/ticket-image bytes (plus identical traversal/non-image rejection) for
# the same fixture.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
MAIN_GO="$ROOT/tools/sprint-check-go/main.go"

# Extract /api/ routes from server.py:
#   exact:  path == '/api/foo'
#   regex:  r'^/api/foo/
py_routes() {
  {
    grep -oE "path == '/api/[^']+'" "$SERVER_PY" | sed "s/path == '//;s/'$//" || true
    grep -oE "r'\^/api/[^'()\$\\\\]+" "$SERVER_PY" | sed "s/r'\^//" || true
  } | sed 's|/$||' | sort -u
}

# Extract /api/ routes from main.go:
#   exact:  case "/api/foo":
#   regex:  `^/api/foo/
go_routes() {
  {
    grep -oE 'case "/api/[^"]+"' "$MAIN_GO" | sed 's/case "//;s/"$//' || true
    grep -oE '`\^/api/[^`/()\$\\]+' "$MAIN_GO" | sed 's/`\^//' || true
  } | sed 's|/$||' | sort -u
}

py="$(py_routes)"
go="$(go_routes)"

if [[ "$py" != "$go" ]]; then
  echo "sprint-check-api-parity: FAIL — route mismatch between server.py and main.go"
  echo ""
  echo "In server.py only:"
  comm -23 <(echo "$py") <(echo "$go") | sed 's/^/  /'
  echo "In main.go only:"
  comm -13 <(echo "$py") <(echo "$go") | sed 's/^/  /'
  exit 1
fi

route_count="$(echo "$py" | wc -l | tr -d ' ')"

if ! command -v python3 >/dev/null 2>&1 || ! command -v go >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-api-parity: ok ($route_count routes match; payload check skipped — python3/go/curl not all present)"
  exit 0
fi

# ── Payload parity: same fixture .tickets/ dir, both servers, diff /api/tickets ──

WORK="$(mktemp -d)"
GO_BIN="$(mktemp -d)/sprint-check-go-bin"
PY_PID=""
GO_PID=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  rm -rf "$WORK" "$(dirname "$GO_BIN")"
}
trap cleanup EXIT

build_tickets_fixture "$WORK"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

PY_PORT="$(free_port)"
GO_PORT="$(free_port)"

mkdir -p "$(dirname "$GO_BIN")"
(cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)

SPRINT_CHECK_ROOT="$WORK" python3 "$SERVER_PY" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!
disown "$PY_PID" 2>/dev/null || true

SPRINT_CHECK_ROOT="$WORK" "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
GO_PID=$!
disown "$GO_PID" 2>/dev/null || true

wait_for_port() {
  local port="$1" i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/tickets" && return 0
    sleep 0.1
  done
  return 1
}
wait_for_port "$PY_PORT" || fail "server.py did not start on port $PY_PORT"
wait_for_port "$GO_PORT" || fail "main.go did not start on port $GO_PORT"

py_json="$(curl -s "http://127.0.0.1:$PY_PORT/api/tickets")"
go_json="$(curl -s "http://127.0.0.1:$GO_PORT/api/tickets")"

python3 - "$py_json" "$go_json" <<'PY'
import json
import sys

py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])

def norm(tickets):
    return {t["id"]: {k: v for k, v in t.items()} for t in tickets}

py_n, go_n = norm(py), norm(go)

if set(py_n) != set(go_n):
    print(f"sprint-check-api-parity: FAIL — /api/tickets ticket-id sets differ")
    print(f"  server.py: {sorted(py_n)}")
    print(f"  main.go:   {sorted(go_n)}")
    sys.exit(1)

mismatches = []
for tid in sorted(py_n):
    a, b = py_n[tid], go_n[tid]
    keys = set(a) | set(b)
    for k in sorted(keys):
        if a.get(k) != b.get(k):
            mismatches.append(f"  {tid}.{k}: server.py={a.get(k)!r} main.go={b.get(k)!r}")

if mismatches:
    print("sprint-check-api-parity: FAIL — /api/tickets payload mismatch between server.py and main.go")
    print("\n".join(mismatches))
    sys.exit(1)
PY


# ── /api/ticket-image parity: same fixture image, both servers, same bytes;
# traversal/non-image attempts rejected identically ──────────────────────────

# Dedicated ticket with a canonical t-[a-z0-9]{4} id — build_tickets_fixture's
# t-placeholder/t-ready are longer than 4 chars and would never match the
# route's ticket-id pattern, silently degenerating every check below into a
# 404==404 comparison instead of exercising the actual 200 success path.
mkdir -p "$WORK/.tickets/t-mock/mockups"
printf '\x89PNG\r\n\x1a\n' > "$WORK/.tickets/t-mock/mockups/test.png"
cat > "$WORK/.tickets/t-mock/ticket.md" <<'EOF'
---
id: t-mock
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Mock ticket for ticket-image parity
EOF

check_ticket_image() {
  local label="$1" py_status go_status
  py_status="$(curl -s -o /tmp/parity-py-img.$$ -w '%{http_code}' "http://127.0.0.1:$PY_PORT/api/ticket-image/$2")"
  go_status="$(curl -s -o /tmp/parity-go-img.$$ -w '%{http_code}' "http://127.0.0.1:$GO_PORT/api/ticket-image/$2")"
  if [[ "$py_status" != "$go_status" ]]; then
    rm -f /tmp/parity-py-img.$$ /tmp/parity-go-img.$$
    fail "sprint-check-api-parity: FAIL — $label status mismatch (server.py=$py_status main.go=$go_status)"
  fi
  if [[ "$py_status" == "200" ]] && ! cmp -s /tmp/parity-py-img.$$ /tmp/parity-go-img.$$; then
    rm -f /tmp/parity-py-img.$$ /tmp/parity-go-img.$$
    fail "sprint-check-api-parity: FAIL — $label served different bytes"
  fi
  rm -f /tmp/parity-py-img.$$ /tmp/parity-go-img.$$
}

check_ticket_image "valid image"              "t-mock/mockups/test.png"
check_ticket_image "traversal attempt"         "t-mock/../../../../etc/passwd"
check_ticket_image "non-image extension (real file, wrong ext)" "t-mock/ticket.md"
check_ticket_image "missing file"              "t-mock/mockups/does-not-exist.png"
check_ticket_image "malformed ticket id"       "t-ready/mockups/test.png"

echo "sprint-check-api-parity: ok ($route_count routes match; /api/tickets payload matches; /api/ticket-image serves identical bytes and rejects traversal/non-image paths identically, for $WORK fixture)"
