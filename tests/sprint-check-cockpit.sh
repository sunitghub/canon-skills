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

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
WORK="$(mktemp -d)"
GO_BIN=""
PY_PID=""; GO_PID=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  # kill any stub daemon http servers this test spawned (detached, so matched by
  # their unique state-dir path in argv)
  pkill -f "$WORK" 2>/dev/null || true
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

# ── server.py ───────────────────────────────────────────────────────────────
PY_PORT="$(free_port)"; PY_SD="$WORK/state-py"
SPRINT_CHECK_ROOT="$WORK" COCKPIT_STATE_DIR="$PY_SD" COCKPIT_DAEMON_BIN="$STUB" \
  python3 "$SERVER_PY" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!; disown "$PY_PID" 2>/dev/null || true
wait_ready "$PY_PORT" || fail "sprint-check-cockpit: server.py did not start"
exercise "server.py" "http://127.0.0.1:$PY_PORT" "$PY_SD"

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
else
  echo "sprint-check-cockpit: go absent — main.go parity portion skipped"
fi

printf 'sprint-check-cockpit: ok\n'
