#!/usr/bin/env bash
# sprint-check — local kanban dashboard for canon projects
# Starts a Python HTTP server and opens the board in the default browser.

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR always points to the real file location
_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
  _SOURCE="$(readlink "$_SOURCE")"
  [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
SERVER="$SCRIPT_DIR/sprint-check/server.py"

# ── Port selection ─────────────────────────────────────────────────────────

find_free_port() {
  local port="${1:-8423}"
  while lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; do
    ((port++))
  done
  echo "$port"
}

# ── Browser open (cross-platform) ─────────────────────────────────────────

open_browser() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" &
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$url" &
  elif [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    # WSL without wslview — use Windows
    powershell.exe /c "start '$url'" &
  elif command -v open >/dev/null 2>&1; then
    open "$url"
  else
    echo "Open in your browser: $url" >&2
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
  if [[ ! -f "$SERVER" ]]; then
    echo "Error: server.py not found at $SERVER" >&2
    exit 1
  fi

  PORT="$(find_free_port 8423)"
  URL="http://127.0.0.1:$PORT"

  # Export project root for the server
  export SPRINT_CHECK_ROOT="${SPRINT_CHECK_ROOT:-$PWD}"

  # Start server in background
  python3 "$SERVER" "$PORT" &
  SERVER_PID=$!

  # Clean up on exit
  trap 'kill "$SERVER_PID" 2>/dev/null; exit 0' INT TERM EXIT

  # Brief pause so the server is ready before the browser hits it
  sleep 0.4

  open_browser "$URL"

  # Wait for server process
  wait "$SERVER_PID"
}

main "$@"
