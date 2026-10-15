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
printf '#!/bin/sh\ncat "%s/pgrep.out"\n' "$WORK" > "$WORK/bin/pgrep"
printf '#!/bin/sh\n# ps -o ppid= -p PID: look PID up in the parent map\nawk -v p="$4" '"'"'$1 == p {print $2}'"'"' "%s/ppid.map"\n' "$WORK" > "$WORK/bin/ps"
chmod +x "$WORK/bin/"*
export ML_LOADAVG_FILE="$WORK/loadavg"
run() {   # run <load> <pgrep pids...>: machine_load as the runner calls it (own pid 100); sets out and rc
  echo "$1 1.0 1.0 1/100 999" > "$WORK/loadavg"; shift
  printf '%s\n' "$@" > "$WORK/pgrep.out"
  set +e
  out="$(PATH="$WORK/bin:$PATH" bash -c 'source "$1/tests/machine-load.sh"; machine_load start "$2" 100' _ "$ROOT" "$WORK/record.txt" 2>&1)"; rc=$?
  set -e
}
printf '200 100\n300 200\n4242 1\n' > "$WORK/ppid.map"   # 200 is the runner's child, 300 its grandchild; 4242 is someone else's run

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

echo "PASS: machine-load-unit"
