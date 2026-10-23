#!/usr/bin/env bash
# run-board-spec-isolation (t-2992) — tests/run-board-spec.sh keeps a spec board away from the real Cockpit daemon and never lets a
# leak look clean: the board's COCKPIT_STATE_DIR is inside its copy and its COCKPIT_DAEMON_BIN names no file, and a process left
# from the copy exits 2 even when the guard fails too. rsync, go, curl and npx are stubs on PATH (no browsers, no board).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
t="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${t%/}/rbsi-test.XXXXXX")"; WORK="$(cd "$WORK" && pwd -P)"
kill_leaks() {   # only the PIDs the npx stub recorded for the processes it leaked on purpose
  if [ -s "$WORK/leakpids" ]; then while read -r p; do kill "$p" 2>/dev/null || true; done < "$WORK/leakpids"; fi
  : > "$WORK/leakpids"
}
trap 'kill_leaks; rm -rf "$WORK"' EXIT

# a fake canon tree holding only the runner, so the copy is tiny and the real tree is never touched
FAKE="$WORK/root"; mkdir -p "$FAKE/tests" "$FAKE/tools/canon-go" "$FAKE/node_modules" "$WORK/bin" "$WORK/state"   # t-8020: the runner starts the board from tools/canon-go
cp "$ROOT/tests/run-board-spec.sh" "$ROOT/tests/machine-load.sh" "$FAKE/tests/"
echo 'console.log("board-spec-guard: 1 violation(s)"); process.exit(1)' > "$FAKE/tests/board-spec-guard.js"   # a guard that always fails
git -C "$FAKE" init -q
printf '#!/bin/sh\nfor a; do last="$prev"; prev="$a"; done\ncp -a "$last." "$prev" 2>/dev/null || cp -a "$last" "$prev"\n' > "$WORK/bin/rsync"   # rsync -a --exclude.. SRC/ DST/
printf '#!/bin/sh\necho "$SPRINT_CHECK_ROOT $COCKPIT_STATE_DIR $COCKPIT_DAEMON_BIN" >> "$STATE/boards"\nexec sleep 600\n' > "$WORK/bin/go"   # records the board's env (its root is the copy)
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/curl"
cat > "$WORK/bin/npx" <<'STUB'
#!/bin/bash
# npx playwright test ...: optionally leave a process behind in the copy, then write a report
[ -n "${LEAK:-}" ] && { bash -c 'sleep 20; :' "spec-isolation-leakmark" "$PWD" >/dev/null 2>&1 & echo "$!" >> "$STATE/../leakpids"; }
echo '{"suites":[]}' > "$PLAYWRIGHT_JSON_OUTPUT_NAME"
exit 0
STUB
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/pgrep"   # t-8627: no other run (the suite running this test must not make the machine "busy")
echo "0.1 0.1 0.1 1/100 999" > "$WORK/loadavg"
chmod +x "$WORK/bin/"*

run() {   # run <name> <args...> [env via RUN_ENV]: sets out (stdout+stderr) and rc
  local name="$1"; shift
  rm -rf "$WORK/state"/*; mkdir -p "$WORK/out-$name"
  set +e
  out="$(env STATE="$WORK/state" TMPDIR="$WORK" ML_LOADAVG_FILE="$WORK/loadavg" ML_WAIT_POLL=1 PATH="$WORK/bin:$PATH" ${RUN_ENV:-} bash "$FAKE/tests/run-board-spec.sh" --out "$WORK/out-$name" "$@" 2>&1)"; rc=$?
  set -e
}

RUN_ENV=""; run clean --runs 1 --browsers chromium --no-guard
assert_eq 0 "$rc"; assert_contains "$out" "no process left running from the copy"
read -r d sd bin < "$WORK/state/boards"
assert_eq "$d/.spec-cockpit-state" "$sd"   # never the real daemon's $TMPDIR/canon-cockpit-board
assert_eq "$d/.spec-no-daemon" "$bin"; [ ! -e "$bin" ] || fail "run-board-spec: the spec board's daemon bin exists: $bin"

# a leak exits 2 with the guard skipped, and still 2 when the guard fails (exit 1) too
RUN_ENV="LEAK=1"; run leak --runs 1 --browsers chromium --no-guard
assert_eq 2 "$rc"; assert_contains "$out" "processes from the copy are still running"
kill_leaks
run leakguard --runs 1 --browsers chromium
assert_contains "$out" "board-spec-guard:"; assert_eq 2 "$rc"
kill_leaks
# t-8627: a busy machine is waited out and then refused (exit 2, nothing started, no copy left behind); --allow-busy runs anyway
echo "99.0 99.0 99.0 1/100 999" > "$WORK/loadavg"
RUN_ENV="ML_WAIT_MAX=0"; run busy --runs 1 --browsers chromium --no-guard
assert_eq 2 "$rc"; assert_contains "$out" "still busy after 0s"; assert_contains "$out" "the machine stayed busy"
[ ! -e "$WORK/state/boards" ] || fail "run-board-spec: a board was started on a busy machine"
[ -z "$(ls -d "$WORK"/board-spec-copy.* 2>/dev/null)" ] || fail "run-board-spec: a refused run left its copy behind"
run allowed --runs 1 --browsers chromium --no-guard --allow-busy
assert_eq 0 "$rc"; assert_contains "$out" "WARNING: the machine is busy"   # still told, not blocked
echo "run-board-spec-isolation: ok"
