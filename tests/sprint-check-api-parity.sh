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
# t-74d6: a controlled cockpit state dir + fake on-disk daemon binary so the
# stale-detection parity case is deterministic (independent of any real daemon
# the dev machine may have running in the default /tmp/canon-cockpit-board).
CK_STATE="$(mktemp -d)"
CK_BIN="$(mktemp)"
CK_STUB_PID=""
PY_PID=""
GO_PID=""
# SPRINT_HEADLESS_BIN/SPRINT_HEADLESS_EVAL_BIN point both servers at throwaway
# temp stubs from the moment they start (t-1781) — the headless-run parity
# section below only ever rewrites these temp files' *content*, never the
# real tools/sprint-headless(-eval). Prior approach swapped the real file in
# place and relied on this trap-bound cleanup to restore it, which can't
# survive an uncatchable kill (SIGKILL) of this script mid-run — exactly how
# two evaluator subagent dispatches corrupted the real file (see research.md).
SPRINT_HEADLESS_BIN="$(mktemp)"
SPRINT_HEADLESS_EVAL_BIN="$(mktemp)"
chmod +x "$SPRINT_HEADLESS_BIN" "$SPRINT_HEADLESS_EVAL_BIN"
export SPRINT_HEADLESS_BIN SPRINT_HEADLESS_EVAL_BIN
# t-7485: hermetic stub for `skills.sh add sprint <dir>` so the register-skill
# endpoint's argv shell-out is exercised in BOTH backends WITHOUT running the
# real onboarding (which would write a git hook + touch ~/.config/canon). The
# stub only appends/upserts the AGENTS.md AI-SKILLS row, idempotently.
SKILLS_SH_BIN="$WORK/stub-skills.sh"
cat > "$SKILLS_SH_BIN" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "add" ] || exit 0
skill="${2:-sprint}"; dir="${3:-$PWD}"; af="$dir/AGENTS.md"
grep -q "^| $skill " "$af" 2>/dev/null && exit 0    # idempotent: row already present
if grep -q "AI-SKILLS:BEGIN" "$af" 2>/dev/null; then
  tmp="$(mktemp)"; awk -v r="| $skill | dev | /x/skills/$skill/SKILL.md |" '/AI-SKILLS:END/{print r} {print}' "$af" > "$tmp" && mv "$tmp" "$af"
else
  printf '<!-- AI-SKILLS:BEGIN -->\n## Active canon skills\n\n| Skill | Category | Source |\n|-------|----------|--------|\n| %s | dev | /x/skills/%s/SKILL.md |\n<!-- AI-SKILLS:END -->\n' "$skill" "$skill" >> "$af"
fi
STUB
chmod +x "$SKILLS_SH_BIN"
export SKILLS_SH_BIN
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  [[ -n "$CK_STUB_PID" ]] && kill "$CK_STUB_PID" 2>/dev/null || true
  rm -f "$SPRINT_HEADLESS_BIN" "$SPRINT_HEADLESS_EVAL_BIN" "$CK_BIN"
  rm -rf "$WORK" "$(dirname "$GO_BIN")" "$CK_STATE"
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

# Dedicated fixture for type_outcome parity (t-cdeb) — the generic per-key
# mismatch loop below covers the field itself; needs 2+ closed tickets of a
# shared type (the field's visibility threshold) plus an open ticket of that
# type to receive it, which the shared build_tickets_fixture doesn't provide.
mkdir -p "$WORK/.tickets/t-oc1" "$WORK/.tickets/t-oc2" "$WORK/.tickets/t-ocopen"
cat > "$WORK/.tickets/t-oc1/ticket.md" <<'EOF'
---
id: t-oc1
status: closed
type: chore
priority: 2
eval_fail_count: 0
created: 2026-06-08T00:00:00Z
---
# Closed clean chore fixture
EOF
cat > "$WORK/.tickets/t-oc2/ticket.md" <<'EOF'
---
id: t-oc2
status: closed
type: chore
priority: 2
eval_fail_count: 1
created: 2026-06-08T00:00:00Z
---
# Closed rework chore fixture
EOF
cat > "$WORK/.tickets/t-ocopen/ticket.md" <<'EOF'
---
id: t-ocopen
status: open
type: chore
priority: 2
created: 2026-06-08T00:00:00Z
---
# Open chore fixture, receives type_outcome
EOF

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

PY_PORT="$(free_port)"
GO_PORT="$(free_port)"

mkdir -p "$(dirname "$GO_BIN")"
# t-5c20: stamp the semver (VERSION file) so the Go board's /api/version matches
# server.py's runtime VERSION read (Go's toolsDir is a temp dir here, so its
# runtime VERSION lookup misses and falls back to this stamped value).
(cd "$ROOT" && GO111MODULE=off go build -ldflags "-X main.version=$(tr -d ' \t\n\r' < "$ROOT/VERSION")" -o "$GO_BIN" ./tools/sprint-check-go)

