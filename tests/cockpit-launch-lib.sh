#!/usr/bin/env bash
# tests/cockpit-launch-lib.sh — t-55c1: the Cockpit launcher helpers (tools/cockpit-launch-lib.sh) work with
# no Python: port check via bash /dev/tcp, project registration parsed with sed/awk against the Go board, and
# start_cockpit_server starts the Go board on every OS (t-15d8).

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

# --- the Go board (compact JSON) -----------------------------------------------------------------
board="$(build_board "$tmp/gobin")"
go_port="$(free_port)"
( cd "$proj" && CANON_HOME="$tmp/canon-go" COCKPIT_STATE_DIR="$tmp/ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_NO_BROWSER=1 TMPDIR="$tmp" \
    exec "$board" "$go_port" ) >/dev/null 2>&1 &
pids+=($!); wait_up "$go_port"
check_backend go "$go_port"

# _port_in_use without lsof/ss (Git Bash): bash /dev/tcp.
PATH="/bin:/usr/bin" lib _port_in_use "$go_port" || fail "/dev/tcp: listening port reported free"
if PATH="/bin:/usr/bin" lib _port_in_use "$(free_port)"; then fail "/dev/tcp: free port reported in use"; fi

# --- start_cockpit_server: the Go board on every OS (t-15d8), at board_rel_path, started as `canon-go board <port>` (t-bdb0: the mode
# word cockpit-stop-lib.sh knows the board by) ------------------------------
fake="$tmp/fakeinst/tools"; mkdir -p "$fake/canon-go-bin"
cp "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$fake/"
stub_board() { # <path>: a board that records how it was started
  printf '#!/usr/bin/env bash\necho "board $0 mode=$1 port=$2 nobrowser=${SPRINT_CHECK_NO_BROWSER:-}" > "%s/started"\n' "$tmp" > "$1"; chmod +x "$1"
}
printf '#!/usr/bin/env bash\necho "fetch args=$* nobuild=${CANON_FETCH_NO_BUILD:-}" >> "%s/fetchlog"\n' "$tmp" > "$fake/fetch-daemon.sh"
started() {  # <is_windows 0|1>
  rm -f "$tmp/started" "$tmp/fetchlog"
  IW="$1" bash -c 'source "$1/cockpit-launch-lib.sh"; _is_windows() { return "$IW"; }
    start_cockpit_server 4321; wait "$SERVER_PID"' _ "$fake" >/dev/null 2>&1
  cat "$tmp/started"
}
stub_board "$fake/canon-go-win.exe"; stub_board "$fake/canon-go-bin/canon-go"
assert_eq "board $fake/canon-go-win.exe mode=board port=4321 nobrowser=1" "$(started 0)"                 # Windows
[[ ! -e "$tmp/fetchlog" ]] || fail "Windows: an exe that is already there must not be re-fetched"
assert_eq "board $fake/canon-go-bin/canon-go mode=board port=4321 nobrowser=1" "$(started 1)"        # macOS/Linux
assert_eq "fetch args=--quiet nobuild=" "$(cat "$tmp/fetchlog")"   # every start; builds an unreleased change from source
# no python3 is run on any path: a python3 on PATH that records itself is never called
pybin="$tmp/pybin"; mkdir -p "$pybin"; printf '#!/usr/bin/env bash\necho ran > "%s/python-ran"\n' "$tmp" > "$pybin/python3"; chmod +x "$pybin/python3"
for iw in 0 1; do PATH="$pybin:$PATH" started "$iw" >/dev/null; done
[[ ! -e "$tmp/python-ran" ]] || fail "start_cockpit_server ran python3"
# SPRINT_CHECK_BIN: that binary, and no fetch
stub_board "$tmp/testboard"; rm -f "$tmp/started" "$tmp/fetchlog"
SPRINT_CHECK_BIN="$tmp/testboard" bash -c 'source "$1/cockpit-launch-lib.sh"; _is_windows() { return 1; }; start_cockpit_server 4321; wait "$SERVER_PID"' _ "$fake" >/dev/null 2>&1
assert_eq "board $tmp/testboard mode=board port=4321 nobrowser=1" "$(cat "$tmp/started")"; [[ ! -e "$tmp/fetchlog" ]] || fail "SPRINT_CHECK_BIN must skip the fetch"
# Windows, exe missing: ONE quiet no-build fetch; a fetch that provides it lets the board start; one that fails says what to do
rm -f "$fake/canon-go-win.exe"
printf '#!/usr/bin/env bash\necho "fetch args=$* nobuild=${CANON_FETCH_NO_BUILD:-}" >> "%s/fetchlog"\nprintf "#!/usr/bin/env bash\\necho started > \\"%s/started2\\"\\n" > "$(dirname "$0")/canon-go-win.exe"; chmod +x "$(dirname "$0")/canon-go-win.exe"\n' "$tmp" "$tmp" > "$fake/fetch-daemon.sh"
rm -f "$tmp/fetchlog" "$tmp/started2"
bash -c 'source "$1/cockpit-launch-lib.sh"; _is_windows() { return 0; }; start_cockpit_server 4321; wait "$SERVER_PID"' _ "$fake" >/dev/null 2>&1 || true
assert_eq "fetch args=--quiet nobuild=1" "$(cat "$tmp/fetchlog")"
assert_eq "started" "$(cat "$tmp/started2")"
for iw in 0 1; do
  rm -f "$fake/canon-go-win.exe" "$fake/canon-go-bin/canon-go" "$tmp/fetchlog"; printf '#!/usr/bin/env bash\necho x >> "%s/fetchlog"\nexit 1\n' "$tmp" > "$fake/fetch-daemon.sh"
  out="$(IW="$iw" bash -c 'source "$1/cockpit-launch-lib.sh"; _is_windows() { return "$IW"; }; start_cockpit_server 4321; echo "rc=$? pid=${SERVER_PID:-}"' _ "$fake" 2>&1 || true)"
  assert_contains "$out" "run canon update"; assert_eq 1 "$(wc -l < "$tmp/fetchlog" | tr -d ' ')"
  assert_contains "$out" "rc=1 pid="   # the callers (canon, sprint-check) stop on it: `start_cockpit_server … || exit 1`; no board was started
done

printf 'cockpit-launch-lib: ok\n'
