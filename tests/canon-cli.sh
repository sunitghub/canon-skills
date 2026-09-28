#!/usr/bin/env bash
# canon-cli — `canon status|sessions|stop|restart` (t-03a8) against BOTH board servers
# (server.py and sprint-check-go) with a stub daemon: text and --json output, identical
# text from both backends, control characters neutralised, busy stop/restart refused
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
  mkdir -p "$sd"; printf '%s' "$sessions" > "$sd/stub-sessions.json"   # re-read per request, so a test can change it
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
  mkdir -p "$sd"
  printf '{"addr":"127.0.0.1:%s","token":"%s","pid":"%s"}' "$port" "$TOKEN" "$pid" > "$sd/daemon.json"
  wait_for "http://127.0.0.1:$port/healthz" || fail "canon-cli: stub daemon did not start"
}

SESSIONS='[{"session":"sx1","ticket":"t-d9e6","project_root":"/work/canon","cwd":"/work/canon","agent":"claude","state":"needs-you","state_secs":250,"signal":"hook","title":"Resume offer \u001b[31mred"},
 {"session":"sx2","ticket":"s-ab12","project_root":"C:\\p\\ToDo","cwd":"C:\\p\\ToDo","agent":"copilot","state":"working","state_secs":5,"signal":"output","title":""}]'

start_board() {   # start_board <name> <state-dir> → sets PORT
  local name="$1" sd="$2"
  PORT="$(free_port)"
  if [[ "$name" == server.py ]]; then
    SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$WORK/home-py" COCKPIT_STATE_DIR="$sd" COCKPIT_DAEMON_BIN=/nonexistent \
      python3 "$ROOT/tools/sprint-check-app/server.py" "$PORT" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$WORK/home-go" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$sd" COCKPIT_DAEMON_BIN=/nonexistent \
      "$GO_BIN" "$PORT" >/dev/null 2>&1 &
  fi
  local pid=$!; disown "$pid" 2>/dev/null || true; PIDS+=("$pid")
  wait_for "http://127.0.0.1:$PORT/api/version" || fail "canon-cli: $name did not start"
}

run() { CANON_COCKPIT_PORT="$PORT" "$CANON" "$@"; }
no_token() { [[ "$1" != *"$TOKEN"* ]] || fail "canon-cli: a token appeared in canon output"; }

BACKENDS=(server.py)
if command -v go >/dev/null 2>&1; then
  GO_BIN="$WORK/sprint-check-go"
  (cd "$ROOT" && GO111MODULE=off go build -ldflags "-X main.version=$(tr -d ' \t\n\r' < "$ROOT/VERSION")" -o "$GO_BIN" ./tools/sprint-check-go)
  BACKENDS+=(main.go)
else
  echo "canon-cli: go absent — main.go portion skipped"
fi

# The Windows wrappers run this same script (they can't run here; t-03a8's VM check covers them).
grep -qF 'set "SCRIPT=%~dp0canon"' "$ROOT/tools/canon.cmd" || fail "canon-cli: tools/canon.cmd must run tools/canon"
for f in canon canon.cmd canon-win canon-win.cmd; do [[ -f "$ROOT/tools/$f" ]] || fail "canon-cli: tools/$f missing"; done

# Board down: status/sessions exit 1, stop is a no-op, wait exits 2.
PORT="$(free_port)"
set +e
out="$(run status 2>&1)"; code=$?
run wait t-wt01 --until done >/dev/null 2>&1; wcode=$?
set -e
assert_eq "2" "$wcode"
assert_eq "1" "$code"
assert_contains "$out" "Canon isn't running on port $PORT"
assert_eq "Canon isn't running on port $PORT — nothing to stop." "$(run stop)"

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
  assert_contains "$out" "doesn't support 'canon $c'"
  [[ "$out" != *"<html"* && "$out" != *"<!DOCTYPE"* ]] || fail "canon-cli: a stale board's error page was printed as output"
done

texts=()
for b in "${BACKENDS[@]}"; do
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
  texts+=("$tbl"$'\n'"$(sed -E 's/up [0-9]+[smhd]( [0-9]+[mh])?/up N/; s/127\.0\.0\.1:[0-9]+/127.0.0.1:PORT/' <<<"$st")")

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
  assert_eq "1" "$code"; assert_contains "$out" "timed out after 2000ms — t-wt01 is needs-you"
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
  texts+=("$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-wt01&format=state")|$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-zz99&format=state")|$(curl -s "http://127.0.0.1:$PORT/api/cockpit-sessions?id=t-wt01&root=/WORK/a/&format=text")")
  printf '%s' "$SESSIONS" > "$sd/stub-sessions.json"

  # Busy: stop/restart refuse without --force and name the count.
  for c in stop restart; do
    set +e; out="$(run "$c" 2>&1)"; code=$?; set -e
    assert_eq "1" "$code"
    assert_contains "$out" "2 session(s) running — canon $c --force ends them"
    no_token "$out"
  done
  # --force stops it (the board ends the stub daemon by its recorded pid).
  out="$(run stop --force)"; no_token "$out"
  assert_eq "Cockpit daemon stopped." "$out"
  assert_contains "$(run status)" "daemon:   not running"
  assert_eq "No sessions running." "$(run sessions)"
  echo "canon-cli: $b ok"
done

if [[ ${#texts[@]} -eq 4 ]]; then
  assert_eq "${texts[0]}" "${texts[2]}"
  assert_eq "${texts[1]}" "${texts[3]}"
fi
echo "canon-cli: ok (status/sessions text + --json, wait (reach/timeout/exited/list/--json/--project/bad input), both backends identical, escapes neutralised, busy refusal, --force stop, board down, no token)"