PY_CANON="$WORK/canon-py"
GO_CANON="$WORK/canon-go"

SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$PY_CANON" COCKPIT_STATE_DIR="$CK_STATE" COCKPIT_DAEMON_BIN="$CK_BIN" python3 "$SERVER_PY" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!
disown "$PY_PID" 2>/dev/null || true

SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$GO_CANON" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$CK_STATE" COCKPIT_DAEMON_BIN="$CK_BIN" "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
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
# Both servers were started with SPRINT_HEADLESS_BIN/SPRINT_HEADLESS_EVAL_BIN
# already pointed at the temp stubs above — just fill in their content so
# this never makes a real claude -p call. No real tools/ file is touched.

cat > "$SPRINT_HEADLESS_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "STUB-TOOL: full-pipeline"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
chmod +x "$SPRINT_HEADLESS_BIN"

# Stub sprint-headless-eval too, with a distinct marker, so the gate-mode
# dispatch selection (t-4e57) can be asserted: a gate:eval ticket must invoke
# this tool, a full ticket must invoke sprint-headless above.
cat > "$SPRINT_HEADLESS_EVAL_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "STUB-TOOL: eval-only"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
chmod +x "$SPRINT_HEADLESS_EVAL_BIN"

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

# ── create-with-skills parity (t-354b): POST /api/tickets writes an allowlisted, deduped skills line; absent otherwise ──
py_sk_id=""; go_sk_id=""
for be in "server.py:$PY_PORT" "main.go:$GO_PORT"; do
  label="${be%%:*}"; port="${be##*:}"
  sid="$(curl -s -X POST "http://127.0.0.1:$port/api/tickets" -d '{"title":"skills create","type":"chore","skills":"context-check,dead-code-cleanup,bogus,context-check"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  grep -q '^skills: context-check,dead-code-cleanup$' "$WORK/.tickets/$sid/ticket.md" || fail "sprint-check-api-parity: FAIL — $label create with skills did not write the allowlisted/deduped 'skills:' line ($sid)"
  grep -q 'bogus' "$WORK/.tickets/$sid/ticket.md" && fail "sprint-check-api-parity: FAIL — $label leaked a non-allowlisted skill ($sid)"
  ns="$(curl -s -X POST "http://127.0.0.1:$port/api/tickets" -d '{"title":"noskills create","type":"chore"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  if grep -q '^skills:' "$WORK/.tickets/$ns/ticket.md"; then fail "sprint-check-api-parity: FAIL — $label create without skills wrote a skills line ($ns)"; fi
  if [[ "$label" == "server.py" ]]; then py_sk_id="$sid"; else go_sk_id="$sid"; fi
done
py_sfm="$(grep '^skills:' "$WORK/.tickets/$py_sk_id/ticket.md")"
go_sfm="$(grep '^skills:' "$WORK/.tickets/$go_sk_id/ticket.md")"
[[ "$py_sfm" == "$go_sfm" ]] || fail "sprint-check-api-parity: FAIL — skills frontmatter mismatch: py=[$py_sfm] go=[$go_sfm]"

# ── create-with-demo parity (t-dfaa): POST /api/tickets writes demo: true; absent otherwise ──
py_demo_id=""; go_demo_id=""
for be in "server.py:$PY_PORT" "main.go:$GO_PORT"; do
  label="${be%%:*}"; port="${be##*:}"
  did="$(curl -s -X POST "http://127.0.0.1:$port/api/tickets" -d '{"title":"demo create","type":"task","demo":true}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  grep -q '^demo: true$' "$WORK/.tickets/$did/ticket.md" || fail "sprint-check-api-parity: FAIL — $label create with demo:true did not write 'demo: true' ($did)"
  nd="$(curl -s -X POST "http://127.0.0.1:$port/api/tickets" -d '{"title":"nodemo create","type":"task"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  if grep -q '^demo:' "$WORK/.tickets/$nd/ticket.md"; then fail "sprint-check-api-parity: FAIL — $label create without demo wrote a demo line ($nd)"; fi
  if [[ "$label" == "server.py" ]]; then py_demo_id="$did"; else go_demo_id="$did"; fi
done
# frontmatter byte-parity between backends for a demo ticket (ignore the naturally-differing id/title/created)
py_fm="$(awk '/^---$/{c++} c<2{print} c==2{print; exit}' "$WORK/.tickets/$py_demo_id/ticket.md" | grep -vE '^(id|title|created): ')"
go_fm="$(awk '/^---$/{c++} c<2{print} c==2{print; exit}' "$WORK/.tickets/$go_demo_id/ticket.md" | grep -vE '^(id|title|created): ')"
[[ "$py_fm" == "$go_fm" ]] || fail "sprint-check-api-parity: FAIL — demo frontmatter byte-mismatch between server.py and main.go:
py=[$py_fm]
go=[$go_fm]"

