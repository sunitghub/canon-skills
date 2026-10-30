#!/usr/bin/env bash
# run-board-spec — t-4469: run the full board Playwright spec (tests/sprint-check-app.spec.js) the one reproducible way.
# t-23f6: Chromium runs every test, WebKit only those tagged @webkit in their title (engine-sensitive: scroll, focus, layout, clipboard...).
#
#   tests/run-board-spec.sh [--runs N] [--browsers chromium,webkit] [--out DIR] [--grep PATTERN] [--strict] [--no-guard] [--keep] [--allow-busy]
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
# Every run records the machine's load at start and end in $OUT/machine-load.txt and prints a WARNING when another spec or test.sh
# run is going or the load exceeds the CPU count: WebKit fails timing-sensitive tests under load (t-5989).
# t-8627: a run does not START on such a machine: it waits up to ML_WAIT_MAX seconds (900) for it to calm, then exits 2 (--allow-busy runs anyway).
# t-43a2: without --runs each browser runs ONCE and is repeated (up to 3) only if the guard rejects its first report; --runs N is exactly N.
# Needs: rsync, go, node, npx (Playwright browsers installed), git, curl, python3. macOS/Linux; ~13-18 min per browser per run
# (the spec is one file, so Playwright runs it on one worker; measured 2026-10-15, t-5989).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNS=3; RUNS_SET=0; BROWSERS="chromium,webkit"; OUT=""; GREP=""; STRICT=""; GUARD=1; KEEP=0; CLASSIFY=0; SOLO_RUNS=3; BASE=""; ALLOW_BUSY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; RUNS_SET=1; shift 2 ;;
    --browsers) BROWSERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --grep) GREP="$2"; shift 2 ;;
    --strict) STRICT="--strict"; shift ;;
    --no-guard) GUARD=0; shift ;;
    --keep) KEEP=1; shift ;;
    --allow-busy) ALLOW_BUSY=1; shift ;;
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

if [ -n "$BASE" ]; then
  BASE_SHA="$(git -C "$ROOT" rev-parse --short --verify "$BASE^{commit}" 2>/dev/null)" || { echo "run-board-spec: --base $BASE is not a commit" >&2; exit 2; }
fi
TMP="${TMPDIR:-/tmp}"
if [ -z "$OUT" ]; then OUT="$(mktemp -d "$TMP/board-spec-out.XXXXXX")"; else mkdir -p "$OUT"; fi
OUT="$(cd "$OUT" && pwd -P)"
COPY="$(mktemp -d "$TMP/board-spec-copy.XXXXXX")"
COPY="$(cd "$COPY" && pwd -P)"
# t-5989: a busy machine (another spec or test.sh run, or load over the CPU count) makes WebKit fail timing-sensitive tests, so every
# run records its load at start and end in $OUT/machine-load.txt and warns when it is too busy to trust.
source "$ROOT/tests/machine-load.sh"
# t-8627: wait for a quiet machine before starting (up to ML_WAIT_MAX seconds), else refuse; --allow-busy skips the wait.
if [ "$ALLOW_BUSY" = 0 ] && ! machine_wait_quiet "$OUT/machine-load.txt" "$$"; then
  echo "run-board-spec: the machine stayed busy; wait for it to calm, or pass --allow-busy to run anyway (WebKit will fail timing tests)" >&2
  rmdir "$COPY" 2>/dev/null || true
  exit 2
fi
machine_load start "$OUT/machine-load.txt" "$$"
# t-cab4: the source's worktrees, beside the load, so a failure that depends on them can be told from a regression
{ git -C "$ROOT" worktree list 2>/dev/null || echo "unknown"; } | sed 's/^/machine-load: worktrees: /' >> "$OUT/machine-load.txt" || true
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
# t-cab4: the copy's .git carries this machine's worktrees (.git/worktrees/*), so the board in it listed real leftovers and
# t-8a2a failed on them while --classify's git-archive base copy (no .git) passed; the copy sees none, like the base copy.
rm -rf "$COPY/.git/worktrees"
ln -s "$ROOT/node_modules" "$COPY/node_modules"

