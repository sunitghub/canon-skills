#!/usr/bin/env bash
# cockpit-launch-lib.sh — shared launcher helpers for `sprint-check` and
# `canon-cockpit` (t-4700). Source, don't execute: `source
# "$SCRIPT_DIR/cockpit-launch-lib.sh"`.
#
# t-55c1: nothing here may require Python. On Windows canon may assume only Git for Windows, so the
# port check, browser open and project registration are bash/coreutils/curl only, and the server
# itself falls back to the Go sprint-check-win.exe when there's no working Python.

# shellcheck source=tools/platform-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${port}[^0-9]"
  else
    # Git Bash has neither lsof nor ss. Bash's own /dev/tcp connects only if something is listening.
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
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
  elif _is_windows; then
    MSYS_NO_PATHCONV=1 cmd.exe /c start "" "$url" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then
    open "$url"
  else
    echo "Open in your browser: $url" >&2
  fi
}

# start_cockpit_server <port> — background the board server; sets SERVER_PID. Python's server.py
# where a working Python exists (unchanged); on Windows without one, the Go sprint-check-win.exe, the
# same parity-tested server canon-cockpit-win.cmd runs (t-55c1). The caller opens the browser.
start_cockpit_server() {
  local port="$1" dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if _is_windows && ! have_python; then
    local exe="$dir/sprint-check-win.exe"
    if [[ ! -f "$exe" ]]; then
      echo "Error: no working Python and no $exe — run canon-cockpit-win instead." >&2
      return 1
    fi
    echo "No Python here — starting the Go board server (sprint-check-win.exe)." >&2
    SPRINT_CHECK_NO_BROWSER=1 "$exe" "$port" &
  else
    python3 "$dir/sprint-check-app/server.py" "$port" &
  fi
  SERVER_PID=$!
}

# JSON string escaping for a filesystem path (backslash and double quote; paths carry no control chars).
_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# cockpit_register_project <cockpit_port> <abs_path> -> prints registry id on
# stdout, or nothing on failure (caller falls back to the bare /cockpit URL).
# Idempotent: an already-registered path is looked up rather than re-added.
# Parses the board's own JSON (both backends: `"key": "v"` or `"key":"v"`) with sed/awk, no Python.
cockpit_register_project() {
  local port="$1" path="$2"
  command -v curl >/dev/null 2>&1 || return 1
  local base="http://127.0.0.1:$port" esc resp id
  esc="$(_json_escape "$path")"
  resp="$(curl -s -X POST "$base/api/projects" \
    -H 'Content-Type: application/json' -H "Origin: $base" \
    -d "{\"path\": \"$esc\"}" 2>/dev/null)" || return 1
  if printf '%s' "$resp" | grep -q '"ok": *true'; then
    id="$(printf '%s' "$resp" | sed -n 's/.*"project": *{[^}]*"id": *"\([^"]*\)".*/\1/p' | head -1)"
    if [[ -n "$id" ]]; then
      echo "$id"
      return 0
    fi
  fi
  # Already registered — look it up by resolved path instead of reimplementing
  # the registry's path-hash id locally: one object per record, match its exact "path".
  curl -s "$base/api/projects" -H "Origin: $base" 2>/dev/null | tr '\n' ' ' |
    WANT="\"$esc\"" awk 'BEGIN { RS = "}"; want = ENVIRON["WANT"] } {   # ENVIRON: -v would unescape \"
      if (match($0, /"path": *"([^"\\]|\\.)*"/)) {
        p = substr($0, RSTART, RLENGTH); sub(/^"path": */, "", p)
        if (p == want && match($0, /"id": *"[^"]*"/)) {
          i = substr($0, RSTART, RLENGTH); sub(/^"id": *"/, "", i); sub(/"$/, "", i); print i; exit
        }
      }
    }'
}
