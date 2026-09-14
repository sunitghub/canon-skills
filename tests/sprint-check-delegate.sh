#!/usr/bin/env bash
# sprint-check-delegate.sh — sprint-check delegates into Canon Cockpit instead
# of starting a private per-project server (t-4700).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-delegate: skipped (python3/curl not both present)"
  exit 0
fi

PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"

WORK="$(mktemp -d)"
PROJECT="$WORK/proj"
mkdir -p "$PROJECT/.tickets"
( cd "$PROJECT" && git init -q && git commit -q --allow-empty -m init )
PROJECT_RESOLVED="$(cd -P "$PROJECT" && pwd -P)"  # registry stores the symlink-resolved path

STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/open" <<'SH'
#!/usr/bin/env bash
echo "STUB-OPEN $*" >> "$SC_OPEN_LOG"
SH
chmod +x "$STUBDIR/open"
export SC_OPEN_LOG="$WORK/open.log"; : > "$SC_OPEN_LOG"
export CANON_HOME="$WORK/.canon"

SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ── Cold start: nothing listening on the cockpit port yet ──────────────────
( cd "$PROJECT" && PATH="$STUBDIR:$PATH" exec "$ROOT/tools/sprint-check" "$PORT" ) \
  >"$WORK/cold.log" 2>&1 &
SRV_PID=$!

for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/projects" && break; sleep 0.1; done
# poll for the register + open_browser calls to land after the server answers,
# instead of a fixed sleep (flaky under load — reviewer-caught, t-4700)
for i in $(seq 1 50); do [[ -s "$SC_OPEN_LOG" ]] && break; sleep 0.1; done

n="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] || fail "sprint-check-delegate: expected exactly 1 listener after cold start, found $n"

grep -q "$PROJECT_RESOLVED" "$CANON_HOME/cockpit/projects.json" 2>/dev/null || \
  fail "sprint-check-delegate: project was not registered in the Cockpit registry"

grep -qE 'STUB-OPEN .*#open=[0-9a-f]{12}' "$SC_OPEN_LOG" || \
  fail "sprint-check-delegate: expected a #open=<id> deep link, got: $(cat "$SC_OPEN_LOG")"

# ── Warm start: cockpit already running, run sprint-check again ───────────
: > "$SC_OPEN_LOG"
( cd "$PROJECT" && PATH="$STUBDIR:$PATH" "$ROOT/tools/sprint-check" "$PORT" ) >/dev/null 2>&1 || true

n="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] || fail "sprint-check-delegate: expected still exactly 1 listener after warm start, found $n"

grep -qE 'STUB-OPEN .*#open=[0-9a-f]{12}' "$SC_OPEN_LOG" || \
  fail "sprint-check-delegate: warm start expected a #open=<id> deep link, got: $(cat "$SC_OPEN_LOG")"

# re-registering the same path must not duplicate the registry entry
count="$(python3 -c "
import json
d=json.load(open('$CANON_HOME/cockpit/projects.json'))
print(sum(1 for e in d if e['path']=='$PROJECT_RESOLVED'))
")"
[[ "$count" == "1" ]] || fail "sprint-check-delegate: expected 1 registry entry for the project, found $count"

echo "sprint-check-delegate: OK"