# Start the Go board from copy $1; sets STARTED_PORT and STARTED_PID. Called directly, never in $(...), so the PID it
# records survives for cleanup. COCKPIT_STATE_DIR too: its default ($TMPDIR/canon-cockpit-board) is the real Cockpit daemon's, and a
# board that finds the user's live daemon there fails the leave-session tests (t-2992). COCKPIT_DAEMON_BIN names no file, so the
# board never launches a daemon of its own: one would outlive it (detached by design) and fail the same tests later in the run.
# t-6fb8: a `go run` board has no VERSION file beside its executable, so it says "no release version (dev)" and Set up CI gate
# (rightly) refuses to write a workflow pinned to a tag. Stamp it the way an install is stamped (fetch-daemon.sh, -X main.version)
# so the browser spec exercises the write path. GOFLAGS, not a flag after `go run`: tests/no-browser-in-tests.sh finds board
# starts by the `go run ./cmd/canon-go` spelling.
start_board() {
  STARTED_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  (cd "$1/tools/canon-go" && CANON_HOME="$1/.spec-canon-home" COCKPIT_STATE_DIR="$1/.spec-cockpit-state" COCKPIT_DAEMON_BIN="$1/.spec-no-daemon" SPRINT_CHECK_ROOT="$1" SPRINT_CHECK_NO_BROWSER=1 GOFLAGS='-ldflags=-X=main.version=0.0.0' exec go run ./cmd/canon-go "$STARTED_PORT" >/dev/null 2>&1) &
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
if [ "$RUNS_SET" = 1 ]; then RUNS_NOTE="$RUNS run(s)"; else RUNS_NOTE="one pass per browser, repeated (up to $RUNS) only for a browser the guard rejects"; fi
echo "run-board-spec: board from the copy on port $PORT; $RUNS_NOTE; browsers: $BROWSERS; reports go to $OUT"

IFS=',' read -r -a BLIST <<< "$BROWSERS"
# t-23f6: Chromium runs every test; WebKit only the engine-sensitive ones, tagged @webkit in the title. A user --grep narrows
# both: for WebKit a lookahead pair makes a title need @webkit AND the user's pattern (Playwright matches the whole
# "project file suite test" line, so each lookahead scans it from the start).
grep_for() {   # grep_for <browser>: the --grep pattern for that browser, empty for none
  if [ "$1" != webkit ]; then printf '%s' "$GREP"
  elif [ -n "$GREP" ]; then printf '^(?=.*@webkit)(?=.*(?:%s))' "$GREP"
  else printf '@webkit'
  fi
}
run_pass() {   # run_pass <browser> <n>
  local b="$1" n="$2" report="$OUT/board-spec-$1-run$2.json" bgrep
  bgrep="$(grep_for "$b")"
  if [ "$RUNS_SET" = 1 ]; then echo "run-board-spec: $b run $n/$RUNS"; else echo "run-board-spec: $b run $n (first pass; up to $RUNS only if rejected)"; fi
  (cd "$COPY" && PLAYWRIGHT_JSON_OUTPUT_NAME="$report" SPRINT_CHECK_BASE="http://127.0.0.1:$PORT" SPRINT_CHECK_TEST_ROOT="$COPY" \
    npx playwright test tests/sprint-check-app.spec.js --browser="$b" --reporter=json,line ${bgrep:+--grep "$bgrep"} >"$OUT/board-spec-$b-run$n.log" 2>&1) || true
  [ -s "$report" ] || { echo "run-board-spec: no JSON report for $b run $n (see $OUT/board-spec-$b-run$n.log)" >&2; exit 2; }
}
# t-43a2: without --runs, one pass per browser, and a browser is repeated (up to $RUNS) only when the guard rejects its first report.
# --runs N is exactly N runs, as before.
if [ "$RUNS_SET" = 1 ]; then LAST="$RUNS"; else LAST=1; fi
for b in "${BLIST[@]}"; do
  rm -f "$OUT"/board-spec-"$b"-run*.json "$OUT"/board-spec-"$b"-run*.log   # a reused --out must not leave an earlier run's reports for the guard and the stamp to judge
  for n in $(seq 1 "$LAST"); do run_pass "$b" "$n"; done
done
if [ "$RUNS_SET" = 0 ]; then
  for b in "${BLIST[@]}"; do
    if [ "$GUARD" != 1 ]; then echo "run-board-spec: $b: run 1 only (the guard is skipped: nothing to judge a repeat by)"; continue; fi
    if node "$ROOT/tests/board-spec-guard.js" --partial ${STRICT} "$OUT/board-spec-$b-run1.json" >"$OUT/probe-$b.log" 2>&1; then
      echo "run-board-spec: $b: run 1 clean, no repeat needed"
    else
      echo "run-board-spec: $b: run 1 was rejected by the guard (see $OUT/probe-$b.log), repeating (runs 2 to $RUNS)"
      for n in $(seq 2 "$RUNS"); do run_pass "$b" "$n"; done
    fi
  done
fi

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

machine_load end "$OUT/machine-load.txt" "$$"
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
# t-a3d7: name the reports and their sha256 in the output, so a stamped log of this run binds them: evidence.sh check can then count
# the run as re-judged by a later guard log over the same, unchanged files when only the baseline moved.
echo "run-board-spec: report dir $OUT"
for r in "$OUT"/board-spec-*-run*.json; do
  [ -f "$r" ] || continue
  if command -v sha256sum >/dev/null 2>&1; then h="$(sha256sum -- "$r" | cut -d' ' -f1)"; else h="$(shasum -a 256 -- "$r" | cut -d' ' -f1)"; fi
  echo "run-board-spec: report ${r##*/} sha256 $h"
done
# A leaked process or a moved tree (2) outranks the guard's 1, or listing the flakes later would make the run look covered.
if [ "$GUARD_STATUS" != 0 ] && [ "$STATUS" = 0 ]; then STATUS="$GUARD_STATUS"; fi
exit "$STATUS"
