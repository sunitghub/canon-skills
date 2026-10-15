#!/usr/bin/env bash
# test-sh-runner (t-2633) — scripts/test.sh's own behaviour: `--list` (the one list of suites; scripts/test-hermetic.sh reads it), and
# the timing table every run prints. The table runs on a copy of the real runner whose suite list is replaced by fakes, with go and
# node kept off PATH. Nothing touches the real tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

t="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${t%/}/test-sh-runner.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export SPRINT_CHECK_NO_BROWSER=1   # tests/no-browser-in-tests.sh reads any sprint-check-go mention as a board start; none starts here
export LC_ALL=C TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

# --- --list ---------------------------------------------------------------------------------------------------------------------
LIST="$(bash "$ROOT/scripts/test.sh" --list)"
assert_eq "" "$(printf '%s\n' "$LIST" | sort | uniq -d)"                        # no suite listed twice
while IFS= read -r l; do [[ -e "$ROOT/$l" ]] || fail "test.sh --list names $l, which does not exist"; done <<< "$LIST"
# the dry pass reaches every invocation in the file: the .sh labels are the tests=( array, the .js labels every node line, plus the Go three
assert_eq "$(awk '/^tests=\(/{f=1;next} /^\)/{f=0} f' "$ROOT/scripts/test.sh" | grep -c 'tests/')" "$(printf '%s\n' "$LIST" | grep -c '\.sh$')"
assert_eq "$(grep -c '^  suite tests/[^ ]*\.js node "\$ROOT/tests/' "$ROOT/scripts/test.sh")" "$(printf '%s\n' "$LIST" | grep -c '\.js$')"
for g in tools/sprint-check-go tools/sprint-headless-json-go tools/cockpit-daemon; do assert_contains "$LIST" "$g"; done
assert_contains "$LIST" "tests/test-sh-runner.sh"
set +e; out="$(bash "$ROOT/scripts/test.sh" --help 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "usage: scripts/test.sh [--list]"
set +e; out="$(bash "$ROOT/scripts/test.sh" --bogus 2>&1)"; rc=$?; set -e; assert_eq 2 "$rc"; assert_contains "$out" "test.sh: unknown option --bogus"

# every SERIAL label is a --list label (a typo would quietly run that suite in the batch)
serial="$(awk '/^SERIAL=\(/{f=1; next} f && /^\)/{exit} f && !/^ *#/{print $1}' "$ROOT/scripts/test.sh")"
[[ -n "$serial" ]] || fail "test.sh: SERIAL lists no suite"
while IFS= read -r l; do grep -qxF "$l" <<< "$LIST" || fail "test.sh: SERIAL names $l, which --list does not"; done <<< "$serial"

# --- copies of the real runner with fake suites; go and node kept off PATH -----------------------------------------------------------
mkdir -p "$WORK/bin"
for b in bash sh git sort head tail mktemp grep sed awk cat rm sleep dirname cut wc tr comm ps pgrep uniq basename env ls xargs date mv mkdir touch nproc sysctl pkill kill; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$WORK/bin/$b"
done
runner_copy() {   # runner_copy <dir> <suite...>: the real test.sh with its tests=( list replaced by the given suites
  local d="$1"; shift
  mkdir -p "$d/scripts" "$d/tests"
  { awk '/^tests=\(/{exit} {print}' "$ROOT/scripts/test.sh"; echo 'tests=('; for t in "$@"; do echo "  \"\$ROOT/$t\""; done; echo ')'
    awk 'f; /^tests=\(/{s=1} s && /^\)/{f=1}' "$ROOT/scripts/test.sh"; } > "$d/scripts/test.sh"
}

