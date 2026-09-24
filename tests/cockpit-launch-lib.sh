#!/usr/bin/env bash
# tests/cockpit-launch-lib.sh — t-55c1: the Cockpit launcher helpers (tools/cockpit-launch-lib.sh) work with
# no Python: port check via bash /dev/tcp, project registration parsed with sed/awk against BOTH backends,
# and start_cockpit_server hands off to the Go sprint-check-win.exe on Windows without a working Python.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "cockpit-launch-lib: curl absent — skipped"; exit 0; }
tmp="$(mktemp -d)"
pids=()
cleanup() { for p in "${pids[@]+"${pids[@]}"}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$tmp"; }
trap cleanup EXIT
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
wait_up() { for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$1/api/version" && return 0; sleep 0.1; done; fail "server on $1 never came up"; }
lib() { bash -c 'source "$1/tools/cockpit-launch-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }

tmp="$(cd -P "$tmp" && pwd -P)"                                # callers pass resolved paths (sprint-check: pwd -P)
proj="$tmp/proj"; mkdir -p "$proj"; git -C "$proj" init -q
odd="$tmp/we\"ird dir"; mkdir -p "$odd"                       # a path needing JSON escaping
export HOME="$tmp/home"; mkdir -p "$HOME"                      # isolate the project registry

check_backend() {   # <label> <port>: register twice (new, then already-registered lookup) for two paths
  local label="$1" port="$2" p id1 id2
  for p in "$proj" "$odd"; do
    id1="$(lib cockpit_register_project "$port" "$p")"
    [[ -n "$id1" ]] || fail "$label: no id registering $p"
    id2="$(lib cockpit_register_project "$port" "$p")"
    assert_eq "$id1" "$id2"
  done
  [[ "$(lib cockpit_register_project "$port" "$proj")" != "$(lib cockpit_register_project "$port" "$odd")" ]] \
    || fail "$label: two paths got the same id"
}

# --- Python backend ------------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  py_port="$(free_port)"
  ( cd "$proj" && CANON_HOME="$tmp/canon-py" SPRINT_CHECK_NO_BROWSER=1 exec python3 "$ROOT/tools/sprint-check-app/server.py" "$py_port" ) >/dev/null 2>&1 &
  pids+=($!); wait_up "$py_port"
  check_backend python "$py_port"

  # _port_in_use without lsof/ss (Git Bash): bash /dev/tcp.
  PATH="/bin:/usr/bin" lib _port_in_use "$py_port" || fail "/dev/tcp: listening port reported free"
  if PATH="/bin:/usr/bin" lib _port_in_use "$(free_port)"; then fail "/dev/tcp: free port reported in use"; fi
fi

# --- Go backend (same API, compact JSON) ----------------------------------------------------------
if command -v go >/dev/null 2>&1; then
  mkdir -p "$tmp/gobin"
  ( cd "$ROOT" && GO111MODULE=off go build -o "$tmp/gobin/sprint-check-go" ./tools/sprint-check-go ) >/dev/null 2>&1 \
    || fail "go build of sprint-check-go failed"
  go_port="$(free_port)"
  ( cd "$proj" && CANON_HOME="$tmp/canon-go" SPRINT_CHECK_NO_BROWSER=1 exec "$tmp/gobin/sprint-check-go" "$go_port" ) >/dev/null 2>&1 &
  pids+=($!); wait_up "$go_port"
  check_backend go "$go_port"
fi

# --- start_cockpit_server: which server starts ------------------------------------------------
fake="$tmp/faketools"; mkdir -p "$fake/sprint-check-app"
cp "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$fake/"
printf '#!/usr/bin/env bash\necho "exe port=$1 nobrowser=${SPRINT_CHECK_NO_BROWSER:-}" > "%s/started"\n' "$tmp" > "$fake/sprint-check-win.exe"
chmod +x "$fake/sprint-check-win.exe"
pybin="$tmp/pybin"; mkdir -p "$pybin"
printf '#!/usr/bin/env bash\necho "python $*" > "%s/started"\n' "$tmp" > "$pybin/python3"; chmod +x "$pybin/python3"
started() {  # <is_windows 0|1> <have_python 0|1>
  rm -f "$tmp/started"
  IW="$1" HP="$2" PATH="$pybin:$PATH" bash -c 'source "$1/cockpit-launch-lib.sh"
    _is_windows() { return "$IW"; }; have_python() { return "$HP"; }
    start_cockpit_server 4321; wait "$SERVER_PID"' _ "$fake" >/dev/null 2>&1
  cat "$tmp/started"
}
assert_eq "exe port=4321 nobrowser=1" "$(started 0 1)"                          # Windows, no Python
assert_eq "python $fake/sprint-check-app/server.py 4321" "$(started 0 0)"       # Windows with Python
assert_eq "python $fake/sprint-check-app/server.py 4321" "$(started 1 1)"       # macOS/Linux
rm "$fake/sprint-check-win.exe"
out="$(bash -c 'source "$1/cockpit-launch-lib.sh"; _is_windows() { return 0; }; have_python() { return 1; }; start_cockpit_server 4321' _ "$fake" 2>&1 || true)"
assert_contains "$out" "run canon-cockpit-win instead"

printf 'cockpit-launch-lib: ok\n'