# ── demo-toggle parity (t-64a0): POST /api/ticket/<id>/demo ON inserts, OFF removes, byte-parity, idempotent ──
tog="$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/tickets" -d '{"title":"demo toggle","type":"task"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
grep -q '^demo:' "$WORK/.tickets/$tog/ticket.md" && fail "sprint-check-api-parity: FAIL — new toggle ticket unexpectedly has a demo line ($tog)"
# ON via server.py → demo: true present; capture result
curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/$tog/demo" -d '{"demo":true}' >/dev/null
grep -q '^demo: true$' "$WORK/.tickets/$tog/ticket.md" || fail "sprint-check-api-parity: FAIL — server.py demo toggle ON did not write 'demo: true' ($tog)"
py_tog="$(cat "$WORK/.tickets/$tog/ticket.md")"
# idempotent ON (server.py) — still exactly one demo line, ok:true
[[ "$(curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/$tog/demo" -d '{"demo":true}')" == '{"ok": true}' ]] || fail "sprint-check-api-parity: FAIL — server.py idempotent demo ON did not return ok:true ($tog)"
[[ "$(grep -c '^demo:' "$WORK/.tickets/$tog/ticket.md")" == "1" ]] || fail "sprint-check-api-parity: FAIL — server.py idempotent demo ON duplicated the demo line ($tog)"
# OFF via server.py → line removed
curl -s -X POST "http://127.0.0.1:$PY_PORT/api/ticket/$tog/demo" -d '{"demo":false}' >/dev/null
grep -q '^demo:' "$WORK/.tickets/$tog/ticket.md" && fail "sprint-check-api-parity: FAIL — server.py demo toggle OFF did not remove the demo line ($tog)"
# ON via main.go on the same ticket → must byte-match server.py's ON result
curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/$tog/demo" -d '{"demo":true}' >/dev/null
go_tog="$(cat "$WORK/.tickets/$tog/ticket.md")"
[[ "$py_tog" == "$go_tog" ]] || fail "sprint-check-api-parity: FAIL — demo toggle ON byte-mismatch server.py vs main.go:
py=[$py_tog]
go=[$go_tog]"
# OFF via main.go → line removed
curl -s -X POST "http://127.0.0.1:$GO_PORT/api/ticket/$tog/demo" -d '{"demo":false}' >/dev/null
grep -q '^demo:' "$WORK/.tickets/$tog/ticket.md" && fail "sprint-check-api-parity: FAIL — main.go demo toggle OFF did not remove the demo line ($tog)"
# strict-id guard: a non-t-xxxx id must not match the demo route (falls through to 404, no write)
for port in "$PY_PORT" "$GO_PORT"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/api/ticket/notaticket/demo" -d '{"demo":true}')"
  [[ "$code" == "404" ]] || fail "sprint-check-api-parity: FAIL — demo route accepted a non-t-xxxx id on port $port (status $code)"
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

# ── /api/worktrees ticket_present parity (t-2a1c): ticket-scoped physical
# presence of .tickets/<id> per worktree, mirroring the daemon's handleStart
# stat. Create a real sibling worktree — a checkout of HEAD, whose commits are
# empty so nothing under .tickets/ is materialized — so the non-main entry is
# ticket_present:false while the main checkout (which physically holds
# .tickets/t-mock on disk, untracked) is exempt → true. Without ?ticket the
# field must be absent (backward-compatible), identically in both backends.
WT_PARENT="$(mktemp -d)"
WT="$WT_PARENT/parity-wt"
git -C "$WORK" worktree add -q "$WT" -b parity-wt
py_wt="$(curl -s "http://127.0.0.1:$PY_PORT/api/worktrees?ticket=t-mock")"
go_wt="$(curl -s "http://127.0.0.1:$GO_PORT/api/worktrees?ticket=t-mock")"
py_wt_noticket="$(curl -s "http://127.0.0.1:$PY_PORT/api/worktrees")"
go_wt_noticket="$(curl -s "http://127.0.0.1:$GO_PORT/api/worktrees")"
python3 - "$py_wt" "$go_wt" "$py_wt_noticket" "$go_wt_noticket" <<'PY'
import json, sys
py, go, py_no, go_no = (json.loads(a) for a in sys.argv[1:5])
if py != go:
    print(f"sprint-check-api-parity: FAIL — /api/worktrees?ticket payload mismatch\n  py={py}\n  go={go}"); sys.exit(1)
main = [e for e in py if e.get("is_main")]
other = [e for e in py if not e.get("is_main")]
if not main or main[0].get("ticket_present") is not True:
    print(f"sprint-check-api-parity: FAIL — main checkout should report ticket_present=true: {main}"); sys.exit(1)
if not other or any(e.get("ticket_present") is not False for e in other):
    print(f"sprint-check-api-parity: FAIL — sibling worktree (no committed .tickets/) should report ticket_present=false: {other}"); sys.exit(1)
if py_no != go_no:
    print(f"sprint-check-api-parity: FAIL — /api/worktrees (no ticket) payload mismatch\n  py={py_no}\n  go={go_no}"); sys.exit(1)
if any("ticket_present" in e for e in py_no):
    print(f"sprint-check-api-parity: FAIL — ticket_present must be absent when no ticket is passed: {py_no}"); sys.exit(1)
PY
# Trailing-newline param parity (t-2a1c reviewer finding): `?ticket=t-abcd%0A`
# must be rejected identically — Python's `$` matches before a final \n but Go
# RE2's does not, so re.fullmatch is used server-side. Both backends must omit
# ticket_present here (invalid id → treated as no ticket).
py_wt_nl="$(curl -s "http://127.0.0.1:$PY_PORT/api/worktrees?ticket=t-abcd%0A")"
go_wt_nl="$(curl -s "http://127.0.0.1:$GO_PORT/api/worktrees?ticket=t-abcd%0A")"
python3 - "$py_wt_nl" "$go_wt_nl" <<'PY'
import json, sys
py, go = json.loads(sys.argv[1]), json.loads(sys.argv[2])
if py != go:
    print(f"sprint-check-api-parity: FAIL — /api/worktrees?ticket=<trailing-newline> payload mismatch\n  py={py}\n  go={go}"); sys.exit(1)
if any("ticket_present" in e for e in py):
    print(f"sprint-check-api-parity: FAIL — a trailing-newline ?ticket must be rejected (no ticket_present), got: {py}"); sys.exit(1)
PY

# ── /api/cockpit-docs parity (t-1357): plan/acceptance/HANDOFF read from the
# WORKTREE the session runs in, not the main checkout. Write those files ONLY
# into the sibling worktree; both backends must return them for that cwd, and
# reject a cwd that isn't a registered worktree (never read an arbitrary path).
mkdir -p "$WT/.tickets/t-mock"
printf '# Plan (worktree)\nWorktree plan body\n' > "$WT/.tickets/t-mock/plan.md"
printf '# Acceptance (worktree)\n' > "$WT/.tickets/t-mock/acceptance.md"
printf '## Current Focus\nWorktree handoff focus.\n' > "$WT/HANDOFF.md"
WT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$WT")"
py_cd="$(curl -s "http://127.0.0.1:$PY_PORT/api/cockpit-docs/t-mock?cwd=$WT_ENC")"
go_cd="$(curl -s "http://127.0.0.1:$GO_PORT/api/cockpit-docs/t-mock?cwd=$WT_ENC")"
python3 - "$py_cd" "$go_cd" <<'PY'
import json, sys
py, go = json.loads(sys.argv[1]), json.loads(sys.argv[2])
if py != go:
    print(f"sprint-check-api-parity: FAIL — /api/cockpit-docs payload mismatch\n  py={py}\n  go={go}"); sys.exit(1)
if "Worktree plan body" not in (py.get("plan") or ""):
    print(f"sprint-check-api-parity: FAIL — cockpit-docs did not return the worktree plan.md: {py}"); sys.exit(1)
if "Acceptance (worktree)" not in (py.get("acceptance") or ""):
    print(f"sprint-check-api-parity: FAIL — cockpit-docs did not return the worktree acceptance.md: {py}"); sys.exit(1)
if "Worktree handoff focus" not in (py.get("handoff") or ""):
    print(f"sprint-check-api-parity: FAIL — cockpit-docs did not return the worktree HANDOFF.md: {py}"); sys.exit(1)
PY
# reject a non-registered-worktree cwd (/tmp) and a missing cwd → 400 in both backends
for port in "$PY_PORT" "$GO_PORT"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/cockpit-docs/t-mock?cwd=%2Ftmp")"
  [[ "$code" == "400" ]] || fail "sprint-check-api-parity: FAIL — cockpit-docs accepted a non-worktree cwd on port $port (status $code)"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/cockpit-docs/t-mock")"
  [[ "$code" == "400" ]] || fail "sprint-check-api-parity: FAIL — cockpit-docs accepted a missing cwd on port $port (status $code)"
done
rm -rf "$WT/.tickets" "$WT/HANDOFF.md"
# stale worktree parity (t-1357): dir removed from disk but still registered in
# `git worktree list` must 400 identically in both backends (Python resolve
# strict / Go EvalSymlinks both fail on the missing path).
rm -rf "$WT"
for port in "$PY_PORT" "$GO_PORT"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/cockpit-docs/t-mock?cwd=$WT_ENC")"
  [[ "$code" == "400" ]] || fail "sprint-check-api-parity: FAIL — cockpit-docs did not 400 for a stale (removed) worktree on port $port (status $code)"
done

git -C "$WORK" worktree remove --force "$WT" 2>/dev/null || true
rm -rf "$WT_PARENT"

# ── /api/cockpit stale-detection parity (t-74d6) ───────────────────────────
# A stub daemon serves /healthz + /version{version,exe_mtime}; daemon.json in
# CK_STATE points both boards at it. Each board compares the stub's exe_mtime to
# CK_BIN's on-disk mtime — setting CK_BIN's mtime unequal/equal flips stale
# true/false. Both backends must agree on stale + running_build + latest_build.
CK_STUB_PORT="$(free_port)"
python3 - "$CK_STUB_PORT" 1000000000 <<'PY' >/dev/null 2>&1 &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, M = int(sys.argv[1]), int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
        elif self.path == '/version':
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
            self.wfile.write(json.dumps({'version': 'stub', 'exe_mtime': M}).encode())
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY
CK_STUB_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$CK_STUB_PORT/healthz" && break; sleep 0.1; done
printf '{"addr":"127.0.0.1:%s","token":"x"}' "$CK_STUB_PORT" > "$CK_STATE/daemon.json"

ck_cmp() {
  local want="$1" py go
  py="$(curl -s "http://127.0.0.1:$PY_PORT/api/cockpit")"
  go="$(curl -s "http://127.0.0.1:$GO_PORT/api/cockpit")"
  python3 - "$py" "$go" "$want" <<'PY'
import json, sys
py, go, want = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3] == 'true'
for k in ('stale', 'running_build', 'latest_build'):
    if py.get(k) != go.get(k):
        print(f"/api/cockpit {k} mismatch\n  py={py}\n  go={go}"); sys.exit(1)
if py.get('stale') is not want:
    print(f"/api/cockpit stale={py.get('stale')}, want {want}\n  py={py}"); sys.exit(1)
PY
}

