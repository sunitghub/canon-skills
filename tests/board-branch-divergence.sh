#!/usr/bin/env bash
# board-branch-divergence — t-6328. With `.tickets/` tracked in git, a ticket
# whose status differs on a live worktree or an unmerged branch gets a
# `branch_divergence` field in /api/tickets, identically from server.py and
# main.go. Real git fixture, both backends.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

command -v python3 >/dev/null 2>&1 && command -v go >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v git >/dev/null 2>&1 || { echo "board-branch-divergence: skipped (python3/go/curl/git not all present)"; exit 0; }

WORK="$(mktemp -d)"
BIN_DIR="$(mktemp -d)"
PY_PID=""; GO_PID=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  rm -rf "$WORK" "$BIN_DIR" "${WORK}-worktrees"
}
trap cleanup EXIT

REPO="$WORK/repo"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.email t@t.com && git config user.name t
mk_ticket() { # id status
  mkdir -p ".tickets/$1"
  printf -- '---\nid: %s\nstatus: %s\ntype: task\npriority: 2\ncreated: 2026-09-23T00:00:00Z\n---\n# Ticket %s\n' "$1" "$2" "$1" > ".tickets/$1/ticket.md"
}
mk_ticket t-brch open   # closed on an unmerged branch
mk_ticket t-wtre open   # edited (uncommitted) in a live worktree
mk_ticket t-same open   # never differs
mk_ticket t-mrgd open   # closed on a branch that is then merged
git add -A && git commit -q -m base

git checkout -q -b sprint/t-brch
mk_ticket t-brch closed && git commit -q -am "close t-brch"
git checkout -q main

git checkout -q -b sprint/t-mrgd
mk_ticket t-mrgd closed && git commit -q -am "close t-mrgd"
git checkout -q main && git merge -q --no-ff sprint/t-mrgd -m merge

git worktree add -q "${WORK}-worktrees/sprint-t-wtre" -b sprint/t-wtre
mk_ticket t-wtre in_progress   # edit inside the worktree
# (cwd is REPO on main; mk_ticket wrote into REPO — redo inside the worktree)
git checkout -q -- .tickets/t-wtre/ticket.md
(cd "${WORK}-worktrees/sprint-t-wtre" && mk_ticket t-wtre in_progress)

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PY_PORT="$(free_port)"; GO_PORT="$(free_port)"
(cd "$ROOT" && GO111MODULE=off go build -o "$BIN_DIR/sc-go" ./tools/sprint-check-go)

export SPRINT_CHECK_DIVERGENCE_TTL=0
SPRINT_CHECK_ROOT="$REPO" CANON_HOME="$WORK/canon-py" python3 "$ROOT/tools/sprint-check-app/server.py" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!
disown "$PY_PID" 2>/dev/null || true
SPRINT_CHECK_ROOT="$REPO" CANON_HOME="$WORK/canon-go" SPRINT_CHECK_NO_BROWSER=1 "$BIN_DIR/sc-go" "$GO_PORT" >/dev/null 2>&1 &
GO_PID=$!
disown "$GO_PID" 2>/dev/null || true
for port in "$PY_PORT" "$GO_PORT"; do
  ok=""; for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/api/tickets" && ok=1 && break; sleep 0.1; done
  [[ -n "$ok" ]] || fail "server on port $port did not start"
done

div() { # port id -> compact JSON of branch_divergence or NONE
  curl -s "http://127.0.0.1:$1/api/tickets" | python3 -c '
import json,sys
t={x["id"]:x for x in json.load(sys.stdin)}[sys.argv[1]]
d=t.get("branch_divergence")
print(json.dumps(d,sort_keys=True) if d is not None else "NONE")' "$2"
}

check() { # id expected
  local py go
  py="$(div "$PY_PORT" "$1")"; go="$(div "$GO_PORT" "$1")"
  [[ "$py" == "$2" ]] || fail "server.py branch_divergence for $1: expected '$2', got '$py'"
  [[ "$go" == "$2" ]] || fail "main.go branch_divergence for $1: expected '$2', got '$go'"
}

# t-2241: `dirty` — t-wtre's edit is uncommitted, so "merged" alone would mislead.
check t-brch '{"branch": "sprint/t-brch", "dirty": false, "merged": false, "status": "closed", "where": "branch"}'
check t-wtre '{"branch": "sprint/t-wtre", "dirty": true, "merged": true, "status": "in_progress", "where": "worktree"}'
check t-same NONE
check t-mrgd NONE   # merged branch; AND the older unmerged sprint/t-brch holds a stale open copy of it — must not flag

# Status changes on main are honoured (cache disabled): once main also says closed, no divergence.
sed -i.bak 's/^status: open/status: closed/' .tickets/t-brch/ticket.md && rm -f .tickets/t-brch/ticket.md.bak
check t-brch NONE

# Non-git root: no field, no error.
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT" && (cd "$NOGIT" && mk_ticket t-ngit open)
NG_PORT="$(free_port)"
SPRINT_CHECK_ROOT="$NOGIT" CANON_HOME="$WORK/canon-ng" python3 "$ROOT/tools/sprint-check-app/server.py" "$NG_PORT" >/dev/null 2>&1 &
NG_PID=$!
disown "$NG_PID" 2>/dev/null || true
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$NG_PORT/api/tickets" && break; sleep 0.1; done
assert_eq NONE "$(div "$NG_PORT" t-ngit)"
kill "$NG_PID" 2>/dev/null || true

