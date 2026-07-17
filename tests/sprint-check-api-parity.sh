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
SPRINT_HEADLESS_BACKUP=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  # Restore the real tools/sprint-headless if the headless-run parity section
  # below swapped in a stub — must run even on failure, so this lives in the
  # trap-bound cleanup, not a linear post-check restore that set -e would skip.
  if [[ -n "$SPRINT_HEADLESS_BACKUP" ]]; then
    cp "$SPRINT_HEADLESS_BACKUP" "$ROOT/tools/sprint-headless"
    chmod +x "$ROOT/tools/sprint-headless"
    rm -f "$SPRINT_HEADLESS_BACKUP"
  fi
  rm -rf "$WORK" "$(dirname "$GO_BIN")"
}
trap cleanup EXIT

build_tickets_fixture "$WORK"

# Real git history so /api/git's total_commits parity check (below) exercises
# the actual git rev-list path, not just both backends agreeing on null.
(cd "$WORK" && git init -q && git config user.email "t@t.com" && git config user.name "t" \
  && git commit -q --allow-empty -m "first" && git commit -q --allow-empty -m "second")

# Dedicated fixture for models_used parity (t-a19e) — not added to the shared
# build_tickets_fixture helper since other tests assert against its exact
# ticket set/content; a standalone ticket here keeps this check isolated.
mkdir -p "$WORK/.tickets/t-model"
cat > "$WORK/.tickets/t-model/ticket.md" <<'EOF'
---
id: t-model
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Model mention fixture
EOF
cat > "$WORK/.tickets/t-model/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Has criteria
- [x] Mentions the convention itself, e.g. `(model: <model>)`, in prose — not a real usage (t-1720 false-positive regression)

## Test Plan
- [x] Has tests

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| reviewer | ran | verdict: YES (model: claude-sonnet-5) |
| eval | ran | verdict: pass (model: HAIKU) |
EOF

# Dedicated fixture for ci: true/false parity (t-978c) — the generic
# per-key mismatch loop below already covers this field, no special-cased
# assertion needed (unlike models_used, which tests extraction logic, not
# just field equality).
mkdir -p "$WORK/.tickets/t-cion" "$WORK/.tickets/t-cioff"
cat > "$WORK/.tickets/t-cion/ticket.md" <<'EOF'
---
id: t-cion
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
ci: true
---
# CI-eligible fixture
EOF
cat > "$WORK/.tickets/t-cioff/ticket.md" <<'EOF'
---
id: t-cioff
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Non-CI fixture (ci field absent)
EOF

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

SPRINT_CHECK_ROOT="$WORK" SPRINT_CHECK_NO_BROWSER=1 "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
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

# t-1720 regression: a Criteria line describing the (model: X) convention itself
# must never leak into models_used — only real Wrapup Gates rows count. Exact-equality
# (not just "doesn't contain <model>") so any other stray extraction fails loud too.
models = py_n["t-model"]["models_used"]
if models != ["claude-sonnet-5", "haiku"]:
    print(f"sprint-check-api-parity: FAIL — t-1720 regression, t-model.models_used should be exactly ['claude-sonnet-5', 'haiku'], got {models!r}")
    sys.exit(1)
PY

# ── /api/git total_commits parity (t-9cde) ──────────────────────────────────
py_git="$(curl -s "http://127.0.0.1:$PY_PORT/api/git")"
go_git="$(curl -s "http://127.0.0.1:$GO_PORT/api/git")"

python3 - "$py_git" "$go_git" <<'PY'
import json
import sys

py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])

py_total, go_total = py.get("total_commits"), go.get("total_commits")
if py_total != go_total:
    print(f"sprint-check-api-parity: FAIL — /api/git total_commits mismatch: server.py={py_total!r} main.go={go_total!r}")
    sys.exit(1)
if not isinstance(py_total, int) or py_total != 2:
    print(f"sprint-check-api-parity: FAIL — /api/git total_commits should be 2 (fixture has 2 commits), got {py_total!r}")
    sys.exit(1)
PY


# ── /api/ticket-image parity: same fixture image, both servers, same bytes;
# traversal/non-image attempts rejected identically ──────────────────────────

# Dedicated ticket with a canonical t-[a-z0-9]{4} id — build_tickets_fixture's
# t-placeholder/t-ready are longer than 4 chars and would never match the
# route's ticket-id pattern, silently degenerating every check below into a
# 404==404 comparison instead of exercising the actual 200 success path.
mkdir -p "$WORK/.tickets/t-mock/visuals"
printf '\x89PNG\r\n\x1a\n' > "$WORK/.tickets/t-mock/visuals/test.png"
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

