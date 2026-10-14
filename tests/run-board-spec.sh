#!/usr/bin/env bash
# run-board-spec — t-4469: run the full board Playwright spec (tests/sprint-check-app.spec.js) the one reproducible way.
#
#   tests/run-board-spec.sh [--runs N] [--browsers chromium,webkit] [--out DIR] [--grep PATTERN] [--strict] [--no-guard] [--keep]
#                           [--classify [--solo-runs N] [--base REF]]
#
# Why a copy: the spec writes and deletes tickets under its project root, so it must never run against canon's own
# tree. Why not an empty repo: several tests expect a populated board, and the timing differs from real use (an empty
# repo once hid 9 tests behind a serial group's first failure). So this copies the working tree (the gitignored .tickets
# included), starts the Go board FROM THE COPY (so its model-tiers.json is the copy's too), runs each browser N times,
# then checks that canon's own tree is unchanged and runs tests/board-spec-guard.js on the JSON reports.
# --classify (t-b860): when the guard finds failures not in the baseline, rerun each alone --solo-runs times (default 3)
# on the same copy and, with --base REF, on a second copy made by `git archive REF` (same .tickets) with its own board,
# then print each one's error kind, its solo counts and, only for a load timeout that passed every solo run on both, a
# baseline entry to paste by hand (tests/board-spec-classify.js). The exit status stays the guard's; the baseline is
# never written.
# Needs: rsync, go, node, npx (Playwright browsers installed), git, curl, python3. macOS/Linux; ~8 min per browser per run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNS=3; BROWSERS="chromium,webkit"; OUT=""; GREP=""; STRICT=""; GUARD=1; KEEP=0; CLASSIFY=0; SOLO_RUNS=3; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --browsers) BROWSERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --grep) GREP="$2"; shift 2 ;;
    --strict) STRICT="--strict"; shift ;;
    --no-guard) GUARD=0; shift ;;
    --keep) KEEP=1; shift ;;
    --classify) CLASSIFY=1; shift ;;
    --solo-runs) SOLO_RUNS="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "run-board-spec: unknown option $1" >&2; exit 2 ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*|0) echo "run-board-spec: --runs needs a positive number" >&2; exit 2 ;; esac
case "$SOLO_RUNS" in ''|*[!0-9]*|0) echo "run-board-spec: --solo-runs needs a positive number" >&2; exit 2 ;; esac
if [ -n "$BASE" ] && [ "$CLASSIFY" = 0 ]; then echo "run-board-spec: --base needs --classify" >&2; exit 2; fi
if [ "$CLASSIFY" = 1 ] && [ "$GUARD" = 0 ]; then echo "run-board-spec: --classify needs the guard (drop --no-guard)" >&2; exit 2; fi
for tool in rsync go node npx git curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run-board-spec: $tool is required" >&2; exit 2; }
done

TMP="${TMPDIR:-/tmp}"
if [ -z "$OUT" ]; then OUT="$(mktemp -d "$TMP/board-spec-out.XXXXXX")"; else mkdir -p "$OUT"; fi
OUT="$(cd "$OUT" && pwd -P)"
if [ -n "$BASE" ]; then
  BASE_SHA="$(git -C "$ROOT" rev-parse --short --verify "$BASE^{commit}" 2>/dev/null)" || { echo "run-board-spec: --base $BASE is not a commit" >&2; exit 2; }
fi
COPY="$(mktemp -d "$TMP/board-spec-copy.XXXXXX")"
COPY="$(cd "$COPY" && pwd -P)"
BOARD_PID=""; BASE_COPY=""; BASE_PID=""; BASE_PORT=""

stop_pid() {
  if [ -n "$1" ]; then
    pkill -P "$1" 2>/dev/null || true
    kill "$1" 2>/dev/null || true
  fi
}
cleanup() {
  stop_pid "$BOARD_PID"
  stop_pid "$BASE_PID"
  # Only ever remove the directories this script made, and only under their own names.
  if [ "$KEEP" = 0 ]; then
    for d in "$COPY" "$BASE_COPY"; do
      if [ -n "$d" ] && [ "$d" != "$ROOT" ]; then
        case "$d" in */board-spec-copy.*|*/board-spec-base.*) rm -rf -- "$d" ;; esac
      fi
    done
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

# Start the Go board from copy $1; sets STARTED_PORT and STARTED_PID. Called directly, never in $(...), so the PID it
# records survives for cleanup.
start_board() {
  STARTED_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  (cd "$1" && CANON_HOME="$1/.spec-canon-home" SPRINT_CHECK_ROOT="$1" SPRINT_CHECK_NO_BROWSER=1 GO111MODULE=off exec go run ./tools/sprint-check-go "$STARTED_PORT" >/dev/null 2>&1) &
  STARTED_PID=$!
}
wait_board() {
  local ready=0
  for _ in $(seq 1 240); do
    if curl -s -o /dev/null "http://127.0.0.1:$1/api/git"; then ready=1; break; fi
    sleep 0.25
  done
  [ "$ready" = 1 ] || { echo "run-board-spec: the board did not start on port $1" >&2; exit 2; }
}
start_board "$COPY"; PORT="$STARTED_PORT"; BOARD_PID="$STARTED_PID"
wait_board "$PORT"
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

