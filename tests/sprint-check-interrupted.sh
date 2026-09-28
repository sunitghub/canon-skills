#!/usr/bin/env bash
# sprint-check-interrupted — /api/cockpit-interrupted + /api/cockpit-interrupted-dismiss
# (t-d9e6) in BOTH server.py and main.go, identically: sessions the daemon left in
# interrupted.json are listed with resumable/reason (ticket gone or closed, cwd gone,
# scratch), minus any live again (a stub daemon answers /sessions), hostile ids skipped;
# dismiss rewrites the file 0600, rejects a bad id, and removes the file when empty.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-interrupted: python3/curl absent — skipped"
  exit 0
fi

WORK="$(mktemp -d)"
STUB_PID=""; PY_PID=""; GO_PID=""
cleanup() {
  for p in "$PY_PID" "$GO_PID" "$STUB_PID"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
wait_for() { local i; for i in $(seq 1 50); do curl -s -o /dev/null "$1" && return 0; sleep 0.1; done; return 1; }

PROJ="$WORK/proj"
ticket() { mkdir -p "$PROJ/.tickets/$1"; printf -- '---\nid: %s\nstatus: %s\n---\n# %s\n' "$1" "$2" "$1" > "$PROJ/.tickets/$1/ticket.md"; }
ticket t-ok01 in_progress; ticket t-cls1 closed; ticket t-cwd1 in_progress; ticket t-liv1 in_progress

# A stub daemon: /healthz for discovery, /sessions reporting t-liv1 as live again.
STUB_PORT="$(free_port)"
python3 - "$STUB_PORT" "$PROJ" <<'PY' >/dev/null 2>&1 &
import http.server, json, sys
port, proj = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok" if self.path == "/healthz" else json.dumps([{"ticket": "t-liv1", "project_root": proj}]).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
STUB_PID=$!; disown "$STUB_PID" 2>/dev/null || true
wait_for "http://127.0.0.1:$STUB_PORT/healthz" || fail "sprint-check-interrupted: stub daemon did not start"

seed() {   # seed <state-dir>: daemon.json → the stub, plus the interrupted fixture
  mkdir -p "$1"
  printf '{"addr":"127.0.0.1:%s","pid":"0"}' "$STUB_PORT" > "$1/daemon.json"
  python3 - "$1/interrupted.json" "$PROJ" <<'PY'
import json, sys
p, proj = sys.argv[1], sys.argv[2]
e = lambda i, cwd=proj: {"sid": "x-" + i, "id": i, "project_root": proj, "cwd": cwd, "agent": "claude", "started": "2026-09-28T10:00:00Z"}
json.dump([e("t-ok01"), e("t-cls1"), e("t-gon1"), e("t-cwd1", proj + "/gone"), e("s-scr1"), e("t-liv1"),
           e("t-../x"), dict(e("t-noro"), project_root="")], open(p, "w"))
PY
}

PY_SD="$WORK/sd-py"; GO_SD="$WORK/sd-go"; seed "$PY_SD"; seed "$GO_SD"
PY_PORT="$(free_port)"
SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$WORK/canon-py" COCKPIT_STATE_DIR="$PY_SD" COCKPIT_DAEMON_BIN=/nonexistent \
  python3 "$ROOT/tools/sprint-check-app/server.py" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!; disown "$PY_PID" 2>/dev/null || true
wait_for "http://127.0.0.1:$PY_PORT/api/cockpit-interrupted" || fail "sprint-check-interrupted: server.py did not start"
BACKENDS=("server.py|$PY_PORT|$PY_SD")

if command -v go >/dev/null 2>&1; then
  GO_BIN="$WORK/sprint-check-go"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
  GO_PORT="$(free_port)"
  SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$WORK/canon-go" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$GO_SD" COCKPIT_DAEMON_BIN=/nonexistent \
    "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
  GO_PID=$!; disown "$GO_PID" 2>/dev/null || true
  wait_for "http://127.0.0.1:$GO_PORT/api/cockpit-interrupted" || fail "sprint-check-interrupted: main.go did not start"
  BACKENDS+=("main.go|$GO_PORT|$GO_SD")
else
  echo "sprint-check-interrupted: go absent — main.go portion skipped"
fi

summary() {   # id:resumable:reason-start, one per line, sorted
  python3 -c '
import json, sys
for e in sorted(json.load(sys.stdin), key=lambda e: e["id"]):
    print("%s:%s:%s" % (e["id"], e["resumable"], e["reason"].split(" ")[0] if e["reason"] else ""))'
}
expected="$(printf '%s\n' 's-scr1:False:scratch' 't-cls1:False:ticket' 't-cwd1:False:working' 't-gon1:False:ticket' 't-ok01:True:')"

outputs=()
for b in "${BACKENDS[@]}"; do
  IFS='|' read -r name port sd <<<"$b"
  got="$(curl -s "http://127.0.0.1:$port/api/cockpit-interrupted" | summary)"
  assert_eq "$expected" "$got"
  outputs+=("$(curl -s "http://127.0.0.1:$port/api/cockpit-interrupted" | python3 -c 'import json,sys;print(json.dumps(sorted(json.load(sys.stdin),key=lambda e:e["id"]),sort_keys=True))')")

  post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$port/api/cockpit-interrupted-dismiss"; }
  assert_eq "400" "$(post '{"id":"t-../x"}')"
  assert_eq "200" "$(post '{"id":"t-cls1"}')"
  left="$(curl -s "http://127.0.0.1:$port/api/cockpit-interrupted" | summary | cut -d: -f1 | tr '\n' ' ')"
  assert_eq "s-scr1 t-cwd1 t-gon1 t-ok01 " "$left"
  mode="$(python3 -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$sd/interrupted.json")"
  assert_eq "0o600" "$mode"
  for id in s-scr1 t-cwd1 t-gon1 t-ok01 t-liv1 t-noro; do post "{\"id\":\"$id\"}" >/dev/null; done
  # only the hostile entry is left in the file (never listed); dismissing it is refused, so the file stays
  assert_eq "[]" "$(curl -s "http://127.0.0.1:$port/api/cockpit-interrupted")"
  echo "sprint-check-interrupted: $name ok"
done

if [[ ${#outputs[@]} -eq 2 ]]; then
  assert_eq "${outputs[0]}" "${outputs[1]}"
fi
echo "sprint-check-interrupted: ok (list reasons, live filter, hostile ids, dismiss + 0600, server.py and main.go identical)"
