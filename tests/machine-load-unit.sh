#!/usr/bin/env bash
# machine-load-unit (t-5989) — tests/machine-load.sh's machine_load: the line it records, the WARNING on a busy machine (load over the
# CPU count, or another test run going), that a process below the caller is not "another run", and that it never fails the caller.
# pgrep, ps and nproc are stubs on PATH; the load average comes from a fixture file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
t="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${t%/}/machine-load-unit.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho 4\n' > "$WORK/bin/nproc"
# pgrep answers only the real pattern, so a changed pattern finds nothing
printf '#!/bin/sh\n[ "$1 $2" = "-f scripts/test\\.sh|tests/run-board-spec\\.sh" ] && cat "%s/pgrep.out"\nexit 0\n' "$WORK" > "$WORK/bin/pgrep"
printf '#!/bin/sh\n# ps -o ppid= -p PID: look PID up in the parent map\nawk -v p="$4" '"'"'$1 == p {print $2}'"'"' "%s/ppid.map"\n' "$WORK" > "$WORK/bin/ps"
printf '#!/bin/sh\ncase "$2" in vm.loadavg) echo "{ 7.25 2.00 1.00 }" ;; hw.ncpu) echo 6 ;; esac\n' > "$WORK/bin/sysctl"   # the macOS path
chmod +x "$WORK/bin/"*
export ML_LOADAVG_FILE="$WORK/loadavg"
run() {   # run <load> <pgrep pids...>: machine_load as the runner calls it (own pid 100); sets out and rc
  echo "$1 1.0 1.0 1/100 999" > "$WORK/loadavg"; shift
  printf '%s\n' "$@" > "$WORK/pgrep.out"
  set +e
  out="$(PATH="$WORK/bin:$PATH" bash -c 'source "$1/tests/machine-load.sh"; machine_load start "$2" 100' _ "$ROOT" "$WORK/record.txt" 2>&1)"; rc=$?
  set -e
}
printf '200 100\n300 200\n4242 1\n1 0\n' > "$WORK/ppid.map"   # 200 is the runner's child, 300 its grandchild; 4242 is someone else's run

run 1.0
assert_eq 0 "$rc"; assert_eq "machine-load: start: load 1.0 on 4 CPUs; other test runs: none" "$out"
assert_eq "$out" "$(cat "$WORK/record.txt")"
run 1.0 200 300
assert_eq "machine-load: start: load 1.0 on 4 CPUs; other test runs: none" "$out"   # its own descendants are not another run
run 9.5
assert_eq 0 "$rc"; assert_contains "$out" "load 9.5 on 4 CPUs"; assert_contains "$out" "machine-load: WARNING: the machine is busy (load 9.5/4)"
run 4.0
[[ "$out" != *WARNING* ]] || fail "machine-load: a load equal to the CPU count is not busy: $out"
run 1.0 200 4242
assert_eq 0 "$rc"; assert_contains "$out" "other test runs: 4242"; assert_contains "$out" "WARNING: the machine is busy (other runs: 4242; load 1.0/4)"
assert_eq 5 "$(grep -c '^machine-load: start:' "$WORK/record.txt")"   # every call appends its line to the record
assert_eq 2 "$(grep -c '^machine-load: WARNING:' "$WORK/record.txt")"   # and the warnings with it
# macOS: no load file, no working nproc: the load comes from sysctl vm.loadavg and the CPU count from hw.ncpu
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/nproc"; printf '\n' > "$WORK/pgrep.out"   # an nproc that fails, as when it is missing
set +e
out="$(ML_LOADAVG_FILE="$WORK/none" PATH="$WORK/bin:/usr/bin:/bin" bash -c 'source "$1/tests/machine-load.sh"; machine_load start /dev/null 100' _ "$ROOT" 2>&1)"
set -e
assert_contains "$out" "machine-load: start: load 7.25 on 6 CPUs; other test runs: none"; assert_contains "$out" "WARNING: the machine is busy (load 7.25/6)"

# neither nproc nor sysctl answers: the CPU count falls back to 1, never an empty number
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/sysctl"; echo "0.5 1 1 1/1 1" > "$WORK/loadavg"
out="$(ML_LOADAVG_FILE="$WORK/loadavg" PATH="$WORK/bin:/usr/bin:/bin" bash -c 'source "$1/tests/machine-load.sh"; machine_load start /dev/null 100' _ "$ROOT" 2>&1)"
assert_eq "machine-load: start: load 0.5 on 1 CPUs; other test runs: none" "$out"

# t-8627: machine_wait_quiet: a run does not start on a busy machine. sleep is a stub that counts, and can calm the load after N waits.
printf '#!/bin/sh\necho 4\n' > "$WORK/bin/nproc"; : > "$WORK/pgrep.out"
printf '#!/bin/sh\nn=$(cat "%s/slept" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "%s/slept"\n[ "$n" -ge "$(cat "%s/calm-after")" ] && echo "1.0 1 1 1/1 1" > "%s/loadavg"\nexit 0\n' "$WORK" "$WORK" "$WORK" "$WORK" > "$WORK/bin/sleep"
chmod +x "$WORK/bin/sleep"
wait_quiet() {   # wait_quiet <load> <calm-after sleeps> <max secs>: sets out and rc
  echo "$1 1 1 1/1 1" > "$WORK/loadavg"; echo "$2" > "$WORK/calm-after"; rm -f "$WORK/slept" "$WORK/wait.txt"
  set +e
  out="$(ML_WAIT_POLL=15 ML_WAIT_MAX="$3" PATH="$WORK/bin:$PATH" bash -c 'source "$1/tests/machine-load.sh"; machine_wait_quiet "$2" 100' _ "$ROOT" "$WORK/wait.txt" 2>&1)"; rc=$?
  set -e
}
wait_quiet 1.0 99 60
assert_eq 0 "$rc"; assert_eq "" "$out"; [[ ! -e "$WORK/slept" ]] || fail "machine_wait_quiet slept on a calm machine"
wait_quiet 9.0 2 60   # busy, calm after two waits: waits, then starts
assert_eq 0 "$rc"; assert_eq 2 "$(cat "$WORK/slept")"
assert_contains "$out" "busy (load 9.0/4): waiting up to 60s"; assert_contains "$out" "quiet after 30s"
assert_eq "$out" "$(cat "$WORK/wait.txt")"   # what it says is also recorded
wait_quiet 9.0 99 45   # busy throughout: gives up after the maximum and says so
assert_eq 1 "$rc"; assert_eq 3 "$(cat "$WORK/slept")"; assert_contains "$out" "still busy after 45s (load 9.0/4); not starting"
echo "PASS: machine-load-unit"
