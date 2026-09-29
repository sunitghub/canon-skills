#!/usr/bin/env bash
# sprint-check-nongit — t-5a4b. A project folder that is not a git repository (and a machine with no
# `git` at all) gets the SAME honest /api/git answer from both boards: is_git false, no invented
# branch, no commits, nothing modified. Real servers, no git on PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

command -v python3 >/dev/null 2>&1 && command -v go >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "sprint-check-nongit: skipped (python3/go/curl not all present)"; exit 0; }

WORK="$(mktemp -d)"
BIN_DIR="$(mktemp -d)"
PY_PID=""; GO_PID=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  rm -rf "$WORK" "$BIN_DIR"
}
trap cleanup EXIT

PROJ="$WORK/pm-project"
mkdir -p "$PROJ/.tickets/t-ngit"
printf -- '---\nid: t-ngit\nstatus: open\ntype: task\npriority: 2\ncreated: 2026-09-29T00:00:00Z\n---\n# A ticket\n' > "$PROJ/.tickets/t-ngit/ticket.md"
printf 'draft\n' > "$PROJ/notes.md"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PY_PORT="$(free_port)"; GO_PORT="$(free_port)"
(cd "$ROOT" && GO111MODULE=off go build -o "$BIN_DIR/sc-go" ./tools/sprint-check-go)
PYTHON="$(command -v python3)"

# An empty PATH directory: no git for either server (a PM's machine).
NOGIT_PATH="$BIN_DIR/empty"; mkdir -p "$NOGIT_PATH"
env PATH="$NOGIT_PATH" SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$WORK/canon-py" "$PYTHON" "$ROOT/tools/sprint-check-app/server.py" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!; disown "$PY_PID" 2>/dev/null || true
env PATH="$NOGIT_PATH" SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$WORK/canon-go" SPRINT_CHECK_NO_BROWSER=1 "$BIN_DIR/sc-go" "$GO_PORT" >/dev/null 2>&1 &
GO_PID=$!; disown "$GO_PID" 2>/dev/null || true
for port in "$PY_PORT" "$GO_PORT"; do
  ok=""; for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && ok=1 && break; sleep 0.1; done
  [[ -n "$ok" ]] || fail "server on port $port did not start"
done

shape() { # port -> the honest fields, one JSON line
  curl -s "http://127.0.0.1:$1/api/git" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("branch","is_git","log","modified","total_commits")},sort_keys=True))'
}
py="$(shape "$PY_PORT")"; go="$(shape "$GO_PORT")"
want='{"branch": "", "is_git": false, "log": [], "modified": 0, "total_commits": null}'
assert_eq "$want" "$py"
assert_eq "$want" "$go"

# The ticket list still works with no git anywhere.
for port in "$PY_PORT" "$GO_PORT"; do
  curl -s "http://127.0.0.1:$port/api/tickets" | grep -q '"t-ngit"' || fail "port $port: /api/tickets lost the ticket with no git"
done

printf 'sprint-check-nongit: ok\n'
