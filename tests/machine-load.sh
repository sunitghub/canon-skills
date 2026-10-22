#!/usr/bin/env bash
# machine-load (t-5989) — sourced by tests/run-board-spec.sh: records how busy the machine is at the start and end of a board spec
# run, and warns when it is too busy to trust. A WebKit run with scripts/test.sh beside it went from 2-3 failures to 8 and ran 21 %
# slower while the board stayed fast (.tickets/t-5989/evidence/diagnosis.md), so a failing run must carry the load it ran under.
#
#   machine_load <label> <file> <own-pid>
# Appends one line to <file> and prints it: the 1-minute load average, the CPU count, and the PIDs of other scripts/test.sh or
# run-board-spec.sh runs (by command line; read only, nothing is signalled). Processes descended from <own-pid> are not "other".
# Prints a WARNING line when the load is above the CPU count or another run is going. Always returns 0: it informs, never blocks.
#   machine_wait_quiet <file> <own-pid>   (t-8627) waits for that rule to clear before a run starts; returns 1 if it never does

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
_ml_others() {   # _ml_others <own-pid>: the PIDs of other scripts/test.sh or run-board-spec.sh runs, space-separated
  local p out=""
  for p in $(pgrep -f 'scripts/test\.sh|tests/run-board-spec\.sh' 2>/dev/null); do
    _ml_descends "$p" "$1" || out="$out $p"
  done
  printf '%s' "$out"
}
_ml_busy() {   # _ml_busy <own-pid> [load] [ncpu] [others]: prints why the machine is busy (nothing when it is calm); the one rule
  local own="$1" load="${2:-$(_ml_load1)}" ncpu="${3:-$(_ml_ncpu)}" others="${4-$(_ml_others "$1")}"
  if [ -n "$others" ] || awk -v l="${load:-0}" -v c="$ncpu" 'BEGIN{exit !(l > c)}'; then
    printf '%s' "${others:+other runs:$others}${others:+; }load ${load:-unknown}/$ncpu"
  fi
}
machine_load() {
  local label="$1" file="$2" own="$3" load ncpu others why line
  load="$(_ml_load1)"; ncpu="$(_ml_ncpu)"; others="$(_ml_others "$own")"
  line="machine-load: $label: load ${load:-unknown} on $ncpu CPUs; other test runs:${others:- none}"
  printf '%s\n' "$line" | tee -a "$file"
  why="$(_ml_busy "$own" "$load" "$ncpu" "$others")"
  if [ -n "$why" ]; then
    printf 'machine-load: WARNING: the machine is busy (%s): WebKit fails timing-sensitive tests under load; rerun on a quiet machine before trusting failures\n' "$why" | tee -a "$file" >&2
  fi
  return 0
}

# machine_wait_quiet <file> <own-pid> (t-8627): a run that STARTS on a busy machine fails WebKit tests that pass on a quiet one (the 13
# failures of the t-d40b close began at load 11 on 10 CPUs, right after scripts/test.sh), so the runner waits for the same rule that
# machine_load warns on. Polls every ML_WAIT_POLL seconds (default 15) for at most ML_WAIT_MAX seconds (default 900), prints and records
# each wait, returns 0 once calm and 1 if it never was; the runner then refuses unless --allow-busy.
machine_wait_quiet() {
  local file="$1" own="$2" waited=0 poll="${ML_WAIT_POLL:-15}" max="${ML_WAIT_MAX:-900}" why
  while why="$(_ml_busy "$own")"; [ -n "$why" ]; do
    if [ "$waited" -ge "$max" ]; then
      printf 'machine-load: still busy after %ss (%s); not starting\n' "$waited" "$why" | tee -a "$file" >&2
      return 1
    fi
    [ "$waited" -gt 0 ] || printf 'machine-load: busy (%s): waiting up to %ss for a quiet machine\n' "$why" "$max" | tee -a "$file"
    sleep "$poll"; waited=$((waited + poll))
  done
  [ "$waited" -eq 0 ] || printf 'machine-load: quiet after %ss\n' "$waited" | tee -a "$file"
  return 0
}