# A failing run: twelve timed suites, the slowest first, the failing one timed and marked, the run's own exit code kept.
T="$WORK/runner"; names=(tests/slow.sh); for k in 01 02 03 04 05 06 07 08 09 10; do names+=("tests/t$k.sh"); done; names+=(tests/bad.sh)
runner_copy "$T" "${names[@]}"
printf 'sleep 2\necho slow-ok\n' > "$T/tests/slow.sh"; printf 'sleep 1\necho bad-runs; exit 3\n' > "$T/tests/bad.sh"
for k in 01 02 03 04 05 06 07 08 09 10; do echo 'true' > "$T/tests/t$k.sh"; done
set +e; out="$(PATH="$WORK/bin" bash "$T/scripts/test.sh" 2>&1)"; rc=$?; set -e
assert_eq 3 "$rc"                                                                  # the failing suite's own code
assert_contains "$out" "==> tests/slow.sh"; assert_contains "$out" "slow-ok"; assert_contains "$out" "==> tests/bad.sh"
assert_contains "$out" "== suite times (s), in run order"; assert_contains "$out" "== total "; assert_contains "$out" "for 12 suite(s)"
slowest="$(printf '%s\n' "$out" | sed -n '/^== slowest 10 (s)$/,/^== total/p' | sed '1d;$d')"
assert_eq 10 "$(printf '%s\n' "$slowest" | wc -l | tr -d ' ')"
[[ "$(printf '%s\n' "$slowest" | head -1)" =~ ^[2-9]\ tests/slow\.sh$ ]] || fail "test.sh: slowest 10 must start with the slow suite: $slowest"
[[ "$out" =~ (^|$'\n')[1-9][0-9]*\ tests/bad\.sh\ \(failed\) ]] || fail "test.sh: the failing suite's time is missing or zero: $out"

# A passing run: exit 0, each go/node skip line printed once (never from the dry pass), and --list unchanged by go/node being absent.
P="$WORK/pass"; runner_copy "$P" tests/a.sh tests/b.sh
echo 'echo a-ran' > "$P/tests/a.sh"; echo 'echo b-ran' > "$P/tests/b.sh"
set +e; out="$(PATH="$WORK/bin" bash "$P/scripts/test.sh" 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "a-ran"; assert_contains "$out" "b-ran"; assert_contains "$out" "All tests passed."
for skipped_line in "==> tools/sprint-check-go skipped (go absent)" "==> tools/sprint-headless-json-go skipped (go absent)" \
  "==> tools/cockpit-daemon skipped (go absent)" "==> tests/sprint-check-gherkin.js skipped (node absent)"; do
  assert_eq 1 "$(printf '%s\n' "$out" | grep -cxF "$skipped_line")"
done
set +e; out="$(PATH="$WORK/bin" bash "$P/scripts/test.sh" --list 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_eq 17 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"; [[ "$out" != *"==>"* ]] || fail "--list printed a run line: $out"

# --- t-abb1: the parallel run -----------------------------------------------------------------------------------------------------
X="$WORK/par"; runner_copy "$X" tests/a.sh tests/b.sh tests/c.sh tests/d.sh tests/e.sh tests/f.sh
printf 'sleep 2; echo A-out\n' > "$X/tests/a.sh"                          # slow, and first
printf 'echo B-out; exit 4\n' > "$X/tests/b.sh"                           # the first failure
printf 'echo C-out\n' > "$X/tests/c.sh"                                    # must still run
printf 'echo D-out; exit 5\n' > "$X/tests/d.sh"                           # a second failure
printf 'echo e > "$TMPDIR/shared"; sleep 1; [ "$(cat "$TMPDIR/shared")" = e ] && echo E-ok\n' > "$X/tests/e.sh"   # a fixed temp name ...
printf 'echo f > "$TMPDIR/shared"; sleep 1; [ "$(cat "$TMPDIR/shared")" = f ] && echo F-ok\n' > "$X/tests/f.sh"   # ... in two suites
set +e; out="$(PATH="$WORK/bin" bash "$X/scripts/test.sh" --jobs 4 2>&1)"; rc=$?; set -e
assert_eq 4 "$rc"                                                                  # the first failing suite's code, in list order
for t in a b c d e f; do assert_eq 1 "$(printf '%s\n' "$out" | grep -cx "==> tests/$t.sh")"; done   # every suite exactly once
heads="$(printf '%s\n' "$out" | grep '^==> tests/[a-f]\.sh$' | tr '\n' ' ')"
assert_eq "==> tests/a.sh ==> tests/b.sh ==> tests/c.sh ==> tests/d.sh ==> tests/e.sh ==> tests/f.sh " "$heads"   # list order, slow a.sh first
assert_contains "$out" "==> tests/a.sh"$'\n'"A-out"$'\n'"==> tests/b.sh"$'\n'"B-out"   # each suite's output under its own header
assert_contains "$out" "C-out"; assert_contains "$out" "E-ok"; assert_contains "$out" "F-ok"
assert_contains "$out" "FAILED: tests/b.sh (exit 4)"$'\n'"FAILED: tests/d.sh (exit 5)"
assert_contains "$out" "0 tests/b.sh (failed)"; [[ "$out" != *"tests/c.sh (failed)"* ]] || fail "a passing suite was marked failed"
assert_eq "" "$(ls "$TMPDIR" | grep '^test-sh-run\.' || true)"                    # the run folder is removed
# a TMPDIR ending in "/" (macOS's own) gives no suite a "//" path; t.TempDir() keeps it, filepath.Join drops it (cockpit-daemon failed)
T2="$WORK/slash"; runner_copy "$T2" tests/a.sh tests/b.sh; echo 'echo "dir=$TMPDIR"' > "$T2/tests/a.sh"; echo true > "$T2/tests/b.sh"
set +e; out="$(TMPDIR="$TMPDIR/" PATH="$WORK/bin" bash "$T2/scripts/test.sh" --jobs 2 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "dir=$TMPDIR/test-sh-run."; [[ "$out" != *"//"* ]] || fail "a suite's TMPDIR has a //: $out"
# --jobs 1: the sequential run stops at the first failure
set +e; out="$(PATH="$WORK/bin" bash "$X/scripts/test.sh" --jobs 1 2>&1)"; rc=$?; set -e
assert_eq 4 "$rc"; assert_contains "$out" "B-out"; [[ "$out" != *"C-out"* ]] || fail "--jobs 1 ran past the first failure"
for bad in "--jobs 0" "--jobs x" "--jobs" "--jobs -1" "--jobs 5x"; do
  set +e; out="$(PATH="$WORK/bin" bash "$X/scripts/test.sh" $bad 2>&1)"; rc=$?; set -e
  assert_eq 2 "$rc"; assert_contains "$out" "test.sh: --jobs needs a positive number"