python3 -c "import os,sys; os.utime(sys.argv[1], (1500000000, 1500000000))" "$CK_BIN"
ck_cmp true  || fail "sprint-check-api-parity: FAIL — /api/cockpit stale-true parity"
python3 -c "import os,sys; os.utime(sys.argv[1], (1000000000, 1000000000))" "$CK_BIN"
ck_cmp false || fail "sprint-check-api-parity: FAIL — /api/cockpit stale-false parity"

kill "$CK_STUB_PID" 2>/dev/null || true; CK_STUB_PID=""
rm -f "$CK_STATE/daemon.json"

# ── /api/version parity (t-5c20) ───────────────────────────────────────────
# Same shape {version, commit, daemon} in both backends, and an IDENTICAL
# semantic `version` (the VERSION file). `commit` is per-component provenance
# (build-time vs runtime, t-99fa) — not required to match.
pyv="$(curl -s "http://127.0.0.1:$PY_PORT/api/version")"
gov="$(curl -s "http://127.0.0.1:$GO_PORT/api/version")"
python3 - "$pyv" "$gov" "$(tr -d ' \t\n\r' < "$ROOT/VERSION")" <<'PY' || fail "sprint-check-api-parity: FAIL — /api/version parity"
import json, sys
py, go, semver = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
for k in ('version', 'commit', 'daemon'):
    if k not in py or k not in go:
        print(f"/api/version missing key {k}\n  py={py}\n  go={go}"); sys.exit(1)
