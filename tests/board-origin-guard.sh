#!/usr/bin/env bash
# board-origin-guard (t-957a) — the board's CSRF guard on writes. Both backends
# (server.py, sprint-check-go) must reject a POST/DELETE whose Origin merely
# STARTS WITH a loopback origin (http://127.0.0.1.attacker.example), and still
# accept exact loopback origins with or without a port, and no Origin at all.
# Requests are sent as text/plain — the cross-site "simple request" shape that
# needs no CORS preflight — and every rejection is checked for no side effect.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "board-origin-guard: python3/curl absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
GO_BIN=""
PIDS=()
TMP="$(mktemp -d)"
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  return 0
}
trap cleanup EXIT

if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

FORGED=(
  'http://127.0.0.1.attacker.example'
  'http://localhost.attacker.example'
  'http://127.0.0.1evil'
  'https://127.0.0.1'
  'http://localhost:80.evil'
  'null'
  'http://evil.example'
)

status_of() { sed -n 's/^status: *//p' "$1/.tickets/t-aa11/ticket.md" | head -1; }

run_checks() {
  local kind="$1" label="$2" work canon port base code reg_id legit
  work="$TMP/$kind-proj"; canon="$TMP/$kind-canon"
  mkdir -p "$work/.tickets/t-aa11" "$canon" "$TMP/$kind-ck" "$TMP/$kind-regproj"
  printf -- '---\nid: t-aa11\nstatus: open\ntype: task\npriority: 2\n---\n# Origin guard fixture\n' > "$work/.tickets/t-aa11/ticket.md"
  port="$(free_port)"
  # Isolated registry (CANON_HOME) and cockpit state; no daemon, no browser.
  if [[ "$kind" == py ]]; then
    SPRINT_CHECK_ROOT="$work" CANON_HOME="$canon" COCKPIT_STATE_DIR="$TMP/$kind-ck" COCKPIT_DAEMON_BIN=/usr/bin/false \
      python3 "$SERVER_PY" "$port" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$work" CANON_HOME="$canon" COCKPIT_STATE_DIR="$TMP/$kind-ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_NO_BROWSER=1 \
      "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!")
  disown "$!" 2>/dev/null || true
  base="http://127.0.0.1:$port"
  for _ in $(seq 1 50); do curl -s -o /dev/null "$base/api/git" && break; sleep 0.1; done

  # A registered project to aim DELETE at (added with a legitimate Origin).
  reg_id="$(curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
    -d "{\"path\":\"$TMP/$kind-regproj\",\"description\":\"origin guard\"}" "$base/api/projects" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["project"]["id"])')"
  [[ -n "$reg_id" ]] || fail "$label: could not register the DELETE target"

  local o
  for o in "${FORGED[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $o" -H 'Content-Type: text/plain' \
      -d '{"status":"closed"}' "$base/api/ticket/t-aa11/status")"
    [[ "$code" == 403 ]] || fail "$label: POST with Origin '$o' must 403, got $code"
    [[ "$(status_of "$work")" == open ]] || fail "$label: POST with Origin '$o' changed the ticket"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Origin: $o" "$base/api/projects/$reg_id")"
    [[ "$code" == 403 ]] || fail "$label: DELETE with Origin '$o' must 403, got $code"
    grep -q "$reg_id" "$canon/cockpit/projects.json" || fail "$label: DELETE with Origin '$o' removed the project"
  done

  # Legitimate: exact loopback origins, with and without a port, and no Origin.
  local want=in_progress
  for legit in 'http://127.0.0.1' "http://127.0.0.1:$port" 'http://localhost' "http://localhost:$port" ''; do
    local hdr=()  # empty for the no-Origin case; bash 3.2 + set -u needs the +-guard below
    [[ -n "$legit" ]] && hdr=(-H "Origin: $legit")
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST ${hdr[@]+"${hdr[@]}"} -H 'Content-Type: application/json' \
      -d "{\"status\":\"$want\"}" "$base/api/ticket/t-aa11/status")"
    [[ "$code" == 200 ]] || fail "$label: POST with Origin '${legit:-<none>}' must succeed, got $code"
    [[ "$(status_of "$work")" == "$want" ]] || fail "$label: POST with Origin '${legit:-<none>}' didn't write status $want"
    [[ "$want" == in_progress ]] && want=open || want=in_progress
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Origin: http://localhost:$port" "$base/api/projects/$reg_id")"
  [[ "$code" == 200 ]] || fail "$label: DELETE with a legitimate Origin must succeed, got $code"
  if grep -q "$reg_id" "$canon/cockpit/projects.json"; then fail "$label: legitimate DELETE didn't remove the project"; fi

  echo "  $label: origin guard ok"
}

run_checks py server.py
if [[ -n "$GO_BIN" ]]; then
  run_checks go main.go
else
  echo "  main.go: go absent — Go half skipped"
fi
echo "board-origin-guard: ok"