done
# SERIAL: a listed suite runs alone after the batch; the others mark themselves running while they run
Z="$WORK/ser"; runner_copy "$Z" tests/p1.sh tests/s.sh tests/p2.sh tests/p3.sh
awk '/^SERIAL=\(/{print "SERIAL=(tests/s.sh)"; f=1} f{if (/^\)/) f=0; next} {print}' "$Z/scripts/test.sh" > "$Z/t" && mv "$Z/t" "$Z/scripts/test.sh"
grep -q '^SERIAL=(tests/s.sh)' "$Z/scripts/test.sh" || fail "could not set SERIAL in the runner copy"
mkdir -p "$WORK/running"
for t in p1 p2 p3; do printf 'touch "%s/running/%s"; sleep 1; rm "%s/running/%s"; echo %s-ok\n' "$WORK" "$t" "$WORK" "$t" "$t" > "$Z/tests/$t.sh"; done
printf 'if [ -n "$(ls "%s/running")" ]; then echo "S-overlapped: $(ls "%s/running")"; exit 7; fi; echo S-alone\n' "$WORK" "$WORK" > "$Z/tests/s.sh"
set +e; out="$(PATH="$WORK/bin" bash "$Z/scripts/test.sh" --jobs 4 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "S-alone"; assert_contains "$out" "p1-ok"; assert_contains "$out" "p3-ok"
assert_contains "$out" "==> tests/sprint-check-gherkin.js skipped (node absent)"$'\n'"==> tests/s.sh"$'\n'"S-alone"   # a SERIAL suite prints after the batch

# the default worker count: the CPU count (nproc), at most 8; a count that is not a number runs one at a time. Each suite records how
# many suites it saw running at once (it stays ~2 s, so every suite started together is seen).
C="$WORK/cpus"; cs=(); for k in 01 02 03 04 05 06 07 08 09 10; do cs+=("tests/c$k.sh"); done; runner_copy "$C" "${cs[@]}"; mkdir -p "$WORK/live"
for k in 01 02 03 04 05 06 07 08 09 10; do
  printf 'touch "%s/live/%s"; m=0; for _ in 1 2 3 4 5 6 7 8 9 10; do n=$(ls "%s/live" | wc -l); [ "$n" -gt "$m" ] && m=$n; sleep 0.2; done; rm "%s/live/%s"; echo "seen=$m"\n' \
    "$WORK" "$k" "$WORK" "$WORK" "$k" > "$C/tests/c$k.sh"
done
for want in "3 3" "20 8"; do
  mkdir -p "$WORK/cpu-${want%% *}"; printf '#!/bin/sh\necho %s\n' "${want%% *}" > "$WORK/cpu-${want%% *}/nproc"; chmod +x "$WORK/cpu-${want%% *}/nproc"
  set +e; out="$(PATH="$WORK/cpu-${want%% *}:$WORK/bin" bash "$C/scripts/test.sh" 2>&1)"; rc=$?; set -e
  assert_eq 0 "$rc"; assert_eq "${want#* }" "$(printf '%s\n' "$out" | sed -n 's/^seen= *//p' | sort -n | tail -1)"
