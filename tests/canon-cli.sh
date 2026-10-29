#!/usr/bin/env bash
# canon-cli — `canon status|sessions|stop|restart` (t-03a8) against the Go board
# (t-15d8: the only board) with a stub daemon: text and --json output, control characters neutralised, busy stop/restart refused
# without --force, board-down messages and exit codes, and no token in any output.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "canon-cli: python3/curl absent — skipped"
  exit 0
fi

CANON="$ROOT/tools/canon"
WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
wait_for() { local i; for i in $(seq 1 50); do curl -s -o /dev/null "$1" && return 0; sleep 0.1; done; return 1; }
TOKEN="SECRET-daemon-token-$$"

# stub_daemon <state-dir> <sessions-json>: /healthz + /sessions; daemon.json holds its pid,
# addr and a token that must never reach any canon output.
stub_daemon() {
  local sd="$1" sessions="$2" port
  port="$(free_port)"
  mkdir -p -m 700 "$sd"; printf '%s' "$sessions" > "$sd/stub-sessions.json"   # re-read per request, so a test can change it
  python3 - "$port" "$sd/stub-sessions.json" <<'PY' >/dev/null 2>&1 &
import http.server, sys
port, path = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        out = b"ok" if self.path == "/healthz" else open(path, "rb").read() if self.path == "/sessions" else b""
        self.send_response(200 if out else 404); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  local pid=$!; disown "$pid" 2>/dev/null || true; PIDS+=("$pid")
  mkdir -p -m 700 "$sd"
  printf '{"addr":"127.0.0.1:%s","token":"%s","pid":"%s"}' "$port" "$TOKEN" "$pid" > "$sd/daemon.json"
  wait_for "http://127.0.0.1:$port/healthz" || fail "canon-cli: stub daemon did not start"
}

SESSIONS='[{"session":"sx1","ticket":"t-d9e6","project_root":"/work/canon","cwd":"/work/canon","agent":"claude","state":"needs-you","state_secs":250,"signal":"hook","title":"Resume offer \u001b[31mred"},
 {"session":"sx2","ticket":"s-ab12","project_root":"C:\\p\\ToDo","cwd":"C:\\p\\ToDo","agent":"copilot","state":"working","state_secs":5,"signal":"output","title":""}]'

start_board() {   # start_board <name> <state-dir> → sets PORT
  local name="$1" sd="$2"
  PORT="$(free_port)"
  SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$WORK/home-go" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$sd" COCKPIT_DAEMON_BIN=/nonexistent \
    TMPDIR="$WORK" "$GO_BIN" "$PORT" >/dev/null 2>&1 &
  local pid=$!; disown "$pid" 2>/dev/null || true; PIDS+=("$pid")
  wait_for "http://127.0.0.1:$PORT/api/version" || fail "canon-cli: $name did not start"
}

run() { CANON_COCKPIT_PORT="$PORT" "$CANON" "$@"; }
no_token() { [[ "$1" != *"$TOKEN"* ]] || fail "canon-cli: a token appeared in canon output"; }

GO_BIN="$(build_board "$WORK/bin")"

# The Windows wrappers run this same script (they can't run here; t-03a8's VM check covers them).
grep -qF 'set "SCRIPT=%~dp0canon"' "$ROOT/tools/canon.cmd" || fail "canon-cli: tools/canon.cmd must run tools/canon"
for f in canon canon.cmd canon-win canon-win.cmd; do [[ -f "$ROOT/tools/$f" ]] || fail "canon-cli: tools/$f missing"; done

# Board down: status/sessions exit 1, stop is a no-op, wait exits 2.
PORT="$(free_port)"
set +e
out="$(run status 2>&1)"; code=$?
wout="$(run wait t-wt01 --until done 2>&1)"; wcode=$?
set -e
assert_eq "2" "$wcode"
assert_eq "The Cockpit is not running on port $PORT. Start it with: canon" "$wout"   # t-9a2d: canon wait, board down
assert_eq "1" "$code"
assert_contains "$out" "The Cockpit is not running on port $PORT. Start it with: canon"
set +e; out="$(run stop 2>&1)"; scode=$?; set -e
assert_eq "0" "$scode"
assert_eq "The Cockpit is not running on port $PORT. Nothing to stop." "$out"

# A board that predates these subcommands: /api/version answers, the new routes 404.
PORT="$(free_port)"
python3 - "$PORT" <<'PY' >/dev/null 2>&1 &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/version":
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"version":"0.2.0"}')
        else:
            self.send_error(404)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
pid=$!; disown "$pid" 2>/dev/null || true; PIDS+=("$pid")
wait_for "http://127.0.0.1:$PORT/api/version" || fail "canon-cli: stale-board stub did not start"
for c in status sessions; do
  set +e; out="$(run "$c" 2>&1)"; code=$?; set -e
  assert_eq "1" "$code"
  assert_contains "$out" "does not support 'canon $c'"
  [[ "$out" != *"<html"* && "$out" != *"<!DOCTYPE"* ]] || fail "canon-cli: a stale board's error page was printed as output"
