#!/usr/bin/env bash
# sprint-check-cockpit — /api/cockpit (t-ddc8): discover + launch-on-demand in
# BOTH server.py and main.go, identically. The board never owns a PTY — it
# discovers/launches the cockpit-daemon and reads only its addr. Uses a STUB
# daemon (COCKPIT_DAEMON_BIN) so no real agent is ever spawned, mirroring
# sprint-check-api-parity.sh's stub approach for sprint-headless.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-cockpit: python3/curl absent — skipped"
  exit 0
fi

# t-2a71: reap any stub daemon leaked by a prior run this script's own
# trap-on-EXIT couldn't reach (e.g. the process was SIGKILLed, or its parent
# shell never ran its exit machinery at all) — before creating this run's own.
sweep_stale_stub_processes

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
WORK="$(mktemp -d)"
GO_BIN=""
PY_PID=""; GO_PID=""; PY_PID2=""; GO_PID2=""
PY_SD=""; PY_SD2=""; GO_SD=""; GO_SD2=""

# kill_stub_daemon <state-dir> — resolves the stub cockpit-daemon's PID from
# its own published daemon.json {addr} and kills it directly (t-677f). The
# daemon is spawned detached by server.py/main.go (start_new_session=True),
# so this script never gets a `$!` for it, and its real argv is bare
# `python3 -` (heredoc-fed stdin script) — `pkill -f "$WORK"` can never match
# that, since the unique tempdir path is only visible to the process via the
# COCKPIT_STATE_DIR *environment* variable, never argv. Resolving the real
# listening port and killing that exact PID is also strictly more robust
# than argv-substring matching would be (immune to a false-positive match on
# an unrelated process). Gated on daemon.json existing and lsof being
# available — skip silently otherwise, matching sweep_stale_stub_processes's
# own "skip on doubt" convention.
kill_stub_daemon() {
  local sd="$1" addr port pid
  [[ -f "$sd/daemon.json" ]] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  addr="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('addr',''))" "$sd/daemon.json" 2>/dev/null)" || return 0
  port="${addr##*:}"
  [[ -n "$port" ]] || return 0
  for pid in $(lsof -ti "tcp:$port" 2>/dev/null || true); do
    kill "$pid" 2>/dev/null || true
  done
}

cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  [[ -n "$PY_PID2" ]] && kill "$PY_PID2" 2>/dev/null || true
  [[ -n "$GO_PID2" ]] && kill "$GO_PID2" 2>/dev/null || true
  # kill each stub daemon http server this test spawned, by resolved PID
  kill_stub_daemon "$PY_SD"
  kill_stub_daemon "$PY_SD2"
  kill_stub_daemon "$GO_SD"
  kill_stub_daemon "$GO_SD2"
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  rm -rf "$WORK"
}
trap cleanup EXIT

build_tickets_fixture "$WORK"

# ── Stub cockpit-daemon: records its argv, then serves 200 on every path
# (so /healthz passes) and publishes daemon.json {addr,token} like the real one.
STUB="$WORK/stub-daemon"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# record argv so the test can assert a fixed argv with no token
printf '%s\n' "$@" > "$COCKPIT_STATE_DIR/argv.txt"
# record COCKPIT_SPRINT_BIN as the launcher actually set it (t-7bdd): empty
# means the launcher left it unset, so the daemon's own "claude" default
# would apply; a non-empty value must be an explicit pass-through, never the
# bash sprint CLI the launcher used to hard-code.
printf '%s' "${COCKPIT_SPRINT_BIN:-}" > "$COCKPIT_STATE_DIR/env-sprintbin.txt"
exec python3 - <<'PY'
import http.server, socketserver, json, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
addr = '127.0.0.1:%d' % srv.server_address[1]
p = os.path.join(os.environ['COCKPIT_STATE_DIR'], 'daemon.json')
open(p, 'w').write(json.dumps({'addr': addr, 'token': 'stub-boot-token-should-never-reach-argv'}))
srv.serve_forever()
PY
EOF
chmod +x "$STUB"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# ── Exercise one backend end to end ─────────────────────────────────────────
# $1 = human label, $2 = base url, $3 = its state dir
exercise() {
  local label="$1" base="$2" sd="$3"
  rm -rf "$sd"; mkdir -p "$sd"

  # discover with no daemon → running:false, addr:null
  local disc; disc="$(curl -s "$base/api/cockpit")"
  python3 - "$disc" "$label" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if d.get("running") is not False or d.get("addr") not in (None,):
    print(f"sprint-check-cockpit: FAIL — {sys.argv[2]} discover (no daemon) should be running:false/addr:null, got {sys.argv[1]}")
    sys.exit(1)
PY

  # foreign Origin on POST → 403 (spawn surface must reject cross-origin)
  local ocode; ocode="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://evil.example' "$base/api/cockpit" -d '{}')"
  [[ "$ocode" == "403" ]] || fail "sprint-check-cockpit: FAIL — $label POST with foreign Origin should be 403, got $ocode"

  # launch on demand → running:true, launched:true, addr set
  local res; res="$(curl -s -X POST "$base/api/cockpit" -d '{}')"
  python3 - "$res" "$label" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if not (d.get("running") is True and d.get("launched") is True and d.get("addr")):
    print(f"sprint-check-cockpit: FAIL — {sys.argv[2]} launch should be running:true/launched:true/addr, got {sys.argv[1]}")
    sys.exit(1)
PY

  # the stub recorded a FIXED argv: exactly `-addr 127.0.0.1:0`, and NO token anywhere
  local argv; argv="$(cat "$sd/argv.txt")"
  [[ "$argv" == $'-addr\n127.0.0.1:0' ]] || fail "sprint-check-cockpit: FAIL — $label spawned argv not fixed [-addr 127.0.0.1:0]: [$argv]"
  if grep -qi 'token' "$sd/argv.txt"; then
    fail "sprint-check-cockpit: FAIL — $label leaked a token into the daemon argv: [$argv]"
  fi

  # t-7bdd: with no COCKPIT_SPRINT_BIN in the launching process's own env, the
  # launcher must leave it unset in the daemon's env — never resolve it to the
  # bash sprint CLI (the regression: the daemon's own "claude" default got
  # silently overridden every time the board launched it).
  local sprintbin_env; sprintbin_env="$(cat "$sd/env-sprintbin.txt" 2>/dev/null || true)"
  [[ -z "$sprintbin_env" ]] || fail "sprint-check-cockpit: FAIL — $label default launch set COCKPIT_SPRINT_BIN=[$sprintbin_env], want unset"

  # second POST discovers the now-running daemon → launched:false (idempotent)
  local res2; res2="$(curl -s -X POST "$base/api/cockpit" -d '{}')"
  python3 - "$res2" "$label" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if not (d.get("running") is True and d.get("launched") is False):
    print(f"sprint-check-cockpit: FAIL — {sys.argv[2]} second launch should be idempotent (launched:false), got {sys.argv[1]}")
    sys.exit(1)
PY

  # GET discover now also reports running:true
  local disc2; disc2="$(curl -s "$base/api/cockpit")"
  python3 - "$disc2" "$label" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if not (d.get("running") is True and d.get("addr")):
    print(f"sprint-check-cockpit: FAIL — {sys.argv[2]} discover after launch should be running:true, got {sys.argv[1]}")
    sys.exit(1)
PY
}

