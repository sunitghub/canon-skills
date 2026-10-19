#!/usr/bin/env bash
# why-cap — tkt why and the board's /api/why (the Go board, t-15d8) cap matched
# tickets to the latest 10 (git-log order, most-recent-first) and report a
# "more" count when truncated, instead of unbounded output for high-churn
# files. Also covers the basename fallback: an exact-path miss searches all
# historically-tracked filenames by basename — unique match resolves and
# returns normal results, multiple matches list candidates (no auto-pick),
# zero matches keeps the original "no git history" message.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# ── Build a fixture: 13 commits/tickets touching one shared file ────────────

WORK="$(mktemp -d)"
BOARD_TMP="$(mktemp -d)"
GO_PID=""
cleanup() {
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  rm -rf "$WORK" "$BOARD_TMP"
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

# ── Basename fallback fixture: unique nested match + ambiguous duplicate ────

mkdir -p "$WORK/nested/dir"
echo "hello" > "$WORK/nested/dir/unique.js"
git -C "$WORK" add nested/dir/unique.js
git -C "$WORK" commit -q -m "t-aaa1 add nested unique file"

mkdir -p "$WORK/dupA" "$WORK/dupB"
echo "hello" > "$WORK/dupA/dup.js"
git -C "$WORK" add dupA/dup.js
git -C "$WORK" commit -q -m "t-aaa1 add dupA/dup.js"
echo "hello" > "$WORK/dupB/dup.js"
git -C "$WORK" add dupB/dup.js
git -C "$WORK" commit -q -m "t-aaa1 add dupB/dup.js"

# ── tkt why: basename fallback, unique match resolves like the full path ────

out_full="$(cd "$WORK" && "$ROOT/tools/tkt" why nested/dir/unique.js)"
out_basename="$(cd "$WORK" && "$ROOT/tools/tkt" why unique.js)"
assert_eq "$out_full" "$out_basename"

# ── tkt why: basename fallback, ambiguous match auto-resolves to most-committed ─

out_ambiguous="$(cd "$WORK" && "$ROOT/tools/tkt" why dup.js)"
assert_contains "$out_ambiguous" "dup.js"
if [[ "$out_ambiguous" == *"Multiple files"* ]]; then
  fail "ambiguous basename should auto-resolve, not refuse: $out_ambiguous"
fi

# ── tkt why: no basename match at all keeps the original message ───────────

out_none="$(cd "$WORK" && "$ROOT/tools/tkt" why totally-not-a-real-file.js)"
assert_contains "$out_none" "No git history found for: totally-not-a-real-file.js"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "why-cap: ok (CLI cap verified; board API skipped — python3/curl not both present)"
  exit 0
fi

# ── The board's /api/why: capped result + more ──────────────────────────────

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

GO_PORT="$(free_port)"
GO_BIN="$(build_board "$BOARD_TMP")"

SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$BOARD_TMP/canon" COCKPIT_STATE_DIR="$BOARD_TMP/ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_NO_BROWSER=1 \
  TMPDIR="$BOARD_TMP" "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
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
wait_for_port "$GO_PORT" || fail "main.go did not start on port $GO_PORT"

why() { curl -s "http://127.0.0.1:$GO_PORT/api/why?file=$1"; }

# the latest 10 in git-log order, most recent first (was checked as py == go before t-15d8)
python3 - "$(why shared.js)" <<'PY'
import json, sys
go = json.loads(sys.argv[1])
ids = [r["id"] for r in go.get("results", [])]
want = ["t-mmm3", "t-lll2", "t-kkk1", "t-jjj0", "t-iii9", "t-hhh8", "t-ggg7", "t-fff6", "t-eee5", "t-ddd4"]
assert go.get("more") == 3, f"why-cap: FAIL — expected more=3, got {go.get('more')!r}"
assert ids == want, f"why-cap: FAIL — capped ids/order: got {ids}, want {want}"
PY

# ── Regression on the board API too: a file touched by 1 ticket → more=0 ───

python3 - "$(why lonely.js)" <<'PY'
import json, sys
go = json.loads(sys.argv[1])
assert go.get("more") == 0, f"why-cap: FAIL — expected more=0 for a 1-ticket file, got {go.get('more')!r}"
PY

# ── The board API: basename fallback (unique + ambiguous + none) ────────────

python3 - "$(why unique.js)" "$(why nested/dir/unique.js)" <<'PY'
import json, sys
basename, full = (json.loads(a) for a in sys.argv[1:3])
assert basename.get("file") == "unique.js", f"why-cap: FAIL — basename fallback must echo the typed query in 'file', got {basename.get('file')!r}"
assert basename.get("results"), "why-cap: FAIL — basename fallback returned no results"
assert [r["id"] for r in basename["results"]] == [r["id"] for r in full.get("results", [])], \
    "why-cap: FAIL — basename fallback result differs from querying the full path directly"
PY

python3 - "$(why dup.js)" <<'PY'
import json, sys
resp = json.loads(sys.argv[1])
assert resp.get("results"), "why-cap: FAIL — ambiguous basename should auto-resolve and return results"
assert resp.get("resolved_path"), "why-cap: FAIL — ambiguous basename should include resolved_path"
assert resp.get("alternatives"), "why-cap: FAIL — ambiguous basename should include alternatives"
PY

python3 - "$(why totally-not-a-real-file.js)" <<'PY'
import json, sys
resp = json.loads(sys.argv[1])
assert "No git history found" in resp.get("message", ""), f"why-cap: FAIL — no-match message regressed: {resp.get('message')!r}"
PY

echo "why-cap: ok (tkt why caps to 10 + '+3 more, older'; the board's /api/why capped to 10 in git-log order, more=3; more=0 for a 1-ticket file; basename fallback verified unique/ambiguous/none across tkt and the board)"
