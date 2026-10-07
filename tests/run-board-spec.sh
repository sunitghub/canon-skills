#!/usr/bin/env bash
# run-board-spec — t-4469: run the full board Playwright spec (tests/sprint-check-app.spec.js) the one reproducible way.
#
#   tests/run-board-spec.sh [--runs N] [--browsers chromium,webkit] [--out DIR] [--grep PATTERN] [--strict] [--no-guard] [--keep]
#
# Why a copy: the spec writes and deletes tickets under its project root, so it must never run against canon's own
# tree. Why not an empty repo: several tests expect a populated board, and the timing differs from real use (an empty
# repo once hid 9 tests behind a serial group's first failure). So this copies the working tree (the gitignored .tickets
# included), starts the Go board FROM THE COPY (so its model-tiers.json is the copy's too), runs each browser N times,
# then checks that canon's own tree is unchanged and runs tests/board-spec-guard.js on the JSON reports.
# Needs: rsync, go, node, npx (Playwright browsers installed), git, curl, python3. macOS/Linux; ~8 min per browser per run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNS=3; BROWSERS="chromium,webkit"; OUT=""; GREP=""; STRICT=""; GUARD=1; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --browsers) BROWSERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --grep) GREP="$2"; shift 2 ;;
    --strict) STRICT="--strict"; shift ;;
    --no-guard) GUARD=0; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "run-board-spec: unknown option $1" >&2; exit 2 ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*|0) echo "run-board-spec: --runs needs a positive number" >&2; exit 2 ;; esac
for tool in rsync go node npx git curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run-board-spec: $tool is required" >&2; exit 2; }
done

TMP="${TMPDIR:-/tmp}"
if [ -z "$OUT" ]; then OUT="$(mktemp -d "$TMP/board-spec-out.XXXXXX")"; else mkdir -p "$OUT"; fi
OUT="$(cd "$OUT" && pwd -P)"
COPY="$(mktemp -d "$TMP/board-spec-copy.XXXXXX")"
COPY="$(cd "$COPY" && pwd -P)"
BOARD_PID=""

cleanup() {
  if [ -n "$BOARD_PID" ]; then
    pkill -P "$BOARD_PID" 2>/dev/null || true
    kill "$BOARD_PID" 2>/dev/null || true
  fi
  # Only ever remove the directory this script made, and only under its own name.
  if [ "$KEEP" = 0 ] && [ -n "$COPY" ] && [ "$COPY" != "$ROOT" ]; then
    case "$COPY" in */board-spec-copy.*) rm -rf -- "$COPY" ;; esac
  fi
}
trap cleanup EXIT

snapshot() {
  printf 'git-status=%s tickets=%s model-tiers=%s\n' \
    "$(git -C "$ROOT" status --porcelain | cksum | cut -d' ' -f1)" \
    "$(ls "$ROOT/.tickets" 2>/dev/null | wc -l | tr -d ' ')" \
    "$(shasum "$ROOT/tools/sprint-check-app/model-tiers.json" 2>/dev/null | cut -d' ' -f1)"
}
BEFORE="$(snapshot)"
echo "run-board-spec: canon tree before: $BEFORE"

echo "run-board-spec: copying the working tree (incl. .tickets) to $COPY"
rsync -a --exclude node_modules --exclude test-results --exclude playwright-report "$ROOT/" "$COPY/"
ln -s "$ROOT/node_modules" "$COPY/node_modules"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
(cd "$COPY" && CANON_HOME="$COPY/.spec-canon-home" SPRINT_CHECK_ROOT="$COPY" SPRINT_CHECK_NO_BROWSER=1 GO111MODULE=off exec go run ./tools/sprint-check-go "$PORT" >/dev/null 2>&1) &
BOARD_PID=$!
ready=0
for _ in $(seq 1 240); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/git"; then ready=1; break; fi
  sleep 0.25
done
[ "$ready" = 1 ] || { echo "run-board-spec: the board did not start on port $PORT" >&2; exit 2; }
echo "run-board-spec: board from the copy on port $PORT; $RUNS run(s) of: $BROWSERS; reports go to $OUT"

IFS=',' read -r -a BLIST <<< "$BROWSERS"
for b in "${BLIST[@]}"; do
  for n in $(seq 1 "$RUNS"); do
    report="$OUT/board-spec-$b-run$n.json"
    echo "run-board-spec: $b run $n/$RUNS"
    (cd "$COPY" && PLAYWRIGHT_JSON_OUTPUT_NAME="$report" SPRINT_CHECK_BASE="http://127.0.0.1:$PORT" SPRINT_CHECK_TEST_ROOT="$COPY" \
      npx playwright test tests/sprint-check-app.spec.js --browser="$b" --reporter=json,line ${GREP:+--grep "$GREP"} >"$OUT/board-spec-$b-run$n.log" 2>&1) || true
    [ -s "$report" ] || { echo "run-board-spec: no JSON report for $b run $n (see $OUT/board-spec-$b-run$n.log)" >&2; exit 2; }
  done
done

# Stop the board, then prove nothing of ours is left and canon's own tree did not move.
pkill -P "$BOARD_PID" 2>/dev/null || true
kill "$BOARD_PID" 2>/dev/null || true
wait "$BOARD_PID" 2>/dev/null || true
BOARD_PID=""
sleep 1
LEFT="$(ps -axo pid,command | grep -F "$COPY" | grep -v grep | grep -v "run-board-spec" || true)"
if command -v lsof >/dev/null 2>&1; then
  LISTEN="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  [ -z "$LISTEN" ] || LEFT="$LEFT"$'\n'"listener on port $PORT: pid $LISTEN"
fi
LEFT="$(printf '%s' "$LEFT" | sed '/^$/d')"
AFTER="$(snapshot)"
echo "run-board-spec: canon tree after:  $AFTER"
status=0
if [ -n "$LEFT" ]; then echo "run-board-spec: processes from the copy are still running:" >&2; echo "$LEFT" >&2; status=2; else echo "run-board-spec: no process left running from the copy"; fi
if [ "$BEFORE" != "$AFTER" ]; then echo "run-board-spec: canon's own tree CHANGED during the run (before/after above)" >&2; status=2; else echo "run-board-spec: canon's own tree is unchanged"; fi

if [ "$GUARD" = 1 ]; then
  node "$ROOT/tests/board-spec-guard.js" ${GREP:+--partial} ${STRICT} "$OUT"/board-spec-*-run*.json || status=$?
else
  echo "run-board-spec: guard skipped (--no-guard); reports are in $OUT"
fi
exit "$status"