check_ticket_image "valid image"              "t-mock/visuals/test.png"
check_ticket_image "traversal attempt"         "t-mock/../../../../etc/passwd"
check_ticket_image "non-image extension (real file, wrong ext)" "t-mock/ticket.md"
check_ticket_image "missing file"              "t-mock/visuals/does-not-exist.png"
check_ticket_image "malformed ticket id"       "t-ready/visuals/test.png"

# ── /api/ticket/<id>/headless-run parity (t-200b): trigger + poll shape ─────
# Both servers reference tools/sprint-headless via a path relative to their
# own file location (never $PATH) — temporarily swap the real script for a
# stub so this never makes a real claude -p call. Restored by cleanup()
# above even on failure, since set -e would skip a linear restore here.

SPRINT_HEADLESS_BACKUP="$(mktemp)"
cp "$ROOT/tools/sprint-headless" "$SPRINT_HEADLESS_BACKUP"
cat > "$ROOT/tools/sprint-headless" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "stub grading output"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
chmod +x "$ROOT/tools/sprint-headless"

py_idle="$(curl -s "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/headless-run")"
go_idle="$(curl -s "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/headless-run")"
if [[ "$(echo "$py_idle" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" != "idle" ]] || \
   [[ "$(echo "$go_idle" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" != "idle" ]]; then
  fail "sprint-check-api-parity: FAIL — headless-run idle-state status mismatch (py=$py_idle go=$go_idle)"
fi

py_trigger="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/headless-run" -d '{"base_ref":"main"}')"
go_trigger="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/headless-run" -d '{"base_ref":"main"}')"
py_status="$(echo "$py_trigger" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
go_status="$(echo "$go_trigger" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
if [[ "$py_status" != "running" || "$go_status" != "running" ]]; then
  fail "sprint-check-api-parity: FAIL — headless-run trigger did not return status=running (py=$py_trigger go=$go_trigger)"
fi

# ── headless_running field on /api/tickets (t-dd51) ─────────────────────────
py_tickets_running="$(curl -s "http://127.0.0.1:$PY_PORT/api/tickets?all=1")"
go_tickets_running="$(curl -s "http://127.0.0.1:$GO_PORT/api/tickets?all=1")"
python3 - "$py_tickets_running" "$go_tickets_running" <<'PY'
import json, sys
py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])
for label, tickets in (("server.py", py), ("main.go", go)):
    t = next((t for t in tickets if t.get("id") == "t-mock"), None)
    if not t or t.get("headless_running") is not True:
        print(f"sprint-check-api-parity: FAIL — {label} /api/tickets missing headless_running=true for t-mock while run is in progress: {t}")
        sys.exit(1)
PY

sleep 3
py_done="$(curl -s "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/headless-run")"
go_done="$(curl -s "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/headless-run")"
python3 - "$py_done" "$go_done" <<'PY'
import json, sys
py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])
for label, d in (("server.py", py), ("main.go", go)):
    if d.get("status") != "done":
        print(f"sprint-check-api-parity: FAIL — {label} headless-run did not reach status=done: {d}")
        sys.exit(1)
    if "HEADLESS_VERDICT: PASS" not in d.get("output", ""):
        print(f"sprint-check-api-parity: FAIL — {label} headless-run output missing expected verdict: {d}")
        sys.exit(1)
    if d.get("exit_code") != 0:
        print(f"sprint-check-api-parity: FAIL — {label} headless-run exit_code should be 0, got {d.get('exit_code')!r}")
        sys.exit(1)
PY

py_tickets_done="$(curl -s "http://127.0.0.1:$PY_PORT/api/tickets?all=1")"
go_tickets_done="$(curl -s "http://127.0.0.1:$GO_PORT/api/tickets?all=1")"
python3 - "$py_tickets_done" "$go_tickets_done" <<'PY'
import json, sys
py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])
for label, tickets in (("server.py", py), ("main.go", go)):
    t = next((t for t in tickets if t.get("id") == "t-mock"), None)
    if t and t.get("headless_running"):
        print(f"sprint-check-api-parity: FAIL — {label} /api/tickets still reports headless_running after run completed: {t}")
        sys.exit(1)
PY

cp "$SPRINT_HEADLESS_BACKUP" "$ROOT/tools/sprint-headless"
chmod +x "$ROOT/tools/sprint-headless"
rm -f "$SPRINT_HEADLESS_BACKUP"
SPRINT_HEADLESS_BACKUP=""

echo "sprint-check-api-parity: ok ($route_count routes match; /api/tickets payload matches including models_used extraction; /api/ticket-image serves identical bytes and rejects traversal/non-image paths identically; headless-run idle/running/done states match, for $WORK fixture)"