if py['version'] != go['version']:
    print(f"/api/version semver mismatch py={py['version']} go={go['version']}"); sys.exit(1)
if py['version'] != semver:
    print(f"/api/version semver {py['version']} != VERSION file {semver}"); sys.exit(1)
PY

# ── /api/projects registry parity (t-9917) ─────────────────────────────────
# Add the SAME git dir to both backends, compare the POST responses + GET list
# + on-disk projects.json byte-for-byte, then DELETE and confirm empty on both.
REGPROJ="$WORK/regproj"
mkdir -p "$REGPROJ/.git"
py_add="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$REGPROJ\",\"description\":\"reg & parity < test >\"}" "http://127.0.0.1:$PY_PORT/api/projects")"
go_add="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$REGPROJ\",\"description\":\"reg & parity < test >\"}" "http://127.0.0.1:$GO_PORT/api/projects")"
# Compare SEMANTICALLY: server.py (json.dumps) and main.go (json.Marshal) differ
# only in whitespace across every endpoint; the byte-parity contract is the
# on-disk projects.json (checked below), matching how the other parity blocks compare.
python3 - "$py_add" "$go_add" <<'PY' || fail "sprint-check-api-parity: FAIL — /api/projects add response mismatch"
import json, sys
if json.loads(sys.argv[1]) != json.loads(sys.argv[2]): sys.exit(1)
PY

py_list="$(curl -s "http://127.0.0.1:$PY_PORT/api/projects")"
go_list="$(curl -s "http://127.0.0.1:$GO_PORT/api/projects")"
python3 - "$py_list" "$go_list" <<'PY' || fail "sprint-check-api-parity: FAIL — /api/projects list mismatch"
import json, sys
if json.loads(sys.argv[1]) != json.loads(sys.argv[2]): sys.exit(1)
PY

