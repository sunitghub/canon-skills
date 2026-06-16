#!/usr/bin/env bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash
#   CANON_HOME=/path/to/dir bash <(curl -fsSL ...)
#   bash <(curl -fsSL ...) /path/to/dir

set -euo pipefail

CANON_REPO='https://github.com/sunitghub/canon-skills.git'

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

if [[ -f "$TARGET/tools/skills.sh" ]]; then
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
bash "$TARGET/tools/skills.sh" init

RC_FILE="$HOME/.bashrc"
[[ "${SHELL:-}" == */zsh ]] && RC_FILE="$HOME/.zshrc"

printf '\nDone.\n\n'
printf '  ──────────────────────────────────────────────────\n'
printf '  Try the Todo walkthrough:\n'
printf '    %s/scripts/copy-todo-walkthrough.sh /tmp/canon-todo\n' "$TARGET"
printf '    cd /tmp/canon-todo && %s/tools/skills.sh add sprint\n' "$TARGET"
printf '  ──────────────────────────────────────────────────\n\n'
