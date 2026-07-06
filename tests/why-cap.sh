#!/usr/bin/env bash
# why-cap — tkt why and both board /api/why implementations cap matched
# tickets to the latest 10 (git-log order, most-recent-first) and report a
# "more" count when truncated, instead of unbounded output for high-churn
# files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# ── Build a fixture: 13 commits/tickets touching one shared file ────────────

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

git -C "$WORK" init -q
git -C "$WORK" config user.email "test@test.com"
git -C "$WORK" config user.name "test"

echo "hello" > "$WORK/shared.js"
git -C "$WORK" add shared.js
git -C "$WORK" commit -q -m "t-aaa1 initial add"
mkdir -p "$WORK/.tickets/t-aaa1"
cat > "$WORK/.tickets/t-aaa1/ticket.md" <<'EOF'
---
id: t-aaa1
status: closed
type: task
priority: 2
created: 2026-01-01T00:00:00Z
---
# Initial add
EOF

for i in bbb2 ccc3 ddd4 eee5 fff6 ggg7 hhh8 iii9 jjj0 kkk1 lll2 mmm3; do
  echo "change $i" >> "$WORK/shared.js"
  git -C "$WORK" add shared.js
  git -C "$WORK" commit -q -m "t-$i update shared.js"
  mkdir -p "$WORK/.tickets/t-$i"
  cat > "$WORK/.tickets/t-$i/ticket.md" <<EOF
---
id: t-$i
status: closed
type: task
priority: 2
created: 2026-01-01T00:00:00Z
---
# Update $i
EOF
done

# ── tkt why: exactly 10 shown, "+3 more, older" ──────────────────────────────

out="$(cd "$WORK" && "$ROOT/tools/tkt" why shared.js)"
shown_count="$(echo "$out" | grep -cE '^t-[a-z0-9]{4}' || true)"
assert_eq "10" "$shown_count"
assert_contains "$out" "+3 more, older"

# ── Regression: a file touched by <=10 tickets shows no truncation line ─────

echo "hello" > "$WORK/lonely.js"
git -C "$WORK" add lonely.js
git -C "$WORK" commit -q -m "t-aaa1 add lonely file"
out_small="$(cd "$WORK" && "$ROOT/tools/tkt" why lonely.js)"
assert_contains "$out_small" "t-aaa1"
if [[ "$out_small" == *"more, older"* ]]; then
  fail "unexpected truncation message for a file touched by only 1 ticket: $out_small"
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v go >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "why-cap: ok (CLI cap verified; board API parity skipped — python3/go/curl not all present)"
  exit 0
fi

# ── Both board /api/why implementations: identical capped result + more ─────

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

PY_PORT="$(free_port)"
GO_PORT="$(free_port)"

mkdir -p "$(dirname "$GO_BIN")"
(cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)

SPRINT_CHECK_ROOT="$WORK" python3 "$ROOT/tools/sprint-check-app/server.py" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!
disown "$PY_PID" 2>/dev/null || true

SPRINT_CHECK_ROOT="$WORK" SPRINT_CHECK_NO_BROWSER=1 "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
GO_PID=$!
disown "$GO_PID" 2>/dev/null || true

wait_for_port() {
  local port="$1" i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/why?file=shared.js" && return 0
    sleep 0.1
  done
  return 1
}
wait_for_port "$PY_PORT" || fail "server.py did not start on port $PY_PORT"
wait_for_port "$GO_PORT" || fail "main.go did not start on port $GO_PORT"

py_json="$(curl -s "http://127.0.0.1:$PY_PORT/api/why?file=shared.js")"
go_json="$(curl -s "http://127.0.0.1:$GO_PORT/api/why?file=shared.js")"

python3 - "$py_json" "$go_json" <<'PY'
import json
import sys

py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])

if py.get("more") != 3 or go.get("more") != 3:
    print(f"why-cap: FAIL — expected more=3 on both, got server.py={py.get('more')!r} main.go={go.get('more')!r}")
    sys.exit(1)

py_ids = [r["id"] for r in py.get("results", [])]
go_ids = [r["id"] for r in go.get("results", [])]

if len(py_ids) != 10 or len(go_ids) != 10:
    print(f"why-cap: FAIL — expected 10 results on both, got server.py={len(py_ids)} main.go={len(go_ids)}")
    sys.exit(1)

if py_ids != go_ids:
    print(f"why-cap: FAIL — server.py and main.go returned different capped id order")
    print(f"  server.py: {py_ids}")
    print(f"  main.go:   {go_ids}")
    sys.exit(1)
PY

# ── Regression on the board APIs too: a file touched by 1 ticket → more=0 ───

py_small_json="$(curl -s "http://127.0.0.1:$PY_PORT/api/why?file=lonely.js")"
go_small_json="$(curl -s "http://127.0.0.1:$GO_PORT/api/why?file=lonely.js")"

python3 - "$py_small_json" "$go_small_json" <<'PY'
import json
import sys

py = json.loads(sys.argv[1])
go = json.loads(sys.argv[2])

if py.get("more") != 0 or go.get("more") != 0:
    print(f"why-cap: FAIL — expected more=0 on both for a 1-ticket file, got server.py={py.get('more')!r} main.go={go.get('more')!r}")
    sys.exit(1)
PY

echo "why-cap: ok (tkt why caps to 10 + '+3 more, older'; server.py/main.go /api/why identical, capped to 10, more=3; both correctly report more=0 for a 1-ticket file)"