done
# t-9a2d: canon wait on a stale board exits 2 and says what to do
set +e; out="$(run wait t-wt01 --until done --timeout 2000 2>&1)"; code=$?; set -e
assert_eq "2" "$code"
assert_eq "The board on port $PORT does not support 'canon wait' (it predates it, or failed). Close its window, then run canon." "$out"

for b in main.go; do
  sd="$WORK/sd-$b"
  stub_daemon "$sd" "$SESSIONS"
  start_board "$b" "$sd"

  st="$(run status)"; no_token "$st"
  assert_contains "$st" "daemon:   running at 127.0.0.1:"
  assert_contains "$st" "sessions: 2 (1 needs-you, 1 working)"
  sj="$(run status --json)"; no_token "$sj"
  assert_eq "2 True" "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(d["sessions"]["total"],d["daemon"]["running"])' "$sj")"

  tbl="$(run sessions)"; no_token "$tbl"
  assert_contains "$tbl" "t-d9e6  needs-you  4m   claude   canon    hook    Resume offer ?[31mred"
  assert_contains "$tbl" "s-ab12  working    5s   copilot  ToDo     output"
  [[ "$tbl" != *$'\x1b'* ]] || fail "canon-cli: an escape sequence reached the terminal"
  raw="$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions")"
  assert_eq "$raw" "$(run sessions --json)"

  # t-180d: canon wait — the stub's session list changes under it.
  row() { printf '{"session":"sw%s","ticket":"t-wt01","project_root":"%s","cwd":"%s","agent":"claude","state":"%s","state_secs":3,"signal":"hook","title":""}' "$1" "$2" "$2" "$3"; }
  setsess() { printf '[%s]' "$1" > "$sd/stub-sessions.json"; }
  setsess "$(row 1 /work/a working)"
  t0=$SECONDS
  ( sleep 2; setsess "$(row 1 /work/a needs-you)" ) &
  out="$(run wait t-wt01 --until needs-you --timeout 9000)"; no_token "$out"
  assert_eq "needs-you" "$out"
  (( SECONDS - t0 >= 2 && SECONDS - t0 < 9 )) || fail "canon-cli: wait returned at the wrong time ($((SECONDS - t0))s)"
  set +e; out="$(run wait t-wt01 --until done --timeout 2000 2>&1)"; code=$?; set -e
  assert_eq "1" "$code"; assert_contains "$out" "timed out after 2000ms. t-wt01 is needs-you"
  assert_eq "needs-you" "$(run wait t-wt01 --until working,needs-you --timeout 3000)"
  j="$(run wait t-wt01 --until needs-you --json)"; no_token "$j"
  assert_eq "t-wt01 needs-you" "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(d["ticket"],d["state"])' "$j")"
  setsess "$(row 1 /work/a working),$(row 2 /work/b needs-you)"
  assert_eq "needs-you" "$(run wait t-wt01 --until needs-you --project /work/b --timeout 3000)"
  set +e; run wait t-wt01 --until needs-you --project /work/a --timeout 2000 >/dev/null 2>&1; code=$?; set -e
  assert_eq "1" "$code"
  setsess ""
  assert_eq "exited" "$(run wait t-wt01 --until exited --timeout 3000)"
  assert_eq '{"ticket": "t-wt01", "state": "exited"}' "$(run wait t-wt01 --until exited --json)"
  for bad in "t-../x --until done" "t-wt01 --until sleeping" "t-wt01" "t-wt01 --until done --timeout soon"; do
    set +e; run wait $bad >/dev/null 2>&1; code=$?; set -e
    assert_eq "2" "$code"
  done
  assert_eq "400" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-../x&format=state")"
  setsess "$(row 1 /work/a working)"
  # format=state: the live state, "exited" for a ticket with no session; root matches case- and trailing-slash-insensitively
  # (these were compared py == go before t-15d8; now explicit)
  assert_eq "working" "$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-wt01&format=state")"
  assert_eq "exited" "$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-zz99&format=state")"
  assert_contains "$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-wt01&root=/WORK/a/&format=text")" "t-wt01  working  "
  printf '%s' "$SESSIONS" > "$sd/stub-sessions.json"

  # Busy: stop/restart refuse without --force and name the count.
  for c in stop restart; do
    set +e; out="$(run "$c" 2>&1)"; code=$?; set -e
    assert_eq "1" "$code"
    assert_contains "$out" "2 session(s) running. Run canon $c --force to end them"
    no_token "$out"
  done
  # --force stops it (the board ends the stub daemon by its recorded pid).
  out="$(run stop --force)"; no_token "$out"
  # this test's board is built outside the install, so canon stop must name it and leave it running (an install's own board is stopped: see below)
  assert_eq "Stopped the daemon. The board on port $PORT is not from this install, or cannot be identified, so it was left running. Press Ctrl+C in the terminal running canon, or close its window." "$out"
  assert_contains "$(run status)" "daemon:   not running"
  assert_eq "No sessions running." "$(run sessions)"
  echo "canon-cli: $b ok"
done

