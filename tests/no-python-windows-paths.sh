#!/usr/bin/env bash
# tests/no-python-windows-paths.sh — t-55c1, t-b62a: no shipped script runs Python. canon may assume only Git for Windows on
# Windows and no python3 anywhere, so every tracked script under tools/ and scripts/ (and the installers) is scanned for a
# non-comment line that invokes python/python3/py. The board binary's helpers (headless-json, json-strings, settings,
# skill-check) replaced the last uses. Out of scope, named here: tools/canon-dev.sh
# (contributor tooling) and tools/mutant-sweep* (dev-only, advisory). Protects no-Python installs and headless CI.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

exempt=' tools/canon-dev.sh tools/mutant-sweep tools/mutant-sweep.py '

# Every tracked text script an end user runs or canon installs: shell and PowerShell files, and extension-less executables.
files=()
while IFS= read -r f; do
  case " $exempt " in *" $f "*) continue ;; esac
  case "$f" in
    *.sh|*.ps1|*.cmd) files+=("$f") ;;
    *.*) ;;
    *) [ -x "$ROOT/$f" ] && [[ "$(head -c 2 "$ROOT/$f")" == '#!' ]] && files+=("$f") ;;
  esac
done < <(git -C "$ROOT" ls-files tools scripts install.sh install.ps1 | grep -v '^tools/canon-go/')
[ "${#files[@]}" -gt 40 ] || fail "no-python-windows-paths: only ${#files[@]} scripts found — the file list is broken"

count_python() {  # non-comment lines that invoke python3 / python / py -
  grep -vE '^[[:space:]]*#' "$ROOT/$1" | grep -cE '(^|[^A-Za-z0-9_./-])(python3?|py -)([^A-Za-z0-9_]|$)' || true
}

bad=0
for f in "${files[@]}"; do
  n="$(count_python "$f")"
  [[ "$(head -n 1 "$ROOT/$f")" =~ ^\#!.*python ]] && n="$n (a Python script)"
  if [ "$n" != 0 ]; then
    echo "no-python-windows-paths: $f has $n line(s) that run Python: use the board binary's helpers (tools/platform-lib.sh board_helper_bin)" >&2
    bad=1
  fi
done
for f in tools/sprint-headless tools/sprint-headless-eval tools/skills/prompts.sh tools/platform-lib.sh; do   # the files t-b62a cleared
  grep -qx "$f" <<<"$(printf '%s\n' "${files[@]}")" || fail "no-python-windows-paths: $f is not scanned"
done
[ "$bad" -eq 0 ] || fail "python use in shipped scripts (see above)"

printf 'no-python-windows-paths: ok (%s scripts)\n' "${#files[@]}"
