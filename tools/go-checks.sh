#!/usr/bin/env bash
# go-checks.sh [--require] <module-dir> [packages…] — t-9a2b: staticcheck and gosec on a Go module's packages (default ./...),
# the one owner of both command lines: .github/workflows/go-checks.yml runs it with --require, tools/pre-gate-check.sh without.
#   gosec's -exclude= list comes from <module-dir>/.gosec-excludes when present (`G<nnn> <reason>` per line, # comments);
#   a module without the file gets gosec's defaults, so canon's own reasons never mute another project's module.
# Exit: 0 clean; 1 a finding; 2 a usage error, a .gosec-excludes line without a reason, or (with --require) a missing tool.
# Without --require a missing tool prints `<tool> skipped | not installed` and is not a finding.
# go-checks.sh --fuzz <module-dir> <seconds> — t-c2de: every `func Fuzz…(f *testing.F)` in the module's _test.go files, one
# `go test -fuzz` per target (it refuses a pattern matching two). Exit 0 all passed, 1 a target failed, 2 a usage error or no target.
set -euo pipefail

if [[ "${1:-}" == --fuzz ]]; then
  [[ $# -eq 3 && "$3" =~ ^[1-9][0-9]*$ ]] || { echo "usage: go-checks.sh --fuzz <module-dir> <seconds>" >&2; exit 2; }
  mod="$2"; secs="$3"
  [[ -f "$mod/go.mod" ]] || { echo "go-checks: $mod has no go.mod" >&2; exit 2; }
  targets="$(cd "$mod" && find . -name '*_test.go' -not -path './vendor/*' -exec grep -HoE '^func Fuzz[A-Za-z0-9_]*\(f \*testing\.F\)' {} + | sed -E 's#^(.*)/[^/]*_test\.go:func (Fuzz[A-Za-z0-9_]*).*#\1 \2#' | sort)" || true
  [[ -n "$targets" ]] || { echo "go-checks: no Fuzz targets in $mod" >&2; exit 2; }
  rc=0
  while read -r pkg fn; do
    if (cd "$mod" && go test -run '^$' -fuzz "^${fn}\$" -fuzztime "${secs}s" "$pkg"); then echo "fuzz $pkg $fn ok"
    else echo "fuzz $pkg $fn FAIL"; rc=1; fi
  done <<<"$targets"
  exit "$rc"
fi

require=0
if [[ "${1:-}" == --require ]]; then require=1; shift; fi
[[ $# -ge 1 ]] || { echo "usage: go-checks.sh [--require] <module-dir> [packages…]" >&2; exit 2; }
mod="$1"; shift
[[ -f "$mod/go.mod" ]] || { echo "go-checks: $mod has no go.mod" >&2; exit 2; }
pkgs=("$@"); ((${#pkgs[@]})) || pkgs=(./...)

excl=""
if [[ -f "$mod/.gosec-excludes" ]]; then
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^(G[0-9]{3})[[:space:]]+[^[:space:]] ]]; then
      echo "go-checks: $mod/.gosec-excludes:$n: needs 'G<nnn> <reason>': $line" >&2; exit 2
    fi
    excl+="${excl:+,}${BASH_REMATCH[1]}"
  done < "$mod/.gosec-excludes"
fi

rc=0
run() { # run <tool> <args…>: prints the tool's own output and a summary line
  local tool="$1"; shift
  if ! type -P "$tool" >/dev/null; then
    if ((require)); then echo "go-checks: $tool not installed" >&2; rc=2; return 0; fi
    echo "$tool skipped | not installed"; return 0
  fi
  if (cd "$mod" && "$tool" "$@"); then echo "$tool ok"
  else echo "$tool FAIL"; ((rc == 2)) || rc=1; fi
}
run staticcheck "${pkgs[@]}"
if [[ -n "$excl" ]]; then run gosec -quiet "-exclude=$excl" "${pkgs[@]}"
else run gosec -quiet "${pkgs[@]}"; fi
exit "$rc"
