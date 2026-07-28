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
    grep -oE 'path == "/api/[^"]+"' "$MAIN_GO" | sed 's/path == "//;s/"$//' || true
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
SPRINT_HEADLESS_EVAL_BACKUP=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  # Restore the real tools/sprint-headless(-eval) if the headless-run parity
  # section below swapped in stubs — must run even on failure, so this lives in
  # the trap-bound cleanup, not a linear post-check restore that set -e would skip.
  if [[ -n "$SPRINT_HEADLESS_BACKUP" ]]; then
    cp "$SPRINT_HEADLESS_BACKUP" "$ROOT/tools/sprint-headless"
    chmod +x "$ROOT/tools/sprint-headless"
    rm -f "$SPRINT_HEADLESS_BACKUP"
  fi
  if [[ -n "$SPRINT_HEADLESS_EVAL_BACKUP" ]]; then
    cp "$SPRINT_HEADLESS_EVAL_BACKUP" "$ROOT/tools/sprint-headless-eval"
    chmod +x "$ROOT/tools/sprint-headless-eval"
    rm -f "$SPRINT_HEADLESS_EVAL_BACKUP"
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

# Dedicated fixture for gate:eval parity (t-4e57) — the generic per-key mismatch
# loop below covers the field itself; a full ticket (absent gate) is already
# covered by every other fixture, so this only needs to exercise gate=eval.
mkdir -p "$WORK/.tickets/t-gate"
cat > "$WORK/.tickets/t-gate/ticket.md" <<'EOF'
---
id: t-gate
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
ci: true
gate: eval
---
# Eval-gate fixture
EOF
cat > "$WORK/.tickets/t-gate/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [ ] something holds
## Test Plan
- [ ] a check
## QA
- [ ] Tested locally
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

# ── POST /api/ticket/<id>/visual parity (t-626d): accept + reject cases ─────

VISUAL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

check_visual_upload() {
  local label="$1" body="$2" py_res go_res
  py_res="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/visual" -d "$body")"
  go_res="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/visual" -d "$body")"
  python3 - "$py_res" "$go_res" "$label" <<'PY'
import json, sys
py_res, go_res, label = sys.argv[1], sys.argv[2], sys.argv[3]
if json.loads(py_res) != json.loads(go_res):
    print(f"sprint-check-api-parity: FAIL — /visual {label} mismatch (server.py={py_res} main.go={go_res})")
    sys.exit(1)
PY
}

check_visual_upload "reject bad extension" "{\"filename\":\"x.txt\",\"data\":\"$VISUAL_PNG_B64\"}"
check_visual_upload "reject bad base64"    '{"filename":"x.png","data":"!!!not-base64!!!"}'
check_visual_upload "reject traversal"     "{\"filename\":\"../../x.png\",\"data\":\"$VISUAL_PNG_B64\"}"

# Oversized payload (>8MB decoded, the MAX_VISUAL_BYTES/maxVisualBytes cap) — built to a
# temp file rather than an inline -d string, since a >8MB base64 blob is too large for a
# shell argument/heredoc.
OVERSIZED_BODY="$(mktemp)"
{
  printf '{"filename":"x.png","data":"'
  head -c 9000000 /dev/zero | base64 | tr -d '\n'
  printf '"}'
} > "$OVERSIZED_BODY"
py_oversized="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/visual" --data-binary "@$OVERSIZED_BODY")"
go_oversized="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/visual" --data-binary "@$OVERSIZED_BODY")"
rm -f "$OVERSIZED_BODY"
python3 - "$py_oversized" "$go_oversized" <<'PY'
import json, sys
py_oversized, go_oversized = json.loads(sys.argv[1]), json.loads(sys.argv[2])
if py_oversized.get("ok") is not False:
    print(f"sprint-check-api-parity: FAIL — server.py accepted an oversized (>8MB) /visual upload: {sys.argv[1]}")
    sys.exit(1)
if go_oversized.get("ok") is not False:
    print(f"sprint-check-api-parity: FAIL — main.go accepted an oversized (>8MB) /visual upload: {sys.argv[2]}")
    sys.exit(1)
