#!/usr/bin/env bash
# run-board-spec-parallel (t-2992) — tests/run-board-spec.sh --parallel N: the passes run at once, each slot in its own copy, with the
# same report names, sha256 lines and exit codes as serial; a process left in any copy, or a pass with no report, exits 2.
# rsync, go, curl and npx are stubs on PATH (no browsers, no board); the guard is skipped (--no-guard; it has its own unit test).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
t="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${t%/}/rbsp-test.XXXXXX")"; WORK="$(cd "$WORK" && pwd -P)"
kill_leaks() {   # only the PIDs the npx stub recorded for the processes it leaked on purpose
  if [ -s "$WORK/leakpids" ]; then while read -r p; do kill "$p" 2>/dev/null || true; done < "$WORK/leakpids"; fi
  : > "$WORK/leakpids"
}
trap 'kill_leaks; rm -rf "$WORK"' EXIT

# a fake canon tree holding only the runner, so the copy is tiny and the real tree is never touched
FAKE="$WORK/root"; mkdir -p "$FAKE/tests" "$FAKE/node_modules" "$WORK/bin" "$WORK/state"
cp "$ROOT/tests/run-board-spec.sh" "$ROOT/tests/machine-load.sh" "$FAKE/tests/"
echo 'console.log("board-spec-guard: 1 violation(s)"); process.exit(1)' > "$FAKE/tests/board-spec-guard.js"   # a guard that always fails
git -C "$FAKE" init -q
printf '#!/bin/sh\nfor a; do last="$prev"; prev="$a"; done\ncp -a "$last." "$prev" 2>/dev/null || cp -a "$last" "$prev"\n' > "$WORK/bin/rsync"   # rsync -a --exclude.. SRC/ DST/
printf '#!/bin/sh\necho "$PWD $COCKPIT_STATE_DIR $COCKPIT_DAEMON_BIN" >> "$STATE/boards"\nexec sleep 600\n' > "$WORK/bin/go"   # records each board's cockpit state dir and daemon bin
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/curl"
cat > "$WORK/bin/npx" <<'STUB'
#!/bin/bash
# npx playwright test ... --browser=B: record the copy it ran in, optionally wait for the other passes, then write a report
b=""; for a in "$@"; do case "$a" in --browser=*) b="${a#--browser=}" ;; esac; done
echo "$b $PWD" >> "$STATE/calls"
touch "$STATE/start.$b.$$"
if [ -n "${RENDEZVOUS:-}" ]; then   # all passes must be running at once, or this gives up and the test sees no overlap
  for _ in $(seq 1 100); do [ "$(ls "$STATE" | grep -c '^start\.')" -ge "$RENDEZVOUS" ] && break; sleep 0.1; done
  [ "$(ls "$STATE" | grep -c '^start\.')" -ge "$RENDEZVOUS" ] || { echo "no overlap" >> "$STATE/errors"; }
fi
[ "${LEAK_BROWSER:-}" = "$b" ] && { bash -c 'sleep 20; :' "spec-parallel-leakmark $STATE" "$PWD" >/dev/null 2>&1 & echo "$!" >> "$STATE/../leakpids"; }
[ "${NOREPORT_BROWSER:-}" = "$b" ] || echo '{"suites":[]}' > "$PLAYWRIGHT_JSON_OUTPUT_NAME"
exit 0
STUB
chmod +x "$WORK/bin/"*