# TTL cache (here 60s): the scan of OTHER checkouts is cached (the comparison against main stays
# live), so deleting the branch inside the window still returns the cached answer — both backends.
sed -i.bak 's/^status: closed/status: open/' .tickets/t-brch/ticket.md && rm -f .tickets/t-brch/ticket.md.bak
CP_PORT="$(free_port)"; CG_PORT="$(free_port)"
SPRINT_CHECK_DIVERGENCE_TTL=60 SPRINT_CHECK_ROOT="$REPO" CANON_HOME="$WORK/canon-cp" python3 "$ROOT/tools/sprint-check-app/server.py" "$CP_PORT" >/dev/null 2>&1 &
CP_PID=$!; disown "$CP_PID" 2>/dev/null || true
SPRINT_CHECK_DIVERGENCE_TTL=60 SPRINT_CHECK_ROOT="$REPO" CANON_HOME="$WORK/canon-cg" SPRINT_CHECK_NO_BROWSER=1 "$BIN_DIR/sc-go" "$CG_PORT" >/dev/null 2>&1 &
CG_PID=$!; disown "$CG_PID" 2>/dev/null || true
for port in "$CP_PORT" "$CG_PORT"; do
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/api/tickets" && break; sleep 0.1; done
  [[ "$(div "$port" t-brch)" != NONE ]] || fail "cache test: expected divergence for t-brch on port $port"
done
git branch -q -D sprint/t-brch
for port in "$CP_PORT" "$CG_PORT"; do
  [[ "$(div "$port" t-brch)" != NONE ]] || fail "cache test: divergence should still be served from cache inside the TTL on port $port"
done
# ...and with the cache disabled the same deletion is seen immediately.
[[ "$(div "$PY_PORT" t-brch)" == NONE ]] || fail "TTL=0 server should see the deleted branch immediately"
[[ "$(div "$GO_PORT" t-brch)" == NONE ]] || fail "TTL=0 Go server should see the deleted branch immediately"
kill "$CP_PID" "$CG_PID" 2>/dev/null || true

# Branch cap: 10 unmerged branches each close a distinct ticket -> only the first 8 are scanned.
for i in 0 1 2 3 4 5 6 7 8 9; do
  git checkout -q -b "capb$i" main
  mk_ticket "t-cap$i" closed && git add -A && git commit -q -m "close t-cap$i"
  git checkout -q main
done
for i in 0 1 2 3 4 5 6 7 8 9; do mk_ticket "t-cap$i" open; done   # untracked on main
count_flagged() {
  curl -s "http://127.0.0.1:$1/api/tickets" | python3 -c '
import json,sys
print(sum(1 for t in json.load(sys.stdin) if t["id"].startswith("t-cap") and "branch_divergence" in t))'
}
assert_eq 8 "$(count_flagged "$PY_PORT")"
assert_eq 8 "$(count_flagged "$GO_PORT")"

# `.tickets/` gitignored: the scan is skipped outright, even if a branch force-added a differing copy.
IGN="$WORK/ignored"; mkdir -p "$IGN" && cd "$IGN"
git init -q -b main . && git config user.email t@t.com && git config user.name t
echo ".tickets/" > .gitignore && git add .gitignore && git commit -q -m base
git checkout -q -b b1 && mk_ticket t-ign closed && git add -f .tickets && git commit -q -m "force-add closed"
git checkout -q main && rm -rf .tickets && mk_ticket t-ign open
IP_PORT="$(free_port)"; IG_PORT="$(free_port)"
SPRINT_CHECK_ROOT="$IGN" CANON_HOME="$WORK/canon-ip" python3 "$ROOT/tools/sprint-check-app/server.py" "$IP_PORT" >/dev/null 2>&1 &
IP_PID=$!; disown "$IP_PID" 2>/dev/null || true
SPRINT_CHECK_ROOT="$IGN" CANON_HOME="$WORK/canon-ig" SPRINT_CHECK_NO_BROWSER=1 "$BIN_DIR/sc-go" "$IG_PORT" >/dev/null 2>&1 &
IG_PID=$!; disown "$IG_PID" 2>/dev/null || true
for port in "$IP_PORT" "$IG_PORT"; do
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/api/tickets" && break; sleep 0.1; done
  assert_eq NONE "$(div "$port" t-ign)"
done
kill "$IP_PID" "$IG_PID" 2>/dev/null || true

# Worktree cap: 10 more worktrees each edit a distinct tracked ticket; with sprint-t-wtre that is 11
# non-main worktrees, only the first 8 are scanned -> sprint-t-wtre + 7 of the new ones flagged.
cd "$REPO"
for i in 0 1 2 3 4 5 6 7 8 9; do mk_ticket "t-wc$i" open; done
git add -A && git commit -q -m "wc tickets"
for i in 0 1 2 3 4 5 6 7 8 9; do
  git worktree add -q "${WORK}-worktrees/wc$i" -b "wcb$i"
  (cd "${WORK}-worktrees/wc$i" && mk_ticket "t-wc$i" in_progress)
done
count_wc() {
  curl -s "http://127.0.0.1:$1/api/tickets" | python3 -c '
import json,sys
print(sum(1 for t in json.load(sys.stdin) if t["id"].startswith("t-wc") and "branch_divergence" in t))'
}
assert_eq 7 "$(count_wc "$PY_PORT")"
assert_eq 7 "$(count_wc "$GO_PORT")"
check t-wtre '{"branch": "sprint/t-wtre", "dirty": true, "merged": true, "status": "in_progress", "where": "worktree"}'

echo "board-branch-divergence: ok (unmerged branch, live worktree, unchanged, merged, main-catches-up, non-git, TTL cache, 8-branch cap, 8-worktree cap, gitignored-tickets skip — server.py == main.go)"