# Stop the boards, then prove nothing of ours is left and canon's own tree did not move. Sets STATUS to 2 on a problem.
stop_and_check() {
  local pid
  for pid in "$BOARD_PID" "$BASE_PID"; do
    [ -n "$pid" ] || continue
    stop_pid "$pid"
    wait "$pid" 2>/dev/null || true
  done
  BOARD_PID=""; BASE_PID=""
  sleep 1
  local d p left="" listen
  for d in "$COPY" "$BASE_COPY"; do
    [ -n "$d" ] || continue
    left="$left"$'\n'"$(ps -axo pid,command | grep -F "$d" | grep -v grep | grep -v "run-board-spec" || true)"
  done
  if command -v lsof >/dev/null 2>&1; then
    for p in "$PORT" "$BASE_PORT"; do
      [ -n "$p" ] || continue
      listen="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null || true)"
      [ -z "$listen" ] || left="$left"$'\n'"listener on port $p: pid $listen"
    done
  fi
  left="$(printf '%s' "$left" | sed '/^$/d')"
  AFTER="$(snapshot)"
  echo "run-board-spec: canon tree after:  $AFTER"
  if [ -n "$left" ]; then echo "run-board-spec: processes from the copy are still running:" >&2; echo "$left" >&2; STATUS=2; else echo "run-board-spec: no process left running from the copy"; fi
  if [ "$BEFORE" != "$AFTER" ]; then echo "run-board-spec: canon's own tree CHANGED during the run (before/after above)" >&2; STATUS=2; else echo "run-board-spec: canon's own tree is unchanged"; fi
}

# Rerun one test alone SOLO_RUNS times against a copy and its board; reports go to $OUT/solo/<side>-<i>-run<k>.json.
solo_runs() { # side copy port browser pattern index
  local k
  for k in $(seq 1 "$SOLO_RUNS"); do
    (cd "$2" && PLAYWRIGHT_JSON_OUTPUT_NAME="$OUT/solo/$1-$6-run$k.json" SPRINT_CHECK_BASE="http://127.0.0.1:$3" SPRINT_CHECK_TEST_ROOT="$2" \
      npx playwright test tests/sprint-check-app.spec.js --browser="$4" --reporter=json,line --grep "$5" >"$OUT/solo/$1-$6-run$k.log" 2>&1) || true
  done
}

classify() {
  local list i=0 b pattern head
  list="$(node "$ROOT/tests/board-spec-classify.js" list "$OUT"/board-spec-*-run*.json)" || { echo "run-board-spec: classify could not list the failures" >&2; STATUS=2; return 0; }
  if [ -z "$list" ]; then echo "run-board-spec: classify: no unlisted failures to rerun (the violations are of another kind)"; return 0; fi
  mkdir -p "$OUT/solo"
  if [ -n "$BASE" ]; then
    BASE_COPY="$(mktemp -d "$TMP/board-spec-base.XXXXXX")"
    BASE_COPY="$(cd "$BASE_COPY" && pwd -P)"
    echo "run-board-spec: classify: copying $BASE ($BASE_SHA) with the same .tickets to $BASE_COPY"
    git -C "$ROOT" archive "$BASE_SHA" | tar -x -C "$BASE_COPY"
    rsync -a "$ROOT/.tickets/" "$BASE_COPY/.tickets/"
    ln -s "$ROOT/node_modules" "$BASE_COPY/node_modules"
    start_board "$BASE_COPY"; BASE_PORT="$STARTED_PORT"; BASE_PID="$STARTED_PID"
    wait_board "$BASE_PORT"
    echo "run-board-spec: classify: board from the base copy on port $BASE_PORT"
  fi
  while IFS=$'\t' read -r b pattern; do
    i=$((i + 1))
    echo "run-board-spec: classify: test $i ($b), $SOLO_RUNS solo run(s)${BASE:+ on the branch and on $BASE}"
    solo_runs branch "$COPY" "$PORT" "$b" "$pattern" "$i"
    if [ -n "$BASE" ]; then solo_runs base "$BASE_COPY" "$BASE_PORT" "$b" "$pattern" "$i"; fi
  done <<< "$list"
  head="$(git -C "$ROOT" rev-parse --short HEAD)"
  if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then head="$head+uncommitted"; fi
  node "$ROOT/tests/board-spec-classify.js" report --solo "$OUT/solo" --solo-runs "$SOLO_RUNS" --head "$head" \
    ${BASE:+--base-ref "$BASE" --base-sha "$BASE_SHA"} "$OUT"/board-spec-*-run*.json || STATUS=2
}

STATUS=0; GUARD_STATUS=0
if [ "$CLASSIFY" = 1 ]; then
  # The boards stay up for the solo reruns; the stop-and-check runs after them.
  node "$ROOT/tests/board-spec-guard.js" ${GREP:+--partial} ${STRICT} "$OUT"/board-spec-*-run*.json || GUARD_STATUS=$?
  if [ "$GUARD_STATUS" = 1 ]; then classify; fi
  stop_and_check
else
  stop_and_check
  if [ "$GUARD" = 1 ]; then
    node "$ROOT/tests/board-spec-guard.js" ${GREP:+--partial} ${STRICT} "$OUT"/board-spec-*-run*.json || GUARD_STATUS=$?
  else
    echo "run-board-spec: guard skipped (--no-guard); reports are in $OUT"
  fi
fi
if [ "$GUARD_STATUS" != 0 ]; then STATUS="$GUARD_STATUS"; fi
exit "$STATUS"