run() {   # run <name> <args...> [env via RUN_ENV]: sets out (stdout+stderr), rc, and OUT dir $WORK/out-<name>
  local name="$1"; shift
  rm -rf "$WORK/state"/*; mkdir -p "$WORK/out-$name"
  set +e
  out="$(env STATE="$WORK/state" TMPDIR="$WORK" PATH="$WORK/bin:$PATH" ${RUN_ENV:-} bash "$FAKE/tests/run-board-spec.sh" ${RUN_GUARD---no-guard} --out "$WORK/out-$name" "$@" 2>&1)"; rc=$?
  set -e
}
names() { (cd "$WORK/out-$1" && ls board-spec-*.json | tr '\n' ' '); }
shas() { grep -o 'report board-spec-.* sha256' <<<"$out" | tr '\n' ' '; }

RUN_ENV=""; run serial --runs 2 --browsers chromium,webkit
assert_eq 0 "$rc"; assert_eq "board-spec-chromium-run1.json board-spec-chromium-run2.json board-spec-webkit-run1.json board-spec-webkit-run2.json " "$(names serial)"
assert_eq 1 "$(sort -u "$WORK/state/calls" | cut -d' ' -f2 | sort -u | wc -l | tr -d ' ')"   # serial: every pass in the one copy
assert_contains "$out" "canon's own tree is unchanged"
[[ "$out" != *"--parallel"* ]] || fail "run-board-spec: serial output mentions --parallel"
SERIAL_SHAS="$(shas)"

RUN_ENV="RENDEZVOUS=2"; run par2 --runs 2 --browsers chromium,webkit --parallel 2
assert_eq 0 "$rc"; assert_eq "$(names serial)" "$(names par2)"   # same report names
assert_eq "$SERIAL_SHAS" "$(shas)"                                # same sha256 line shape and order
assert_eq 4 "$(wc -l < "$WORK/state/calls" | tr -d ' ')"
assert_eq 2 "$(cut -d' ' -f2 "$WORK/state/calls" | sort -u | wc -l | tr -d ' ')"   # two slots, two copies
while read -r d sd bin; do   # each board's cockpit state dir is its own copy's, never the real daemon's $TMPDIR/canon-cockpit-board,
  assert_eq "$d/.spec-cockpit-state" "$sd"   # and its daemon bin names no file, so it never launches a daemon that outlives it
  assert_eq "$d/.spec-no-daemon" "$bin"; [ ! -e "$bin" ] || fail "run-board-spec: the spec board's daemon bin exists: $bin"
done < "$WORK/state/boards"
assert_eq 2 "$(wc -l < "$WORK/state/boards" | tr -d ' ')"
[ ! -s "$WORK/state/errors" ] || fail "run-board-spec: --parallel 2 did not run the passes at once"
assert_contains "$out" "4 pass(es) over 2 slot(s)"; assert_contains "$out" "no process left running from the copy"
assert_contains "$out" "report dir $WORK/out-par2"
assert_eq "" "$(ls -d "$WORK"/board-spec-copy.* 2>/dev/null || true)"   # every copy removed

RUN_ENV="RENDEZVOUS=3"; run par9 --runs 1 --browsers chromium,webkit --parallel 9   # more slots than passes: capped at the passes
assert_eq 0 "$rc"; assert_contains "$out" "2 pass(es) over 2 slot(s)"

# a process left in any copy exits 2 (here only the second slot's pass leaks), serial or parallel
RUN_ENV="LEAK_BROWSER=webkit"; run leakpar --runs 1 --browsers chromium,webkit --parallel 2
assert_eq 2 "$rc"; assert_contains "$out" "processes from the copy are still running"
kill_leaks
run leakser --runs 1 --browsers chromium,webkit
assert_eq 2 "$rc"; assert_contains "$out" "processes from the copy are still running"
kill_leaks

# a leak still exits 2 when the guard fails too (exit 1)
RUN_ENV="LEAK_BROWSER=webkit" RUN_GUARD=""; run leakguard --runs 1 --browsers chromium,webkit --parallel 2
unset RUN_GUARD
assert_contains "$out" "board-spec-guard:"; assert_eq 2 "$rc"
kill_leaks

# a pass with no report exits 2 in a slot too
RUN_ENV="NOREPORT_BROWSER=webkit"; run noreport --runs 1 --browsers chromium,webkit --parallel 2
assert_eq 2 "$rc"; assert_contains "$out" "no JSON report for webkit run 1"

RUN_ENV=""; run bad --parallel 0; assert_eq 2 "$rc"; assert_contains "$out" "--parallel needs a positive number"
run badc --parallel 2 --classify; assert_eq 2 "$rc"; assert_contains "$out" "--parallel cannot be combined with --classify"
echo "run-board-spec-parallel: ok"
