#!/usr/bin/env bash
# cockpit-launch-lib.sh — shared launcher helpers for `sprint-check` and
# `canon-cockpit` (t-4700). Source, don't execute: `source
# "$SCRIPT_DIR/cockpit-launch-lib.sh"`.

_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${port}[^0-9]"
  else
    ! python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
try:
    s.bind(('127.0.0.1', int(sys.argv[1]))); s.close()
except OSError:
    sys.exit(1)
" "$port" 2>/dev/null
  fi
}

open_browser() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" &
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$url" &
  elif [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    powershell.exe /c "start '$url'" &
  elif command -v open >/dev/null 2>&1; then
    open "$url"
  else
    echo "Open in your browser: $url" >&2
  fi
}

# cockpit_register_project <cockpit_port> <abs_path> -> prints registry id on
# stdout, or nothing on failure (caller falls back to the bare /cockpit URL).
# Idempotent: an already-registered path is looked up rather than re-added.
cockpit_register_project() {
  local port="$1" path="$2"
  command -v curl >/dev/null 2>&1 || return 1
  local base="http://127.0.0.1:$port"
  local resp
  resp="$(curl -s -X POST "$base/api/projects" \
    -H 'Content-Type: application/json' -H "Origin: $base" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1]}))' "$path" 2>/dev/null)" \
    2>/dev/null)" || return 1
  local id
  id="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("ok") and d.get("project"):
    print(d["project"]["id"])
' <<<"$resp" 2>/dev/null)"
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi
  # Already registered — look it up by resolved path instead of reimplementing
  # the registry's path-hash id locally.
  python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception:
    sys.exit(0)
target = sys.argv[1]
for e in entries:
    if e.get("path") == target:
        print(e["id"]); break
' "$path" < <(curl -s "$base/api/projects" -H "Origin: $base" 2>/dev/null) 2>/dev/null
}
