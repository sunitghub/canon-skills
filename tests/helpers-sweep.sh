#!/usr/bin/env bash
# sweep_stale_stub_processes (t-2a71): reaps a leaked test-stub daemon
# (`python3 - <<PY`) whose only other cleanup path is a trap that can't fire
# if the process was SIGKILLed or its parent shell torn down non-gracefully.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v lsof >/dev/null 2>&1 || ! command -v pgrep >/dev/null 2>&1; then
  echo "helpers-sweep: lsof/pgrep absent — skipped"
  exit 0
fi

# Resolved via cd+`pwd -P` (physical path), not raw mktemp output or a plain
# `pwd` — macOS symlinks /var to /private/var, lsof reports the resolved
# path, and plain `pwd` doesn't traverse the symlink either.
CWD_A="$(cd "$(mktemp -d)" && pwd -P)"
CWD_B="$(cd "$(mktemp -d)" && pwd -P)"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$CWD_A" "$CWD_B"
}
trap cleanup EXIT

spawn_stub() {
  local cwd="$1"
  ( cd "$cwd" && exec python3 - <<'PY'
import time
time.sleep(120)
PY
  ) &
  PIDS+=("$!")
  disown 2>/dev/null || true
  # give the shell a moment to actually exec into python3 before the test proceeds
  sleep 0.3
}

# Case 1: old + right cwd → swept (ceiling forced to 0 to simulate "old" without a real wait).
spawn_stub "$CWD_A"
old_pid="${PIDS[${#PIDS[@]}-1]}"
sleep 1.2
sweep_stale_stub_processes 0 "$CWD_A"
sleep 0.3
kill -0 "$old_pid" 2>/dev/null && fail "expected old+matching-cwd stub to be swept, still alive: $old_pid"

# Case 2: young + right cwd → left alone (real 300s default ceiling; this stub is seconds old).
spawn_stub "$CWD_A"
young_pid="${PIDS[${#PIDS[@]}-1]}"
sweep_stale_stub_processes 300 "$CWD_A"
sleep 0.3
kill -0 "$young_pid" 2>/dev/null || fail "expected young stub to survive the age gate, but it's gone: $young_pid"

# Case 3: old + wrong cwd → left alone (cwd gate).
spawn_stub "$CWD_B"
wrong_cwd_pid="${PIDS[${#PIDS[@]}-1]}"
sleep 1.2
sweep_stale_stub_processes 0 "$CWD_A"
sleep 0.3
kill -0 "$wrong_cwd_pid" 2>/dev/null || fail "expected different-cwd stub to survive the cwd gate, but it's gone: $wrong_cwd_pid"

# t-3f04: the pattern matches every form ps shows a stub as, and nothing else.
for c in 'python3 -' 'python3.15 -' '/usr/bin/python3 -' '/opt/homebrew/bin/python3 -' \
  '/opt/homebrew/Cellar/python@3.15/3.15.0/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python -'; do
  printf '%s\n' "$c" | grep -E "$STUB_PROC_RE" >/dev/null || fail "the stub pattern misses '$c'"
done
for c in 'python3 script.py' 'python3 -c x' 'python3 - extra' 'mypython3 -' 'Python' 'python -' 'node -' '/usr/bin/xpython3 -'; do
  if printf '%s\n' "$c" | grep -E "$STUB_PROC_RE" >/dev/null; then fail "the stub pattern wrongly matches '$c'"; fi
done

printf 'helpers-sweep: ok\n'
