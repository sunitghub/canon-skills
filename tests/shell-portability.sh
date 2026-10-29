#!/usr/bin/env bash
# shell-portability — no canon shell code loads functions with `source <(...)` (t-6cf5).
#
# macOS's /bin/bash is 3.2, and bash 3.2 sources nothing from a process substitution: the functions are
# silently missing. Cloud sessions run Linux's bash 5, where it works, so the trap reached the Mac only at
# merge (t-0865's tests/sprint-approve.sh, fixed in 6d857842). Use eval "$(...)" instead.
#
# Scans every tracked *.sh file and every tracked extensionless file with a sh/bash shebang; comment lines
# never count. SHELL_PORTABILITY_ROOT points it at a scratch clone, so the guard can be revert-checked there.
set -euo pipefail

ROOT="${SHELL_PORTABILITY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF="tests/$(basename "${BASH_SOURCE[0]}")"

bad=""
while IFS= read -r f; do
  [[ "$f" == "$SELF" || ! -f "$ROOT/$f" ]] && continue
  if [[ "$f" != *.sh ]]; then
    head -1 "$ROOT/$f" | grep -qE '^#!.*\b(ba)?sh\b' || continue
  fi
  hits="$(awk -v file="$f" '/^[[:space:]]*#/ { next } /(^|[^[:alnum:]_])(source|\.)[[:space:]]+<\(/ { print file ":" NR ": " $0 }' "$ROOT/$f")"
  [[ -n "$hits" ]] && bad+="$hits"$'\n'
done < <(git -C "$ROOT" ls-files)

if [[ -n "$bad" ]]; then
  printf '%s' "$bad" >&2
  echo "FAIL: source <(...) loads nothing under bash 3.2, the macOS default: use eval \"\$(...)\" instead" >&2
  exit 1
fi
echo "shell-portability: ok"
