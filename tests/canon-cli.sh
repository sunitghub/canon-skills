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
wait_for() { for _ in $(seq 1 50); do curl -s -o /dev/null "$1" && return 0; sleep 0.1; done; return 1; }
TOKEN="SECRET-daemon-token-$$"

# stub_daemon <state-dir> <sessions-json>: /healthz + /sessions; daemon.json holds its pid,
# addr and a token that must never reach any canon output.
stub_daemon() {
  local sd="$1" sessions="$2" port
  port="$(free_port)"
  mkdir -p "$sd"; chmod 700 "$sd"; printf '%s' "$sessions" > "$sd/stub-sessions.json"   # re-read per request, so a test can change it
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
  mkdir -p "$sd"; chmod 700 "$sd"
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

run() { CANON_COCKPIT_PORT="$PORT" SPRINT_CHECK_BIN="$GO_BIN" "$CANON" "$@"; }   # t-5b80: the table is the test build's sessions-table
# run_bounded: run, but a command that would loop (a validation that failed to refuse) is stopped after 8 s and fails the assertion on its status (143), not the suite on a hang.
run_bounded() {
  CANON_COCKPIT_PORT="$PORT" SPRINT_CHECK_BIN="$GO_BIN" "$CANON" "$@" & local p=$!
  ( sleep 8; kill "$p" 2>/dev/null ) & local w=$!
  local c=0; wait "$p" || c=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null || true
  return "$c"
}
no_token() { [[ "$1" != *"$TOKEN"* ]] || fail "canon-cli: a token appeared in canon output"; }

# t-5b80: every request to the board goes through board_curl (curl --noproxy '*'): a proxy variable must not see or answer for the board. One scan
# of the CLI and the libraries (canon, canon-uninstall.sh, cockpit-launch-lib.sh, pkg-lib.sh) for a bare curl naming an /api/ path or 127.0.0.1.
bare="$(grep -nE '(^|[^_a-zA-Z])curl .*(/api/|127\.0\.0\.1)' "$ROOT"/tools/canon "$ROOT"/tools/*.sh | grep -v 'board_curl' || true)"
[[ -z "$bare" ]] || fail "canon-cli: a board request calls curl without board_curl (--noproxy): $bare"

GO_BIN="$(build_board "$WORK/bin")"

# The Windows wrappers run this same script (they can't run here; t-03a8's VM check covers them).
grep -qF 'set "SCRIPT=%~dp0canon"' "$ROOT/tools/canon.cmd" || fail "canon-cli: tools/canon.cmd must run tools/canon"
for f in canon canon.cmd canon-win canon-win.cmd; do [[ -f "$ROOT/tools/$f" ]] || fail "canon-cli: tools/$f missing"; done

# Board down: status/sessions exit 1, stop is a no-op, wait exits 2.
PORT="$(free_port)"
set +e
out="$(run status 2>&1)"; code=$?
wout="$(run wait t-wt01 --until "done" 2>&1)"; wcode=$?
set -e
assert_eq "2" "$wcode"
assert_eq "The Cockpit is not running on port $PORT. Start it with: canon" "$wout"   # t-9a2d: canon wait, board down
assert_eq "1" "$code"
assert_contains "$out" "The Cockpit is not running on port $PORT. Start it with: canon"
set +e; out="$(run stop 2>&1)"; scode=$?; set -e
assert_eq "0" "$scode"
assert_eq "The Cockpit is not running on port $PORT. Nothing to stop." "$out"
# t-ad6f: canon events / canon sprint with no board exit 2 and say how to start it
for c in "events" "sprint t-d9e6"; do
  set +e; out="$(run $c 2>&1)"; code=$?; set -e
  assert_eq "2" "$code"; assert_eq "The Cockpit is not running on port $PORT. Start it with: canon" "$out"
done

# t-ad6f: --help lists the two commands with their options
help_out="$("$CANON" --help)"
assert_contains "$help_out" "canon events [--limit N] [--json]"; assert_contains "$help_out" "canon sprint <id> [--json]"
assert_contains "$help_out" "The newest N (1 to 500, default 100) activity-log events, oldest first"
assert_contains "$help_out" "A ticket's sprint snapshot: the latest lifecycle event of each kind"
# the limits of the port: 1 and 65535 pass the check (and then find no board), 0 and 65536 do not
for okport in 1 65535; do
  set +e; out="$(CANON_COCKPIT_PORT="$okport" "$CANON" events 2>&1)"; code=$?; set -e
  assert_eq "2" "$code"; assert_eq "The Cockpit is not running on port $okport. Start it with: canon" "$out"
done

# t-ad6f: the port goes into a URL, so only a port number is accepted, by every command that talks to the board (status, sessions, stop, events, sprint, wait)
for badport in '1@127.0.0.1' '8899/x' '88 99' '8899?x=1' 'x' '70000' '0' '08899' '08' '65536' '123456'; do
  for c in "status" "sessions" "stop" "events" "sprint t-d9e6" "wait t-wt01 --until done"; do
    set +e; out="$(CANON_COCKPIT_PORT="$badport" "$CANON" $c 2>&1)"; code=$?; set -e
    assert_eq "2" "$code"; assert_eq "canon: CANON_COCKPIT_PORT must be a port number (1 to 65535), got '$badport'" "$out"
  done
done

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
  [[ "$out" != *sessions-table* ]] || fail "canon-cli: canon $c went on to the table after the board refused: $out"
  [[ "$out" != *"<html"* && "$out" != *"<!DOCTYPE"* ]] || fail "canon-cli: a stale board's error page was printed as output"
done
for c in "events" "sprint t-d9e6"; do   # t-ad6f: a board without the v1 routes
  set +e; out="$(run $c 2>&1)"; code=$?; set -e
  assert_eq "1" "$code"; assert_contains "$out" "answered 404 to 'canon ${c%% *}'"
done
# t-ad6f (break-it): a board that answers 500 with escape bytes in the body, and one that drops the connection on the v1 routes. The first must
# not put a raw escape on the terminal; the second must be named as not answering, not as having "answered 000".
v1_stub() {   # v1_stub <port> <500|500long|drop|noroot|nostate|lateroot>
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1 &
import http.server, sys
mode = sys.argv[2]
seen = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/version":
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"version":"0.2.0"}'); return
        if mode == "noroot" and self.path.startswith("/api/v1/sessions"):   # rows whatever root= says
            b = b'{"schema":1,"sessions":[{"ticket":"t-wt01","state":"working"}]}' if self.path.startswith("/api/v1/sessions?") else b'{"schema":1,"id":"t-wt01","state":"working"}'
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        if mode == "lateroot" and self.path.startswith("/api/v1/sessions"):   # no root filter; the first list is empty, the next ones have a row
            global seen
            if self.path.startswith("/api/v1/sessions?"):
                seen += 1
                b = b'{"schema":1,"sessions":[]}' if seen == 1 else b'{"schema":1,"sessions":[{"ticket":"t-wt01","state":"working"}]}'
            else:
                b = b'{"schema":1,"id":"t-wt01","state":"working"}'
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        if mode == "nostate" and self.path.startswith("/api/v1/sessions"):   # 200 with no state in it
            b = b'{"schema":1,"error":"x"}'; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        if mode == "drop":
            self.connection.shutdown(2); return
        body = b"bad \x1b[31mred\x1b[0m " + (b"z" * 600 if mode == "500long" else b"end")
        self.send_response(500); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!; disown "$pid" 2>/dev/null || true; PIDS+=("$pid")
  wait_for "http://127.0.0.1:$1/api/version" || fail "canon-cli: v1 stub did not start"
}
PORT="$(free_port)"; v1_stub "$PORT" 500
set +e; out="$(run events 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "answered 500 to 'canon events'"; [[ "$out" == *"close its window, then run canon): bad ?[31mred?[0m end" ]] || fail "canon-cli: the board's short error body was not shown as it was: $out"
PORT="$(free_port)"; v1_stub "$PORT" 500long
set +e; out="$(run events 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "bad ?[31mred?[0m zzz"
[[ "$out" != *$'\x1b'* ]] || fail "canon-cli: an escape byte from the board's error body reached the terminal"
[[ "${#out}" -lt 500 ]] || fail "canon-cli: the board's error body was echoed whole (${#out} characters)"
PORT="$(free_port)"; v1_stub "$PORT" drop
set +e; out="$(run events 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "did not answer 'canon events'"; [[ "$out" != *"answered 000"* ]] || fail "canon-cli: a dropped connection was reported as an answer"
# t-9a2d: canon wait on a stale board exits 2 and says what to do
set +e; out="$(run wait t-wt01 --until "done" --timeout 2000 2>&1)"; code=$?; set -e
assert_eq "2" "$code"
assert_eq "The board on port $PORT does not support 'canon wait' (it predates it, or failed). Close its window, then run canon." "$out"

# t-5b80: a board with v1 sessions but no root filter would answer for another project: canon wait --project refuses, it does not guess
PORT="$(free_port)"; v1_stub "$PORT" noroot
set +e; out="$(run wait t-wt01 --until "done" --timeout 2000 --project /work/a 2>&1)"; code=$?; set -e
assert_eq "2" "$code"
assert_eq "The board on port $PORT does not support 'canon wait --project' (it predates it, or failed). Close its window, then run canon." "$out"
# t-5b80: the same board with no session at the first poll: the refusal comes at the poll where a row appears, not never
PORT="$(free_port)"; v1_stub "$PORT" lateroot
set +e; out="$(run wait t-wt01 --until done --timeout 6000 --project /work/a 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "does not support 'canon wait --project'"
# t-5b80: a 200 answer that carries no state is the board failing: canon wait exits 2 and says so, it does not wait it out
PORT="$(free_port)"; v1_stub "$PORT" nostate
set +e; out="$(run wait t-wt01 --until done --timeout 3000 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "does not support 'canon wait'"

# t-5b80 (break-it): wait refuses what can never work, before it asks the board anything (this board answers "working", so exit 2 can only be the check)
PORT="$(free_port)"; v1_stub "$PORT" noroot
for bad in "--until done --timeout 08" "--until done --timeout 09" "--until done --timeout 18446744073709551617" "--until done --timeout 0x10" "--until done --timeout -1" "--until ," "--until ,,"; do
  # shellcheck disable=SC2086  # split on purpose: flag and value
  set +e; out="$(run_bounded wait t-wt01 $bad 2>&1)"; code=$?; set -e
  assert_eq "2" "$code"; [[ "$out" == "canon wait: "* ]] || fail "canon-cli: canon wait $bad said: $out"
done
set +e; out="$(run_bounded wait t-wt01 --until done --project "" 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "canon wait: --project needs a path"   # an empty project is not "any project"
set +e; out="$(run_bounded wait t-wt01 --until done --project 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "canon wait: --project needs a path"
set +e; out="$(run_bounded wait t-wt01 --until sleeping 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "canon wait: unknown state 'sleeping'"
# t-5b80: the table needs this install's board binary to have sessions-table; one that does not (an older install) is named, never run as a port
stub_bin="$WORK/old-canon-go"; printf '#!/usr/bin/env bash\necho "usage: canon-go (an older one)"\n' > "$stub_bin"; chmod +x "$stub_bin"
set +e; out="$(CANON_COCKPIT_PORT="$PORT" SPRINT_CHECK_BIN="$stub_bin" "$CANON" sessions 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "canon sessions: the board binary ($stub_bin) is older than this command; run canon update."
# a leading zero is refused, but 0 and a plain number are timeouts: the board answers "working", so --until done times out (exit 1), not usage
set +e; out="$(run wait t-wt01 --until done --timeout 0 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "timed out after 0ms"

# shellcheck disable=SC2043  # one board today; the loop keeps the per-board stub dirs
for b in main.go; do
  sd="$WORK/sd-$b"
  stub_daemon "$sd" "$SESSIONS"
  start_board "$b" "$sd"

  st="$(run status)"; no_token "$st"
  assert_contains "$st" "daemon:   running at 127.0.0.1:"
  assert_contains "$st" "sessions: 2 (1 needs-you, 1 working)"
  sj="$(run status --json)"; no_token "$sj"
  assert_eq "2 True" "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(d["sessions"]["total"],d["daemon"]["running"])' "$sj")"

  # t-ad6f: events and sprint print the public read API's body unchanged (one JSON line), --json changes nothing
  ev="$(run events)"; no_token "$ev"
  assert_eq '{"cursor":"' "$(printf '%s' "$ev" | cut -c1-11)"; assert_contains "$ev" '"events":['; assert_contains "$ev" '"schema":1'
  assert_eq 1 "$(printf '%s\n' "$ev" | wc -l | tr -d ' ')"
  assert_eq "$ev" "$(run events --json)"
  assert_eq "$(curl -s "http://127.0.0.1:$PORT/api/v1/events?limit=5")" "$(run events --limit 5)"
  for good in 1 500 "5 --json"; do   # the limits themselves are valid
    set +e; out="$(run events --limit $good 2>&1)"; code=$?; set -e
    assert_eq "0" "$code"; assert_contains "$out" '"events":['
  done
  set +e; out="$(run events --nope 2>&1)"; set -e; assert_eq "canon events: unknown option: --nope" "$out"
  set +e; out="$(run events stray 2>&1)"; set -e; assert_eq "canon events: unexpected argument: stray" "$out"
  set +e; out="$(run sprint t-d9e6 --limit 5 2>&1)"; set -e; assert_eq "canon sprint: unknown option: --limit" "$out"
  for bad in "--limit 0" "--limit 501" "--limit x" "--limit" "--limit 1x" "extra" "--nope" "--limit 5 --limit" "--limit 18446744073709551617" "--limit 08" "--limit 0500" "--limit 1000"; do
    set +e; out="$(run events $bad 2>&1)"; code=$?; set -e
    assert_eq "2" "$code"; [[ "$out" == "canon events: "* ]] || fail "canon-cli: canon events $bad said: $out"
  done
  set +e; out="$(run events --limit "" 2>&1)"; code=$?; set -e   # an empty value is not "no limit"
  assert_eq "2" "$code"; [[ "$out" == "canon events: "* ]] || fail "canon-cli: canon events --limit '' said: $out"
  # a proxy named in the environment is never used for the board (it is on 127.0.0.1): every request would reach it otherwise
  proxy_log="$WORK/proxy-hits"; : > "$proxy_log"; proxy_port="$(free_port)"
  python3 - "$proxy_port" "$proxy_log" <<'PY' >/dev/null 2>&1 &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2], "a").write(self.path + "\n")
        b = b'{"proxied":1}'; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  ppid=$!; disown "$ppid" 2>/dev/null || true; PIDS+=("$ppid"); wait_for "http://127.0.0.1:$proxy_port/" || true
  for c in "events" "sprint t-d9e6" "status" "sessions" "sessions --json" "wait t-wt01 --until exited --timeout 1000" "wait t-wt01 --until exited --timeout 1000 --project /work/a"; do
    via="$(http_proxy="http://127.0.0.1:$proxy_port" HTTP_PROXY="http://127.0.0.1:$proxy_port" ALL_PROXY="http://127.0.0.1:$proxy_port" all_proxy="http://127.0.0.1:$proxy_port" run $c)"
    [[ "$via" != *proxied* ]] || fail "canon-cli: canon $c went through the environment's proxy"
  done
  assert_eq "" "$(grep -v '^/$' "$proxy_log" || true)"   # the "/" is wait_for's own readiness request
  sp="$(run sprint t-d9e6)"; no_token "$sp"
  assert_eq "$(curl -s "http://127.0.0.1:$PORT/api/v1/sprint/t-d9e6")" "$sp"
  assert_contains "$sp" '"ticket":"t-d9e6"'
  assert_eq "$sp" "$(run sprint t-d9e6 --json)"
  for bad in "" "t-D9E6" "t-d9e" "t-d9e66" "xt-d9e6" "../x" "t-d9e6 t-d9e7" "t-d9e6 --nope" "--limit 5"; do
    set +e; out="$(run sprint $bad 2>&1)"; code=$?; set -e
    assert_eq "2" "$code"; [[ "$out" == "canon sprint: "* ]] || fail "canon-cli: canon sprint $bad said: $out"
  done

  tbl="$(run sessions)"; no_token "$tbl"
  assert_contains "$tbl" "t-d9e6  needs-you  4m   claude   canon    hook    Resume offer ?[31mred"
  assert_contains "$tbl" "s-ab12  working    5s   copilot  ToDo     output"
  [[ "$tbl" != *$'\x1b'* ]] || fail "canon-cli: an escape sequence reached the terminal"
  raw="$(curl -s "http://127.0.0.1:$PORT/api/v1/sessions")"   # t-5b80: --json is the v1 body, unchanged
  assert_eq "$raw" "$(run sessions --json)"
  assert_contains "$raw" '"schema":1'; assert_contains "$raw" '"sessions":['
  assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/cockpit-sessions")"   # the private route is gone

  # t-180d: canon wait — the stub's session list changes under it.
  row() { printf '{"session":"sw%s","ticket":"t-wt01","project_root":"%s","cwd":"%s","agent":"claude","state":"%s","state_secs":3,"signal":"hook","title":""}' "$1" "$2" "$2" "$3"; }
  setsess() { printf '[%s]' "$1" > "$sd/stub-sessions.json"; }
  setsess "$(row 1 /work/a working)"
  t0=$SECONDS
  ( sleep 2; setsess "$(row 1 /work/a needs-you)" ) &
  out="$(run wait t-wt01 --until needs-you --timeout 9000)"; no_token "$out"
  assert_eq "needs-you" "$out"
  (( SECONDS - t0 >= 2 && SECONDS - t0 < 9 )) || fail "canon-cli: wait returned at the wrong time ($((SECONDS - t0))s)"
  set +e; out="$(run wait t-wt01 --until "done" --timeout 2000 2>&1)"; code=$?; set -e
  assert_eq "1" "$code"; assert_contains "$out" "timed out after 2000ms. t-wt01 is needs-you"
  assert_eq "needs-you" "$(run wait t-wt01 --until working,needs-you --timeout 3000)"
  j="$(run wait t-wt01 --until needs-you --json)"; no_token "$j"
  assert_eq "t-wt01 needs-you" "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1])["session"];print(d["ticket"],d["state"])' "$j")"   # t-5b80: the v1 session body
  setsess "$(row 1 /work/a working),$(row 2 /work/b needs-you)"
  assert_eq "needs-you" "$(run wait t-wt01 --until needs-you --project /work/b --timeout 3000)"
  set +e; run wait t-wt01 --until needs-you --project /work/a --timeout 2000 >/dev/null 2>&1; code=$?; set -e
  assert_eq "1" "$code"
  setsess ""
  assert_eq "exited" "$(run wait t-wt01 --until exited --timeout 3000)"
  assert_eq "1 t-wt01 exited" "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(d["schema"],d["id"],d["state"])' "$(run wait t-wt01 --until exited --json)")"
  for bad in "t-../x --until done" "t-wt01 --until sleeping" "t-wt01" "t-wt01 --until done --timeout soon"; do
    set +e; run wait $bad >/dev/null 2>&1; code=$?; set -e
    assert_eq "2" "$code"
  done
  setsess "$(row 1 /work/a working)"
  # the v1 state route: the live state, "exited" for a ticket with no session; root matches case- and trailing-slash-insensitively
  v1s() { curl -s "http://127.0.0.1:$PORT/api/v1/sessions/$1/state?root=$2" | sed -n 's/.*"state":"\([a-z-]*\)".*/\1/p'; }
  assert_eq "working" "$(v1s t-wt01 '')"
  assert_eq "exited" "$(v1s t-zz99 '')"
  assert_eq "working" "$(v1s t-wt01 /WORK/a/)"
  assert_eq "exited" "$(v1s t-wt01 /work/c)"
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
  # Homebrew's python on macOS re-execs through Python.app and drops the command line `exec -a` sets, so canon cannot verify the stub as
  # ours and this check has nothing to test: skip it there (t-fde8); Linux and Windows still run it
  if [[ "$(ps -o command= -p "$bp" 2>/dev/null)" != "$(cd "$ROOT" && pwd -P)/tools/canon-go-bin/canon-go "* ]]; then
    echo "canon-cli: stuck-board stop check skipped: this python drops the disguised command line (t-fde8)"
    touch "$stuck/release"; kill "$bp" 2>/dev/null || true; stuck=""
  fi
fi
if [[ -n "${stuck:-}" ]]; then
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

echo "canon-cli: ok (status/sessions text + --json, events and sprint (the v1 body, bad input, no board, old board), wait (reach/timeout/exited/list/--json/--project/bad input), escapes neutralised, busy refusal, --force stop, board down, no token)"