PY
if [[ -e "$WORK/.tickets/t-mock/visuals/x.png" ]]; then
  fail "sprint-check-api-parity: FAIL — oversized /visual upload wrote a file to disk"
fi

# Both servers share the same on-disk .tickets/ fixture, so uploads from one
# server are visible to the other — reset the visuals dir before each
# backend's own upload sequence, or py's write would shift go's auto-suffix
# (and vice versa) and the two responses would never actually match.
reset_visuals() { rm -rf "$WORK/.tickets/t-mock/visuals"; mkdir -p "$WORK/.tickets/t-mock/visuals"; }

reset_visuals
py_upload="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}")"
reset_visuals
go_upload="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}")"
python3 - "$py_upload" "$go_upload" <<'PY'
import json, sys
py_upload, go_upload = json.loads(sys.argv[1]), json.loads(sys.argv[2])
if py_upload.get("ok") is not True:
    print(f"sprint-check-api-parity: FAIL — server.py rejected a valid /visual upload: {sys.argv[1]}")
    sys.exit(1)
if go_upload.get("ok") is not True:
    print(f"sprint-check-api-parity: FAIL — main.go rejected a valid /visual upload: {sys.argv[2]}")
    sys.exit(1)
if py_upload != go_upload:
    print(f"sprint-check-api-parity: FAIL — /visual upload result mismatch (server.py={sys.argv[1]} main.go={sys.argv[2]})")
    sys.exit(1)
PY

# Same filename uploaded twice against the SAME backend must auto-suffix, never overwrite —
# checked independently per backend (each against its own freshly-reset dir), then compared.
reset_visuals
curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}" >/dev/null
py_dup="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}")"
reset_visuals
curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}" >/dev/null
go_dup="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}")"
python3 - "$py_dup" "$go_dup" <<'PY'
import json, sys
py_dup, go_dup = json.loads(sys.argv[1]), json.loads(sys.argv[2])
if py_dup != go_dup:
    print(f"sprint-check-api-parity: FAIL — /visual collision-suffix mismatch (server.py={sys.argv[1]} main.go={sys.argv[2]})")
    sys.exit(1)
if py_dup.get("filename") != "pasted-1-2.png":
    print(f"sprint-check-api-parity: FAIL — collision did not auto-suffix: {sys.argv[1]}")
    sys.exit(1)
PY
reset_visuals

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
echo "STUB-TOOL: full-pipeline"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
chmod +x "$ROOT/tools/sprint-headless"

# Stub sprint-headless-eval too, with a distinct marker, so the gate-mode
# dispatch selection (t-4e57) can be asserted: a gate:eval ticket must invoke
# this tool, a full ticket must invoke sprint-headless above.
SPRINT_HEADLESS_EVAL_BACKUP="$(mktemp)"
cp "$ROOT/tools/sprint-headless-eval" "$SPRINT_HEADLESS_EVAL_BACKUP"
cat > "$ROOT/tools/sprint-headless-eval" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "STUB-TOOL: eval-only"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
chmod +x "$ROOT/tools/sprint-headless-eval"

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
    if "STUB-TOOL: full-pipeline" not in d.get("output", ""):
        print(f"sprint-check-api-parity: FAIL — {label} full-gate ticket did not dispatch sprint-headless (full pipeline): {d}")
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