if ! diff -q "$PY_CANON/cockpit/projects.json" "$GO_CANON/cockpit/projects.json" >/dev/null; then
  fail "sprint-check-api-parity: FAIL — projects.json differs between backends"
fi

mkdir -p "$WORK/regplain"
py_err="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$WORK/regplain\",\"description\":\"x\"}" "http://127.0.0.1:$PY_PORT/api/projects")"
go_err="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$WORK/regplain\",\"description\":\"x\"}" "http://127.0.0.1:$GO_PORT/api/projects")"
python3 - "$py_err" "$go_err" <<'PY' || fail "sprint-check-api-parity: FAIL — /api/projects non-git error mismatch"
import json, sys
if json.loads(sys.argv[1]) != json.loads(sys.argv[2]): sys.exit(1)
PY

reg_id="$(printf '%s' "$py_list" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")"

# ── Phase 2a: project-scoped reads + stats + unknown-id 400 (t-a55a) ─────────
# regproj (registered above, id=reg_id) gets 2 tickets; a 2nd project gets 1.
# Assert /api/tickets?project=<id> is scoped per project, project-stats parity,
# and an unknown id → 400, on BOTH backends.
mkdir -p "$REGPROJ/.tickets/t-aaa1" "$REGPROJ/.tickets/t-aaa2"
printf '# t\n' > "$REGPROJ/.tickets/t-aaa1/ticket.md"
printf '# t\n' > "$REGPROJ/.tickets/t-aaa2/ticket.md"
REGPROJ2="$WORK/regproj2"; mkdir -p "$REGPROJ2/.git/x" "$REGPROJ2/.tickets/t-bbb1"
printf '# t\n' > "$REGPROJ2/.tickets/t-bbb1/ticket.md"
curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$REGPROJ2\",\"description\":\"p2\"}" "http://127.0.0.1:$PY_PORT/api/projects" >/dev/null
curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$REGPROJ2\",\"description\":\"p2\"}" "http://127.0.0.1:$GO_PORT/api/projects" >/dev/null
reg_id2="$(curl -s "http://127.0.0.1:$PY_PORT/api/projects" | python3 -c "import sys,json;d=json.load(sys.stdin);print([e['id'] for e in d if e['path'].endswith('regproj2')][0])")"

# scoped /api/tickets: regproj=2, regproj2=1 (both backends agree)
for port in "$PY_PORT" "$GO_PORT"; do
  n1="$(curl -s "http://127.0.0.1:$port/api/tickets?project=$reg_id" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"
  n2="$(curl -s "http://127.0.0.1:$port/api/tickets?project=$reg_id2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"
  [[ "$n1" == "2" && "$n2" == "1" ]] || fail "sprint-check-api-parity: FAIL — project-scoped /api/tickets wrong on port $port (regproj=$n1 want 2, regproj2=$n2 want 1)"
done

# scoped /api/handoff, /api/git, /api/doc, /api/why parity (T2): seed regproj with a
# HANDOFF + a ticket doc, then assert each read endpoint returns semantically-equal
# data across backends for ?project=$reg_id (the backends differ only in JSON whitespace).
( cd "$REGPROJ" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm init )
printf '# Handoff\n## Current Focus\nRegproj focus line for parity.\n' > "$REGPROJ/HANDOFF.md"
printf '# Acceptance\n## Criteria\n- [ ] regproj doc parity\n' > "$REGPROJ/.tickets/t-aaa1/acceptance.md"
scoped_parity() {
  local ep="$1"
  local py="$(curl -s "http://127.0.0.1:$PY_PORT$ep?project=$reg_id" 2>/dev/null)"
  local go="$(curl -s "http://127.0.0.1:$GO_PORT$ep?project=$reg_id" 2>/dev/null)"
  python3 - "$py" "$go" "$ep" <<'PY' || fail "sprint-check-api-parity: FAIL — scoped read parity mismatch"
import json,sys
py,go,ep=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    if json.loads(py)!=json.loads(go): print("scoped parity differ for",ep); sys.exit(1)
except Exception as e:
    print("scoped parity parse error for",ep,e,"py=",py[:200],"go=",go[:200]); sys.exit(1)
PY
}
scoped_parity "/api/handoff"
scoped_parity "/api/git"
scoped_parity "/api/why"   # ?project + no file → both return the "Enter a file path" shape
# /api/doc needs the doc path in the URL; assert both backends return regproj's own doc
py_doc="$(curl -s "http://127.0.0.1:$PY_PORT/api/doc/t-aaa1/acceptance.md?project=$reg_id")"
go_doc="$(curl -s "http://127.0.0.1:$GO_PORT/api/doc/t-aaa1/acceptance.md?project=$reg_id")"
python3 - "$py_doc" "$go_doc" <<'PY' || fail "sprint-check-api-parity: FAIL — scoped /api/doc parity mismatch"
import json,sys
py,go=json.loads(sys.argv[1]),json.loads(sys.argv[2])
assert py==go, f"doc differ {py} {go}"
assert "regproj doc parity" in py.get("content",""), f"doc not regproj-scoped: {py}"
PY
# /api/git scoped to regproj must report regproj as the project (not the server default)
py_gitproj="$(curl -s "http://127.0.0.1:$PY_PORT/api/git?project=$reg_id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["project"])')"
[[ "$py_gitproj" == "regproj" ]] || fail "sprint-check-api-parity: FAIL — scoped /api/git project should be regproj, got $py_gitproj"

