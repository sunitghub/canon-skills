#!/usr/bin/env bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sunitghub/canon/main/install.sh | bash
#   CANON_HOME=/path/to/dir bash <(curl -fsSL ...)
#   bash <(curl -fsSL ...) /path/to/dir

set -euo pipefail

CANON_REPO='https://github.com/sunitghub/canon.git'

# Precedence: positional arg > CANON_HOME env > ~/.canon
_resolve_target() {
  local raw
  if [[ -n "${1-}" && "${1-}" != -* ]]; then
    raw="$1"
  elif [[ -n "${CANON_HOME-}" ]]; then
    raw="$CANON_HOME"
  else
    raw="$HOME/.canon"
  fi
  # Expand tilde inline (avoids subshell so HOME overrides work in tests)
  case "$raw" in
    '~')   raw="$HOME" ;;
    '~/'*) raw="$HOME/${raw#'~'/}" ;;
  esac
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    *)  printf '%s/%s' "$PWD" "$raw" ;;
  esac
}

# Allow sourcing for tests without running main (BASH_SOURCE is unreliable under curl|bash)
(return 0 2>/dev/null) && return 0

if ! command -v git >/dev/null 2>&1; then
  printf 'error: git is required — https://git-scm.com/downloads\n' >&2
  exit 1
fi

TARGET="$(_resolve_target "${1-}")"

if [[ -f "$TARGET/skills.sh" ]]; then
  printf 'canon already installed at %s\nPulling latest updates...\n' "$TARGET"
  if ! git -C "$TARGET" pull --ff-only; then
    printf 'warning: git pull failed — your local changes may conflict. Skipping update.\n' >&2
  fi
else
  printf 'Cloning canon → %s\n' "$TARGET"
  mkdir -p "$(dirname "$TARGET")"
  if ! git clone "$CANON_REPO" "$TARGET"; then
    printf 'error: clone failed. Check your git config and try again.\n' >&2
    exit 1
  fi
fi

printf 'Wiring agent hooks...\n'
bash "$TARGET/skills.sh" init

printf '\nDone.\n\n'
printf '  Register skills in a project:\n\n'
printf '    cd /path/to/your-project\n'
printf '    %s/skills.sh add sprint\n\n' "$TARGET"
printf '  Full setup guide: %s/guides/AI-Agents-Setup.md\n\n' "$TARGET"
