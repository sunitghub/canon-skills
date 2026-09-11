#!/usr/bin/env bash
# canon-cockpit.sh — launcher single-instance + /cockpit landing tests (t-9917).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "canon-cockpit: skipped (python3/curl not both present)"
  exit 0
fi

# ── T4: single-instance — a second launch must NOT start a second server ──────
# We simulate "already running" by occupying the port with a server, then assert
# the launcher's port-in-use path is taken (it prints "already running" + opens
# the URL rather than binding). We drive the launcher with a stub browser opener
# and a very short timeout so it can't block.

PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [[ -n "${SRV:-}" ]] && kill "$SRV" 2>/dev/null || true' EXIT

# occupy the port with the real server
CANON_HOME="$WORK/.canon" SPRINT_CHECK_ROOT="$ROOT" python3 "$ROOT/tools/sprint-check-app/server.py" "$PORT" >/dev/null 2>&1 &
SRV=$!
for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/projects" && break; sleep 0.1; done

# launcher with a stubbed browser opener on PATH so it can't actually open a browser
STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/open" <<'SH'
#!/usr/bin/env bash
echo "STUB-OPEN $*" >> "$CC_OPEN_LOG"
SH
chmod +x "$STUBDIR/open"

CC_OPEN_LOG="$WORK/open.log"; : > "$CC_OPEN_LOG"
# Run the launcher; because the port is in use it must hit the single-instance
# branch (print "already running", open URL, exit 0) WITHOUT starting a server.
out="$(CC_OPEN_LOG="$CC_OPEN_LOG" PATH="$STUBDIR:$PATH" "$ROOT/tools/canon-cockpit" "$PORT" 2>&1)" || true
echo "$out" | grep -qi "already running" || fail "canon-cockpit: expected single-instance 'already running' message, got: $out"

# still exactly one listener on the port (the launcher didn't bind a second)
n="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] || fail "canon-cockpit: expected exactly 1 listener after 2nd launch, found $n"

# ── T5: /cockpit landing serves the Projects page with key elements ───────────
page="$(curl -s -H 'Host: localhost' "http://127.0.0.1:$PORT/cockpit")"
echo "$page" | grep -q "<title>Canon Cockpit</title>" || fail "canon-cockpit: /cockpit missing Canon Cockpit title"
echo "$page" | grep -q "Add Project" || fail "canon-cockpit: /cockpit missing Add Project"
echo "$page" | grep -q "projFilter" || fail "canon-cockpit: /cockpit missing project filter dropdown"
echo "$page" | grep -q "escAttr" || fail "canon-cockpit: /cockpit missing quote-safe escAttr (XSS guard)"
# the page must NOT use inline onclick with interpolated user data (uses data-attr + listeners)
echo "$page" | grep -q "onclick=\"dereg(" && fail "canon-cockpit: /cockpit still has inline onclick with interpolated data (XSS risk)"

echo "canon-cockpit: ok (single-instance no-2nd-server; /cockpit serves Projects page with filter + Add + quote-safe escaping)"