# project-stats ticket_count parity + per-project
# project-stats ticket_count parity + per-project + t-7485 skills field.
# Seed regproj's AGENTS.md with an AI-SKILLS table so `skills` is exercised
# (both backends read the same on-disk file → identical list).
printf '# regproj\n<!-- AI-SKILLS:BEGIN -->\n## Active canon skills\n\n| Skill | Category | Source |\n|-------|----------|--------|\n| sprint | dev | /x/skills/sprint/SKILL.md |\n<!-- AI-SKILLS:END -->\n' > "$REGPROJ/AGENTS.md"
py_s1="$(curl -s "http://127.0.0.1:$PY_PORT/api/project-stats?project=$reg_id")"
go_s1="$(curl -s "http://127.0.0.1:$GO_PORT/api/project-stats?project=$reg_id")"
python3 - "$py_s1" "$go_s1" <<'PY' || fail "sprint-check-api-parity: FAIL — /api/project-stats parity/shape"
import json,sys
a,b=json.loads(sys.argv[1]),json.loads(sys.argv[2])
assert a==b, f"stats differ {a} {b}"
assert a["ticket_count"]==2, f"ticket_count {a} want 2"
assert "updated" in a
assert a.get("skills")==["sprint"], f'skills should be ["sprint"], got {a.get("skills")}'
PY
# t-7485: a project with no AGENTS.md → skills: [] on BOTH backends (parity).
py_s2="$(curl -s "http://127.0.0.1:$PY_PORT/api/project-stats?project=$reg_id2")"
go_s2="$(curl -s "http://127.0.0.1:$GO_PORT/api/project-stats?project=$reg_id2")"
python3 - "$py_s2" "$go_s2" <<'PY' || fail "sprint-check-api-parity: FAIL — skills empty-case parity ([] not null)"
import json,sys
a,b=json.loads(sys.argv[1]),json.loads(sys.argv[2])
assert a==b, f"stats differ {a} {b}"
assert a.get("skills")==[], f'no-AGENTS.md project should have skills [], got {a.get("skills")}'
PY

# unknown project id → 400 on both backends, for a scoped read
for port in "$PY_PORT" "$GO_PORT"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/tickets?project=deadbeef0000")"
  [[ "$code" == "400" ]] || fail "sprint-check-api-parity: FAIL — unknown project id should 400 on port $port (got $code)"
done

# no-param /api/tickets unchanged (still returns the server's default-project list)
py_np="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PY_PORT/api/tickets")"
[[ "$py_np" == "200" ]] || fail "sprint-check-api-parity: FAIL — no-param /api/tickets should still 200 (got $py_np)"

# ── Phase 2b-ii: project-scoped WRITES land in the tab's project (t-8485) ────
# create/status/doc with ?project=$reg_id (regproj) must write regproj's .tickets,
# NOT regproj2 and NOT the server's default project — on BOTH backends. Then a
# scoped write with an unknown id → 400, and a no-param create still targets the
# default project. Each backend has its own on-disk regproj tree ($REGPROJ is
# under $WORK, shared, so we assert per-backend via the id echoed back + on-disk).
for port in "$PY_PORT" "$GO_PORT"; do
  # scoped create → new ticket dir appears under regproj/.tickets
  before="$(ls "$REGPROJ/.tickets" | wc -l | tr -d ' ')"
  cid="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
        -d '{"title":"scoped write","type":"task","status":"open"}' \
        "http://127.0.0.1:$port/api/tickets?project=$reg_id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
  [[ -f "$REGPROJ/.tickets/$cid/ticket.md" ]] || fail "sprint-check-api-parity: FAIL — scoped create did not land in regproj on port $port (id=$cid)"
  [[ ! -e "$REGPROJ2/.tickets/$cid" ]] || fail "sprint-check-api-parity: FAIL — scoped create leaked into regproj2 on port $port"
  # scoped status flip → writes regproj's ACTIVE
  curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
       -d '{"status":"in_progress"}' "http://127.0.0.1:$port/api/ticket/$cid/status?project=$reg_id" >/dev/null
  [[ "$(cat "$REGPROJ/.tickets/ACTIVE" 2>/dev/null | tr -d '[:space:]')" == "$cid" ]] || fail "sprint-check-api-parity: FAIL — scoped status did not write regproj ACTIVE on port $port"
  # scoped doc write → under regproj/.tickets/<cid>/plan.md
  curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
       -d '{"content":"# Scoped plan\nport-'"$port"'"}' "http://127.0.0.1:$port/api/doc/$cid/plan.md?project=$reg_id" >/dev/null
  grep -q "Scoped plan" "$REGPROJ/.tickets/$cid/plan.md" || fail "sprint-check-api-parity: FAIL — scoped doc write did not land in regproj on port $port"
  # unknown project id → 400 on a scoped WRITE too
  wcode="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
          -d '{"status":"open"}' "http://127.0.0.1:$port/api/ticket/$cid/status?project=deadbeef0000")"
  [[ "$wcode" == "400" ]] || fail "sprint-check-api-parity: FAIL — scoped write with unknown id should 400 on port $port (got $wcode)"
