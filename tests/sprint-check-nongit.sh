#!/usr/bin/env bash
# sprint-check-nongit — t-5a4b. A project folder that is not a git repository (and a machine with no
# `git` at all) gets an honest /api/git answer from the Go board (t-15d8: the only board): is_git false, no invented
# branch, no commits, nothing modified. Real servers, no git on PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "sprint-check-nongit: skipped (python3/curl not both present)"; exit 0; }
command -v go >/dev/null 2>&1 || fail "sprint-check-nongit: go is required (the board and the daemon are built from source here)"

WORK="$(mktemp -d)"
BIN_DIR="$(mktemp -d)"
GO_PID=""; D_PID=""
cleanup() {
  [[ -n "$D_PID" ]] && kill "$D_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  rm -rf "$WORK" "$BIN_DIR"
}
trap cleanup EXIT

PROJ="$WORK/pm-project"
mkdir -p "$PROJ/.tickets/t-ngit"
printf -- '---\nid: t-ngit\nstatus: open\ntype: task\npriority: 2\ncreated: 2026-09-29T00:00:00Z\n---\n# A ticket\n' > "$PROJ/.tickets/t-ngit/ticket.md"
printf 'draft\n' > "$PROJ/notes.md"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
GO_PORT="$(free_port)"
GO_BIN="$(build_board "$BIN_DIR")"
(cd "$ROOT/tools/canon-go" && go build -o "$BIN_DIR/canon-go" ./cmd/canon-go)

# An empty PATH directory: no git for the boards or the daemon (a PM's machine).
NOGIT_PATH="$BIN_DIR/empty"; mkdir -p "$NOGIT_PATH"
export CANON_HOME="$WORK/canon-home" COCKPIT_STATE_DIR="$WORK/state"
mkdir -p "$CANON_HOME/cockpit"; mkdir -p -m 700 "$COCKPIT_STATE_DIR"   # t-68ae: the daemon refuses a state folder open to others
# The folder is a REGISTERED project (the daemon's trust rule for a folder without git).
printf '[{"id":"aaaaaaaaaaaa","path":"%s","name":"pm-project","description":"","added":"2026-09-29"}]\n' "$PROJ" > "$CANON_HOME/cockpit/projects.json"
# A stub agent: writes a file into its working directory, then stays alive like a live session.
printf '#!/bin/sh\nprintf "the agent wrote this\\n" > "$PWD/agent-out.md"\nexec /bin/cat\n' > "$BIN_DIR/agent.sh"; chmod +x "$BIN_DIR/agent.sh"
env PATH="$NOGIT_PATH" COCKPIT_TOKEN=tok COCKPIT_SPRINT_BIN="$BIN_DIR/agent.sh" COCKPIT_PROJECT_ROOT="$PROJ" "$BIN_DIR/canon-go" daemon -addr 127.0.0.1:0 >/dev/null 2>&1 &
D_PID=$!; disown "$D_PID" 2>/dev/null || true
env PATH="$NOGIT_PATH" SPRINT_CHECK_ROOT="$PROJ" SPRINT_CHECK_NO_BROWSER=1 TMPDIR="$WORK" "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
GO_PID=$!; disown "$GO_PID" 2>/dev/null || true
for port in "$GO_PORT"; do
  ok=""; for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && ok=1 && break; sleep 0.1; done
  [[ -n "$ok" ]] || fail "server on port $port did not start"
done

shape() { # port -> the honest fields, one JSON line
  curl -s "http://127.0.0.1:$1/api/git" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("branch","is_git","log","modified","total_commits")},sort_keys=True))'
}
go="$(shape "$GO_PORT")"
want='{"branch": "", "is_git": false, "log": [], "modified": 0, "total_commits": null}'
assert_eq "$want" "$go"

# The ticket list still works with no git anywhere.
for port in "$GO_PORT"; do
  curl -s "http://127.0.0.1:$port/api/tickets" | grep '"t-ngit"' >/dev/null || fail "port $port: /api/tickets lost the ticket with no git"
done

# ── end to end: Start in the plain folder (no git anywhere), the agent writes a file, End ──
for _ in $(seq 1 100); do [[ -f "$COCKPIT_STATE_DIR/daemon.json" ]] && break; sleep 0.1; done
DADDR="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["addr"])' "$COCKPIT_STATE_DIR/daemon.json")"
printf "original notes\n" > "$PROJ/notes.md"
start="$(curl -s -X POST "http://$DADDR/session/start" -H "Authorization: Bearer tok" -d "{\"ticket\":\"t-ngit\",\"cwd\":\"$PROJ\",\"agent\":\"claude\"}")"
SID="$(printf '%s' "$start" | python3 -c 'import json,sys;print(json.load(sys.stdin)["session"])')" || fail "no session started in a folder without git: $start"
STOK="$(printf '%s' "$start" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
for _ in $(seq 1 100); do [[ -f "$PROJ/agent-out.md" ]] && break; sleep 0.1; done
[[ -f "$PROJ/agent-out.md" ]] || fail "the agent never wrote its file"
curl -s -X POST "http://$DADDR/session/$SID/kill" -H "Authorization: Bearer $STOK" >/dev/null
changes() { # port -> the comparable part of the board's answer
  curl -s "http://127.0.0.1:$1/api/cockpit-changes?id=t-ngit" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("tracked","complete","total","files")},sort_keys=True))'
}
want_changes='{"complete": true, "files": [{"path": "agent-out.md", "size": 21, "status": "added"}], "total": 1, "tracked": true}'
got_go=""
for _ in $(seq 1 50); do got_go="$(changes "$GO_PORT")"; [[ "$got_go" == "$want_changes" ]] && break; sleep 0.2; done
assert_eq "$want_changes" "$got_go"
# The project folder holds only the person's files plus what the agent wrote — no store, no .git.
[[ ! -e "$PROJ/.git" ]] || fail "a .git appeared in the project folder"

# Restore original: an edit after the session is put back, the file the agent added stays, and the gates' list is on disk.
[[ -f "$PROJ/.tickets/t-ngit/changes.json" ]] || fail "no .tickets/t-ngit/changes.json for the close gates"
printf 'edited later\n' > "$PROJ/notes.md"
restored="$(curl -s -X POST "http://$DADDR/changes/restore" -H "Authorization: Bearer tok" -d "{\"root\":\"$PROJ\",\"id\":\"t-ngit\"}")"
assert_eq '{"remaining":1,"restored":1}' "$(printf '%s' "$restored" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(",",":")))')"
assert_eq "original notes" "$(cat "$PROJ/notes.md")"
[[ -f "$PROJ/agent-out.md" ]] || fail "restore removed a file the agent added"

printf 'sprint-check-nongit: ok\n'
