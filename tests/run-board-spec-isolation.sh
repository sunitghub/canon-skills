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
echo "$*" >> "$STATE/npx-args"
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
# t-43a2: without --runs a browser runs once and is repeated (to 3) only when the guard rejects its first report; --runs N is exactly N.
nreports() { ls "$WORK/out-$1"/board-spec-"$2"-run*.json 2>/dev/null | wc -l | tr -d ' '; }
echo "0.1 0.1 0.1 1/100 999" > "$WORK/loadavg"; RUN_ENV=""
echo 'process.exit(0)' > "$FAKE/tests/board-spec-guard.js"   # a guard that passes
run adaptive-clean --browsers chromium,webkit
assert_eq 0 "$rc"; assert_eq 1 "$(nreports adaptive-clean chromium)"; assert_eq 1 "$(nreports adaptive-clean webkit)"
assert_contains "$out" "chromium: run 1 clean, no repeat needed"
echo 'process.exit(process.argv.slice(2).some(a => /board-spec-webkit-run/.test(a)) ? 1 : 0)' > "$FAKE/tests/board-spec-guard.js"   # rejects only webkit's report
run adaptive-webkit --browsers chromium,webkit
assert_eq 1 "$rc"   # the final guard (webkit rejected) still fails the run
assert_eq 1 "$(nreports adaptive-webkit chromium)"; assert_eq 3 "$(nreports adaptive-webkit webkit)"   # only the rejected browser is repeated
assert_contains "$out" "webkit: run 1 was rejected by the guard"; assert_contains "$out" "chromium: run 1 clean, no repeat needed"
run explicit --runs 2 --browsers chromium,webkit
assert_eq 1 "$rc"
assert_eq 2 "$(nreports explicit chromium)"; assert_eq 2 "$(nreports explicit webkit)"   # an explicit --runs is exactly that many, whatever the guard says
run noguard --browsers chromium --no-guard
assert_eq 1 "$(nreports noguard chromium)"; assert_contains "$out" "the guard is skipped"
# a reused --out must not leave an earlier run's reports for the guard and the stamp to judge
echo 'process.exit(0)' > "$FAKE/tests/board-spec-guard.js"
mkdir -p "$WORK/out-reuse"; echo '{"suites":[]}' > "$WORK/out-reuse/board-spec-chromium-run2.json"; echo '{"suites":[]}' > "$WORK/out-reuse/board-spec-chromium-run3.json"
run reuse --browsers chromium
assert_eq 0 "$rc"; assert_eq 1 "$(nreports reuse chromium)"; [ ! -e "$WORK/out-reuse/board-spec-chromium-run3.json" ] || fail "run-board-spec: a stale run3 report survived a reused --out"
# t-23f6: Chromium runs every test; WebKit gets --grep @webkit, and a user --grep must match as well (a lookahead pair, not a replacement)
echo 'process.exit(0)' > "$FAKE/tests/board-spec-guard.js"
run tags --runs 1 --browsers chromium,webkit --no-guard
assert_eq 1 "$(grep -c -- '--browser=chromium' "$WORK/state/npx-args")"; grep -- '--browser=chromium' "$WORK/state/npx-args" | grep -q -- '--grep' && fail "run-board-spec: chromium was given a --grep"
grep -- '--browser=webkit' "$WORK/state/npx-args" | grep -q -- '--grep @webkit$' || fail "run-board-spec: webkit did not get --grep @webkit: $(cat "$WORK/state/npx-args")"
run tags-user --runs 1 --browsers chromium,webkit --no-guard --grep 'popover|menu'
grep -- '--browser=chromium' "$WORK/state/npx-args" | grep -q -- '--grep popover|menu$' || fail "run-board-spec: chromium lost the user --grep: $(cat "$WORK/state/npx-args")"
grep -- '--browser=webkit' "$WORK/state/npx-args" | grep -qF -- '--grep ^(?=.*@webkit)(?=.*(?:popover|menu))' || fail "run-board-spec: webkit --grep is not @webkit AND the user pattern: $(cat "$WORK/state/npx-args")"
echo "run-board-spec-isolation: ok"