done
for v in abc x4 4x; do   # not a whole number: one at a time, so the run stops at the first failure
  mkdir -p "$WORK/cpu-$v"; printf '#!/bin/sh\necho %s\n' "$v" > "$WORK/cpu-$v/nproc"; chmod +x "$WORK/cpu-$v/nproc"
  set +e; out="$(PATH="$WORK/cpu-$v:$WORK/bin" bash "$X/scripts/test.sh" 2>&1)"; rc=$?; set -e
  assert_eq 4 "$rc"; [[ "$out" != *"C-out"* ]] || fail "nproc $v: the run was not one at a time"
done
# skip lines ahead of other suites (go absent, node present): every later suite still runs
N="$WORK/node"; runner_copy "$N" tests/a.sh; echo 'echo a-ran' > "$N/tests/a.sh"
mkdir -p "$WORK/nodebin"; printf '#!/bin/sh\necho "node-ran $(basename "$1")"\n' > "$WORK/nodebin/node"; chmod +x "$WORK/nodebin/node"
set +e; out="$(PATH="$WORK/nodebin:$WORK/bin" bash "$N/scripts/test.sh" --jobs 4 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "==> tools/cockpit-daemon skipped (go absent)"$'\n'"==> tests/sprint-check-gherkin.js"$'\n'"node-ran sprint-check-gherkin.js"
assert_contains "$out" "node-ran sprint-check-api-scoping.js"
# an interrupted run stops every process its suites started (not only xargs's own workers) and removes its folder
I="$WORK/int"; runner_copy "$I" tests/a.sh tests/b.sh; mkdir -p "$WORK/int-tmp"
printf 'sleep 60 & echo $! > "%s/int-child"; echo $$ > "%s/int-suite"; wait\n' "$WORK" "$WORK" > "$I/tests/a.sh"; echo 'true' > "$I/tests/b.sh"
TMPDIR="$WORK/int-tmp" PATH="$WORK/bin" bash "$I/scripts/test.sh" --jobs 2 > "$WORK/int-out" 2>&1 & ipid=$!
for _ in $(seq 100); do [[ -s "$WORK/int-suite" ]] && break; sleep 0.1; done
[[ -s "$WORK/int-suite" ]] || fail "the interrupted run's suite never started: $(cat "$WORK/int-out")"
kill -TERM "$ipid"; wait "$ipid" 2>/dev/null || true; sleep 1
left=""
for f in int-suite int-child; do
  if kill -0 "$(cat "$WORK/$f")" 2>/dev/null; then kill "$(cat "$WORK/$f")" 2>/dev/null || true; left+=" $f"; fi
done
[[ -z "$left" ]] || fail "an interrupted run left suite processes running:$left"
assert_eq "" "$(ls "$WORK/int-tmp")"                                              # the run folder is removed

# --- the two timing-table gaps t-2633's last evaluator found -----------------------------------------------------------------------
# a passing sequential run marks nothing failed (CURRENT is cleared after each suite)
set +e; out="$(PATH="$WORK/bin" bash "$P/scripts/test.sh" --jobs 1 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; [[ "$out" != *"(failed)"* ]] || fail "a passing --jobs 1 run printed a failed row: $out"
assert_eq 1 "$(printf '%s\n' "$out" | grep -cxF "==> tools/cockpit-daemon skipped (go absent)")"   # the sequential run prints skips too
# the slowest 10 are sorted, even when the slow suite runs last
L="$WORK/late"; runner_copy "$L" tests/q1.sh tests/q2.sh tests/q3.sh
echo 'true' > "$L/tests/q1.sh"; echo 'sleep 1' > "$L/tests/q2.sh"; echo 'sleep 2' > "$L/tests/q3.sh"
for j in 1 4; do
  set +e; out="$(PATH="$WORK/bin" bash "$L/scripts/test.sh" --jobs "$j" 2>&1)"; rc=$?; set -e
  assert_eq 0 "$rc"
  assert_eq "tests/q3.sh tests/q2.sh tests/q1.sh" "$(printf '%s\n' "$out" | sed -n '/^== slowest 10 (s)$/,/^== total/p' | sed '1d;$d' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
done

echo "test-sh-runner: ok"