# ── gate-mode dispatch selection (t-4e57): a gate:eval ticket must invoke
# sprint-headless-eval; a full ticket (t-mock, above) invoked sprint-headless ─
py_gate_trig="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/t-gate/headless-run" -d '{"base_ref":"main"}')"
go_gate_trig="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/t-gate/headless-run" -d '{"base_ref":"main"}')"
[[ "$(echo "$py_gate_trig" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" == "running" ]] || fail "sprint-check-api-parity: FAIL — t-gate headless-run (server.py) did not start: $py_gate_trig"
[[ "$(echo "$go_gate_trig" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" == "running" ]] || fail "sprint-check-api-parity: FAIL — t-gate headless-run (main.go) did not start: $go_gate_trig"
sleep 3
py_gate_done="$(curl -s "http://127.0.0.1:$PY_PORT/api/ticket/t-gate/headless-run")"
go_gate_done="$(curl -s "http://127.0.0.1:$GO_PORT/api/ticket/t-gate/headless-run")"
python3 - "$py_gate_done" "$go_gate_done" <<'PY'
import json, sys
for label, raw in (("server.py", sys.argv[1]), ("main.go", sys.argv[2])):
    d = json.loads(raw)
    out = d.get("output", "")
    if "STUB-TOOL: eval-only" not in out:
        print(f"sprint-check-api-parity: FAIL — {label} gate:eval ticket did not dispatch sprint-headless-eval: {d}")
        sys.exit(1)
    if "STUB-TOOL: full-pipeline" in out:
        print(f"sprint-check-api-parity: FAIL — {label} gate:eval ticket wrongly dispatched the full pipeline: {d}")
        sys.exit(1)
PY

# ── create-with-gate parity (t-4e57): POST /api/tickets writes gate: eval ────
for be in "server.py:$PY_PORT" "main.go:$GO_PORT"; do
  label="${be%%:*}"; port="${be##*:}"
  eid="$(curl -s -X POST "http://127.0.0.1:$port/api/tickets" -d '{"title":"gate create","type":"task","ci":true,"gate":"eval"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  grep -q '^gate: eval$' "$WORK/.tickets/$eid/ticket.md" || fail "sprint-check-api-parity: FAIL — $label create with gate:eval did not write 'gate: eval' ($eid)"
  fid="$(curl -s -X POST "http://127.0.0.1:$port/api/tickets" -d '{"title":"full create","type":"task","ci":true}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  if grep -q '^gate:' "$WORK/.tickets/$fid/ticket.md"; then fail "sprint-check-api-parity: FAIL — $label full create wrote a gate line ($fid)"; fi
done

# ── /api/ci-workflow parity (t-344e): both write byte-identical canon-gate.yml + refuse-on-exists ─
# Both servers share $WORK, so exercise py fully (write + refuse), clear, then go.
rm -rf "$WORK/.github"
py_ci="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ci-workflow" -d '{}')"
py_written="$(cat "$WORK/.github/workflows/canon-gate.yml")"
py_ci2="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ci-workflow" -d '{}')"
rm -rf "$WORK/.github"
go_ci="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ci-workflow" -d '{}')"
go_written="$(cat "$WORK/.github/workflows/canon-gate.yml")"
go_ci2="$(curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ci-workflow" -d '{}')"
python3 - "$py_ci" "$go_ci" "$py_ci2" "$go_ci2" <<'PY'
import json, sys
py_ci, go_ci, py_ci2, go_ci2 = (json.loads(a) for a in sys.argv[1:5])
if py_ci.get("ok") is not True or go_ci.get("ok") is not True:
    print(f"sprint-check-api-parity: FAIL — ci-workflow create not ok (py={py_ci} go={go_ci})"); sys.exit(1)
if py_ci != go_ci:
    print(f"sprint-check-api-parity: FAIL — ci-workflow create JSON mismatch (py={py_ci} go={go_ci})"); sys.exit(1)
if py_ci2.get("ok") is not False or py_ci2.get("reason") != "exists":
    print(f"sprint-check-api-parity: FAIL — server.py ci-workflow did not refuse-on-exists: {py_ci2}"); sys.exit(1)
if py_ci2 != go_ci2:
    print(f"sprint-check-api-parity: FAIL — ci-workflow refuse-on-exists JSON mismatch (py={py_ci2} go={go_ci2})"); sys.exit(1)
PY
cmp -s "$WORK/.github/workflows/canon-gate.yml" "$ROOT/tools/canon-gate-template.yml" || fail "sprint-check-api-parity: FAIL — go-written canon-gate.yml differs from the shipped template"
[[ "$py_written" == "$go_written" ]] || fail "sprint-check-api-parity: FAIL — server.py and main.go wrote different canon-gate.yml content"
[[ "$py_written" == "$(cat "$ROOT/tools/canon-gate-template.yml")" ]] || fail "sprint-check-api-parity: FAIL — server.py-written canon-gate.yml differs from the shipped template"
rm -rf "$WORK/.github"