wait_ready() {
  local port="$1"
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && return 0; sleep 0.1; done
  return 1
}

# t-7bdd: an explicit COCKPIT_SPRINT_BIN in the *board's own* launching env
# (a test stub, say) must still pass through unchanged — the fix removes the
# wrong default, not the ability to override.
OVERRIDE_VALUE="/path/to/fake-claude-stub.sh"
assert_override_passthrough() {
  local label="$1" sd="$2"
  local sprintbin_env; sprintbin_env="$(cat "$sd/env-sprintbin.txt" 2>/dev/null || true)"
  [[ "$sprintbin_env" == "$OVERRIDE_VALUE" ]] || fail "sprint-check-cockpit: FAIL — $label override launch set COCKPIT_SPRINT_BIN=[$sprintbin_env], want [$OVERRIDE_VALUE]"
}

# ── server.py ───────────────────────────────────────────────────────────────
PY_PORT="$(free_port)"; PY_SD="$WORK/state-py"
SPRINT_CHECK_ROOT="$WORK" COCKPIT_STATE_DIR="$PY_SD" COCKPIT_DAEMON_BIN="$STUB" \
  python3 "$SERVER_PY" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!; disown "$PY_PID" 2>/dev/null || true
wait_ready "$PY_PORT" || fail "sprint-check-cockpit: server.py did not start"
exercise "server.py" "http://127.0.0.1:$PY_PORT" "$PY_SD"

# server.py, override case: COCKPIT_SPRINT_BIN already set in the launching env
PY_PORT2="$(free_port)"; PY_SD2="$WORK/state-py-override"; mkdir -p "$PY_SD2"
SPRINT_CHECK_ROOT="$WORK" COCKPIT_STATE_DIR="$PY_SD2" COCKPIT_DAEMON_BIN="$STUB" COCKPIT_SPRINT_BIN="$OVERRIDE_VALUE" \
  python3 "$SERVER_PY" "$PY_PORT2" >/dev/null 2>&1 &
PY_PID2=$!; disown "$PY_PID2" 2>/dev/null || true
wait_ready "$PY_PORT2" || fail "sprint-check-cockpit: server.py (override) did not start"
curl -s -X POST "http://127.0.0.1:$PY_PORT2/api/cockpit" -d '{}' >/dev/null
assert_override_passthrough "server.py" "$PY_SD2"

# ── main.go (parity) ─────────────────────────────────────────────────────────
if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
  GO_PORT="$(free_port)"; GO_SD="$WORK/state-go"
  SPRINT_CHECK_ROOT="$WORK" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$GO_SD" COCKPIT_DAEMON_BIN="$STUB" \
    "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
  GO_PID=$!; disown "$GO_PID" 2>/dev/null || true
  wait_ready "$GO_PORT" || fail "sprint-check-cockpit: main.go did not start"
  exercise "main.go" "http://127.0.0.1:$GO_PORT" "$GO_SD"

  # main.go, override case: COCKPIT_SPRINT_BIN already set in the launching env
  GO_PORT2="$(free_port)"; GO_SD2="$WORK/state-go-override"; mkdir -p "$GO_SD2"
  SPRINT_CHECK_ROOT="$WORK" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$GO_SD2" COCKPIT_DAEMON_BIN="$STUB" COCKPIT_SPRINT_BIN="$OVERRIDE_VALUE" \
    "$GO_BIN" "$GO_PORT2" >/dev/null 2>&1 &
  GO_PID2=$!; disown "$GO_PID2" 2>/dev/null || true
  wait_ready "$GO_PORT2" || fail "sprint-check-cockpit: main.go (override) did not start"
  curl -s -X POST "http://127.0.0.1:$GO_PORT2/api/cockpit" -d '{}' >/dev/null
  assert_override_passthrough "main.go" "$GO_SD2"
else
  echo "sprint-check-cockpit: go absent — main.go parity portion skipped"
fi

printf 'sprint-check-cockpit: ok\n'
