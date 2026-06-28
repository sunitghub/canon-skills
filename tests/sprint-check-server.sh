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
mkdir -p "$WORK/.tickets/t-placeholder" "$WORK/.tickets/t-ready" "$WORK/.tickets/t-archived"
cat > "$WORK/.tickets/t-placeholder/ticket.md" <<'EOF'
---
id: t-placeholder
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Placeholder plan
EOF
cat > "$WORK/.tickets/t-placeholder/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Has criteria

## Test Plan
- [x] Has tests
EOF
cat > "$WORK/.tickets/t-placeholder/plan.md" <<'EOF'
# Plan

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->

## Decisions
EOF
cat > "$WORK/.tickets/t-ready/ticket.md" <<'EOF'
---
id: t-ready
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Ready plan
EOF
cat > "$WORK/.tickets/t-ready/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Has criteria

## Test Plan
- [x] Has tests
EOF
cat > "$WORK/.tickets/t-ready/plan.md" <<'EOF'
# Plan

## Sign-off
- [x] Plan approved

## Approach
Use the smallest board-side check that catches untouched templates.

## Decisions
EOF

cat > "$WORK/.tickets/t-archived/ticket.md" <<'EOF'
---
id: t-archived
status: archived
type: task
priority: 2
created: 2026-01-01T00:00:00Z
---
# Old closed work
EOF

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

tickets_json="$(curl -s "http://127.0.0.1:$PORT/api/tickets")"
python3 - "$tickets_json" <<'PY'
import json
import sys

tickets = {t["id"]: t for t in json.loads(sys.argv[1])}
assert tickets["t-placeholder"]["acceptance_has_items"] is True
assert tickets["t-placeholder"]["plan_has_approach"] is False
assert tickets["t-placeholder"]["plan_approved"] is False
assert tickets["t-ready"]["acceptance_has_items"] is True
assert tickets["t-ready"]["plan_has_approach"] is True
assert tickets["t-ready"]["plan_approved"] is True
# archived ticket excluded from default response
assert "t-archived" not in tickets, "archived ticket must not appear in default /api/tickets"
PY

# archived ticket included with ?all=1
tickets_all_json="$(curl -s "http://127.0.0.1:$PORT/api/tickets?all=1")"
python3 - "$tickets_all_json" <<'PY'
import json
import sys

tickets = {t["id"]: t for t in json.loads(sys.argv[1])}
assert "t-archived" in tickets, "archived ticket must appear in /api/tickets?all=1"
assert tickets["t-archived"]["status"] == "archived"
PY

printf 'sprint-check-server: ok\n'