cp "$SPRINT_HEADLESS_BACKUP" "$ROOT/tools/sprint-headless"
chmod +x "$ROOT/tools/sprint-headless"
rm -f "$SPRINT_HEADLESS_BACKUP"
SPRINT_HEADLESS_BACKUP=""
cp "$SPRINT_HEADLESS_EVAL_BACKUP" "$ROOT/tools/sprint-headless-eval"
chmod +x "$ROOT/tools/sprint-headless-eval"
rm -f "$SPRINT_HEADLESS_EVAL_BACKUP"
SPRINT_HEADLESS_EVAL_BACKUP=""

# ── /api/ticket-feature parity (t-f89a): same fixture .feature, both servers,
# identical text; traversal/non-feature/missing rejected identically ──────────
mkdir -p "$WORK/.tickets/t-mock/features"
printf 'Scenario: parity\n  Given a\n  Then b\n' > "$WORK/.tickets/t-mock/features/spec.feature"

check_ticket_feature() {
  local label="$1" py_status go_status
  py_status="$(curl -s -o /tmp/parity-py-feat.$$ -w '%{http_code}' "http://127.0.0.1:$PY_PORT/api/ticket-feature/$2")"
  go_status="$(curl -s -o /tmp/parity-go-feat.$$ -w '%{http_code}' "http://127.0.0.1:$GO_PORT/api/ticket-feature/$2")"
  if [[ "$py_status" != "$go_status" ]]; then
    rm -f /tmp/parity-py-feat.$$ /tmp/parity-go-feat.$$
    fail "sprint-check-api-parity: FAIL — ticket-feature $label status mismatch (server.py=$py_status main.go=$go_status)"
  fi
  # This is a JSON endpoint: the two backends' encoders differ in whitespace and
  # HTML-escaping, so compare PARSED content (mirrors the /api/tickets approach),
  # never raw bytes. 404 bodies legitimately differ and aren't compared.
  if [[ "$py_status" == "200" ]]; then
    python3 - /tmp/parity-py-feat.$$ /tmp/parity-go-feat.$$ "$label" <<'PY'
import json, sys
py = json.load(open(sys.argv[1])); go = json.load(open(sys.argv[2]))
if py.get("content") != go.get("content"):
    print(f"sprint-check-api-parity: FAIL — ticket-feature {sys.argv[3]} content mismatch")
    sys.exit(1)
PY
  fi
  rm -f /tmp/parity-py-feat.$$ /tmp/parity-go-feat.$$
}

check_ticket_feature "valid feature"     "t-mock/features/spec.feature"
check_ticket_feature "traversal attempt" "t-mock/../../../../etc/passwd"
check_ticket_feature "non-feature ext"   "t-mock/ticket.md"
check_ticket_feature "missing file"      "t-mock/features/none.feature"

# Guard against a degenerate 404==404 pass: the valid case must be a real 200
# whose JSON {content} carries the file text.
py_feat_body="$(curl -s "http://127.0.0.1:$PY_PORT/api/ticket-feature/t-mock/features/spec.feature")"
python3 - "$py_feat_body" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if "Scenario: parity" not in d.get("content", ""):
    print(f"sprint-check-api-parity: FAIL — ticket-feature valid case did not return file text: {sys.argv[1]}")
    sys.exit(1)
PY
rm -rf "$WORK/.tickets/t-mock/features"

echo "sprint-check-api-parity: ok ($route_count routes match; /api/tickets payload matches including models_used + gate; /api/ticket-image serves identical bytes and rejects traversal/non-image paths identically; /api/ticket-feature serves identical text and rejects traversal/non-feature/missing identically; headless-run idle/running/done states match; gate:eval dispatches sprint-headless-eval and full dispatches sprint-headless, identically in both backends; create-with-gate writes gate: eval; /api/ci-workflow writes an identical canon-gate.yml from both backends and refuses-on-exists, for $WORK fixture)"
