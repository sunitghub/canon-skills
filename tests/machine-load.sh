#!/usr/bin/env bash
# machine-load (t-5989) — sourced by tests/run-board-spec.sh: records how busy the machine is at the start and end of a board spec
# run, and warns when it is too busy to trust. A WebKit run with scripts/test.sh beside it went from 2-3 failures to 8 and ran 21 %
# slower while the board stayed fast (.tickets/t-5989/evidence/diagnosis.md), so a failing run must carry the load it ran under.
#
#   machine_load <label> <file> <own-pid>
# Appends one line to <file> and prints it: the 1-minute load average, the CPU count, and the PIDs of other scripts/test.sh or
# run-board-spec.sh runs (by command line; read only, nothing is signalled). Processes descended from <own-pid> are not "other".
# Prints a WARNING line when the load is above the CPU count or another run is going. Always returns 0: it informs, never blocks.

_ml_load1() {   # Linux /proc/loadavg (ML_LOADAVG_FILE overrides it for the unit test), else macOS sysctl
  local f="${ML_LOADAVG_FILE:-/proc/loadavg}"
  if [ -r "$f" ]; then cut -d' ' -f1 "$f"; return; fi
  sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'
}
_ml_ncpu() { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1; }
_ml_descends() {   # _ml_descends <pid> <ancestor>: 0 when <pid> is <ancestor> or below it
  local p="$1"
  while [ -n "$p" ]; do   # ps prints nothing for the parent of PID 0, so the walk ends above the root
    [ "$p" = "$2" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}
machine_load() {
  local label="$1" file="$2" own="$3" load ncpu others="" p line
  load="$(_ml_load1)"; ncpu="$(_ml_ncpu)"
  for p in $(pgrep -f 'scripts/test\.sh|tests/run-board-spec\.sh' 2>/dev/null); do
    _ml_descends "$p" "$own" || others="$others $p"
  done
  line="machine-load: $label: load ${load:-unknown} on $ncpu CPUs; other test runs:${others:- none}"
  printf '%s\n' "$line" | tee -a "$file"
  if [ -n "$others" ] || awk -v l="${load:-0}" -v c="$ncpu" 'BEGIN{exit !(l > c)}'; then
    printf 'machine-load: WARNING: the machine is busy (%s): WebKit fails timing-sensitive tests under load; rerun on a quiet machine before trusting failures\n' \
      "${others:+other runs:$others}${others:+; }load ${load:-unknown}/$ncpu" | tee -a "$file" >&2
  fi
  return 0
}