# canon stop / canon restart report each outcome (tools/canon board_cmd): a stub board answers /api/version and the stop/restart POSTs, so each message
# and exit code is produced by the real command. stub_board <port> <stop-json> <restart-json> <exit-after-post: 0|1>.
stub_board() {
  python3 - "$1" "$2" "$3" "$4" <<'PY' >/dev/null 2>&1 &
import http.server, sys, threading
port, stop, restart, quit_after = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4] == "1"
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, body):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); self.wfile.flush()
    def do_GET(self): self.reply(b'{"version":"0.2.0"}')
    def do_POST(self):
        self.reply((stop if self.path.endswith("stop") else restart).encode())
        if quit_after: threading.Thread(target=self.server.shutdown).start()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  local pid=$!; disown "$pid" 2>/dev/null || true; PIDS+=("$pid")
  wait_for "http://127.0.0.1:$1/api/version" || fail "canon-cli: stub board did not start"
}
# canon stop: the daemon stopped and the board is gone by the time canon looks for it
PORT="$(free_port)"; stub_board "$PORT" '{"running": false}' '{}' 1
set +e; out="$(run stop 2>&1)"; code=$?; set -e
assert_eq "0" "$code"
assert_eq "Stopped the daemon. The board had already exited." "$out"
# canon stop: the daemon did not stop without --force
PORT="$(free_port)"; stub_board "$PORT" '{"running": true}' '{}' 0
set +e; out="$(run stop 2>&1)"; code=$?; set -e
assert_eq "1" "$code"
assert_eq "The daemon is still running. Try: canon stop --force" "$out"
# canon restart: success, then failure (the daemon's answer is shown)
PORT="$(free_port)"; stub_board "$PORT" '{}' '{"restarted": true}' 0
set +e; out="$(run restart 2>&1)"; code=$?; set -e
assert_eq "0" "$code"
assert_eq "Restarted the daemon." "$out"
PORT="$(free_port)"; stub_board "$PORT" '{}' '{"restarted": false}' 0
set +e; out="$(run restart 2>&1)"; code=$?; set -e
assert_eq "1" "$code"
assert_eq 'The daemon did not restart: {"restarted": false}' "$out"

# canon stop: this install's board (a stub whose command line is the install's canon-go board <port>, so canon verifies it as ours) ignores SIGTERM
# until $stuck/release exists, so canon names its pid and exits 1 after CANON_STOP_WAIT
if command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1; then
  stuck="$WORK/stuck"; mkdir -p "$stuck"; PORT="$(free_port)"
  cat > "$stuck/board" <<'PY'
import http.server, os, signal, sys
def term(*a):
    if os.path.exists("release"): os._exit(0)
signal.signal(signal.SIGTERM, term)
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, body):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self): self.reply(b'{"version":"0.2.0"}')
    def do_POST(self): self.reply(b'{"running": false}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  # python3 finds its libraries from argv[0], which the command line below replaces: point it at them
  py_home="$(python3 -c 'import sys; print(sys.prefix)')"
  ( cd "$stuck" && PYTHONHOME="$py_home" exec -a "$(cd "$ROOT" && pwd -P)/tools/canon-go-bin/canon-go" python3 board "$PORT" >/dev/null 2>&1 ) &
  bp=$!; disown "$bp" 2>/dev/null || true; PIDS+=("$bp")
  wait_for "http://127.0.0.1:$PORT/api/version" || fail "canon-cli: the SIGTERM-proof board did not start"
  set +e; out="$(CANON_STOP_WAIT=1 run stop 2>&1)"; code=$?; set -e
  touch "$stuck/release"; kill "$bp" 2>/dev/null || true
  assert_eq "1" "$code"
  assert_eq "Stopped the daemon. The board (pid $bp) did not exit within 1s. Press Ctrl+C in the terminal running canon, or close its window." "$out"
fi

# canon stop also ends THIS install's own board (tools/canon-go-bin/canon-go board <port>, found by its port and verified by its path and mode
# word, t-bdb0), on an isolated state dir and port.
if [[ -x "$ROOT/tools/canon-go-bin/canon-go" ]]; then
  PORT="$(free_port)"; own="$(mktemp -d)"
  ( cd "$own" && COCKPIT_STATE_DIR="$own/state" HOME="$own" "$ROOT/tools/canon-go-bin/canon-go" board "$PORT" >/dev/null 2>&1 & echo $! > "$own/pid"; disown )
  bp="$(cat "$own/pid")"; PIDS+=("$bp")
  wait_for "http://127.0.0.1:$PORT/api/version" || fail "canon-cli: the install's own board did not start"
  out="$(COCKPIT_STATE_DIR="$own/state" HOME="$own" run stop)"
  assert_eq "Stopped the Cockpit: the board and the daemon have exited." "$out"
  ! kill -0 "$bp" 2>/dev/null || fail "canon-cli: canon stop left this install's board running"
fi

echo "canon-cli: ok (status/sessions text + --json, wait (reach/timeout/exited/list/--json/--project/bad input), escapes neutralised, busy refusal, --force stop, board down, no token)"