done

# ── t-7485: register-skill endpoint parity ───────────────────────────────────
# Unknown ?project → 400 on both backends (registered-id-only). Then a real
# POST (via the hermetic SKILLS_SH_BIN stub) into regproj2 registers `sprint`:
# the AGENTS.md AI-SKILLS row appears and a re-POST is idempotent. Both backends
# behave identically. (regproj2's AGENTS.md was absent → skills:[] asserted above.)
for port in "$PY_PORT" "$GO_PORT"; do
  rcode="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
          -d '{}' "http://127.0.0.1:$port/api/register-skill?project=deadbeef0000")"
  [[ "$rcode" == "400" ]] || fail "sprint-check-api-parity: FAIL — register-skill unknown id should 400 on port $port (got $rcode)"
done
# register sprint into regproj2 (was skills:[]) and assert the row lands + ok:true
reg_ok="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$PY_PORT/api/register-skill?project=$reg_id2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ok"))')"
[[ "$reg_ok" == "True" ]] || fail "sprint-check-api-parity: FAIL — register-skill did not report ok (got $reg_ok)"
grep -q "^| sprint " "$REGPROJ2/AGENTS.md" || fail "sprint-check-api-parity: FAIL — register-skill did not add the sprint row to regproj2 AGENTS.md"
# idempotent: a second POST (via the Go backend) keeps exactly one sprint row
curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$GO_PORT/api/register-skill?project=$reg_id2" >/dev/null
[[ "$(grep -c '^| sprint ' "$REGPROJ2/AGENTS.md")" == "1" ]] || fail "sprint-check-api-parity: FAIL — register-skill not idempotent (duplicate sprint rows)"
# project-stats now reports the newly-registered skill on both backends
for port in "$PY_PORT" "$GO_PORT"; do
  sk="$(curl -s "http://127.0.0.1:$port/api/project-stats?project=$reg_id2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("skills"))')"
  [[ "$sk" == "['sprint']" ]] || fail "sprint-check-api-parity: FAIL — post-register skills wrong on port $port (got $sk)"
done

curl -s -X DELETE -H 'Origin: http://localhost' "http://127.0.0.1:$PY_PORT/api/projects/$reg_id2" >/dev/null
curl -s -X DELETE -H 'Origin: http://localhost' "http://127.0.0.1:$GO_PORT/api/projects/$reg_id2" >/dev/null
curl -s -X DELETE -H 'Origin: http://localhost' "http://127.0.0.1:$PY_PORT/api/projects/$reg_id" >/dev/null
curl -s -X DELETE -H 'Origin: http://localhost' "http://127.0.0.1:$GO_PORT/api/projects/$reg_id" >/dev/null
py_after="$(curl -s "http://127.0.0.1:$PY_PORT/api/projects")"
go_after="$(curl -s "http://127.0.0.1:$GO_PORT/api/projects")"
[[ "$py_after" == "[]" && "$go_after" == "[]" ]] || fail "sprint-check-api-parity: FAIL — /api/projects not empty after delete: py=$py_after go=$go_after"

echo "sprint-check-api-parity: ok ($route_count routes match; /api/tickets payload matches including models_used + gate; /api/ticket-image serves identical bytes and rejects traversal/non-image paths identically; /api/ticket-feature serves identical text and rejects traversal/non-feature/missing identically; /api/worktrees ticket_present matches (main exempt=true, blind worktree=false, absent without ?ticket); /api/cockpit stale-detection matches (stale true/false + running/latest build); /api/version shares shape {version,commit,daemon} + identical semver from VERSION; headless-run idle/running/done states match; gate:eval dispatches sprint-headless-eval and full dispatches sprint-headless, identically in both backends; create-with-gate writes gate: eval; /api/ci-workflow writes an identical canon-gate.yml from both backends and refuses-on-exists; /api/projects add/list/delete + on-disk projects.json byte-identical + non-git error parity, for $WORK fixture)"
