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
build_tickets_fixture "$WORK"
mkdir -p "$WORK/.tickets/t-archived"
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

# t-cdeb: type_outcome aggregate fixture — 3 closed "chore" tickets (2 clean, 1 with
# eval_fail_count > 0) plus one open "chore" ticket to receive the aggregate, and a
# single-sample "epic" type (1 closed ticket only) to confirm the field stays absent
# below the 2-closed-ticket threshold.
mkdir -p "$WORK/.tickets/t-chore1" "$WORK/.tickets/t-chore2" "$WORK/.tickets/t-chore3" \
         "$WORK/.tickets/t-chore-open" "$WORK/.tickets/t-epic1" "$WORK/.tickets/t-epic-open"
cat > "$WORK/.tickets/t-chore1/ticket.md" <<'EOF'
---
id: t-chore1
status: closed
type: chore
priority: 2
eval_fail_count: 0
created: 2026-01-01T00:00:00Z
---
# Clean chore one
EOF
cat > "$WORK/.tickets/t-chore2/ticket.md" <<'EOF'
---
id: t-chore2
status: closed
type: chore
priority: 2
eval_fail_count: 2
created: 2026-01-01T00:00:00Z
---
# Chore that needed rework
EOF
cat > "$WORK/.tickets/t-chore3/ticket.md" <<'EOF'
---
id: t-chore3
status: closed
type: chore
priority: 2
eval_fail_count: 0
created: 2026-01-01T00:00:00Z
---
# Clean chore two
EOF
cat > "$WORK/.tickets/t-chore-open/ticket.md" <<'EOF'
---
id: t-chore-open
status: open
type: chore
priority: 2
created: 2026-01-01T00:00:00Z
---
# Open chore
EOF
cat > "$WORK/.tickets/t-epic1/ticket.md" <<'EOF'
---
id: t-epic1
status: closed
type: epic
priority: 2
eval_fail_count: 0
created: 2026-01-01T00:00:00Z
---
# Single closed epic
EOF
cat > "$WORK/.tickets/t-epic-open/ticket.md" <<'EOF'
---
id: t-epic-open
status: open
type: epic
priority: 2
created: 2026-01-01T00:00:00Z
---
# Open epic
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

# t-cdeb: type_outcome aggregate — 2 clean of 3 closed "chore" tickets, surfaced only on
# the open ticket of the same type; single-sample "epic" type stays below threshold
python3 - "$tickets_json" <<'PY'
import json
import sys

tickets = {t["id"]: t for t in json.loads(sys.argv[1])}
assert tickets["t-chore-open"]["type_outcome"] == {"closed": 3, "clean": 2}, \
    tickets["t-chore-open"].get("type_outcome")
assert tickets["t-epic-open"].get("type_outcome") is None, \
    "single-sample type must not surface type_outcome"
# closed tickets themselves never carry the field (badge only applies to open/in_progress cards)
assert "type_outcome" not in tickets["t-chore1"]
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

# status transition to in_progress claims ACTIVE; moving away from it (e.g. to open) clears it
curl -s -X POST "http://127.0.0.1:$PORT/api/ticket/t-placeholder/status" \
  -H 'Content-Type: application/json' -d '{"status":"in_progress"}' >/dev/null
[[ "$(cat "$WORK/.tickets/ACTIVE" 2>/dev/null)" == "t-placeholder" ]] || fail "ACTIVE not set after status -> in_progress"

curl -s -X POST "http://127.0.0.1:$PORT/api/ticket/t-placeholder/status" \
  -H 'Content-Type: application/json' -d '{"status":"open"}' >/dev/null
[[ ! -f "$WORK/.tickets/ACTIVE" ]] || fail "ACTIVE not cleared after status -> open"

printf 'sprint-check-server: ok\n'
