#!/usr/bin/env bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash
#   CANON_HOME=/path/to/dir bash <(curl -fsSL ...)
#   bash <(curl -fsSL ...) /path/to/dir

set -euo pipefail

CANON_REPO="${CANON_REPO:-https://github.com/sunitghub/canon-skills.git}"   # the override is a test seam
# t-65c9: a new install is the latest verified release (the same check as `canon update`). CANON_REF=main installs the development track, CANON_REF=vX.Y.Z a version.
CANON_REF_GIVEN="${CANON_REF:+1}"
CANON_REF="${CANON_REF:-latest}"

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
  printf 'canon already installed at %s\nUpdating...\n' "$TARGET"
  # an explicit CANON_REF picks the version; otherwise the install keeps its own track (latest release unless it follows main)
  upd=(update); [[ -z "${CANON_REF_GIVEN-}" ]] || upd=(update --to "$CANON_REF")
  if ! bash "$TARGET/tools/canon" "${upd[@]}"; then
    printf 'warning: canon update did not finish — nothing was changed, or your local changes conflict. Skipping update.\n' >&2
  fi
else
  printf 'Cloning canon → %s\n' "$TARGET"
  mkdir -p "$(dirname "$TARGET")"
  target_existed=0; [[ -e "$TARGET" ]] && target_existed=1   # an existing (empty) folder is the user's: clean its contents, never the folder itself
  # t-0d25: depth 1 (sizes and how to get full history: docs/setup.md)
  if ! git clone --depth 1 -- "$CANON_REPO" "$TARGET"; then
    printf 'error: clone failed. Check your git config and try again.\n' >&2
    exit 1
  fi
  # t-65c9: move the clone to the verified release (or the requested ref). If that cannot be verified nothing is left installed.
  if ! bash "$TARGET/tools/canon" update --to "$CANON_REF"; then
    if [[ "$target_existed" == 1 ]]; then find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; else rm -rf -- "$TARGET"; fi
    printf 'error: could not install a verified canon release, so nothing was installed.\n       To install the development version instead: CANON_REF=main  (then run this again)\n' >&2
    exit 1
  fi
fi

printf 'Wiring agent hooks...\n'
bash "$TARGET/tools/skills.sh" init

# t-60f7: the cockpit daemon is gitignored, so a clone has none; fetch the verified prebuilt (or build it). Never fatal: the board still works.
bash "$TARGET/tools/fetch-daemon.sh" || printf 'warning: agent sessions in the Cockpit need the daemon; see the message above, or run: canon update\n' >&2

RC_FILE="$HOME/.bashrc"
[[ "${SHELL:-}" == */zsh ]] && RC_FILE="$HOME/.zshrc"

if [[ "$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)" == main ]]; then
  printf '\nNote: this installed main (development, not checksum-verified). For the latest verified release: canon update --to latest\n'
else
  printf '\nInstalled the verified release %s. Update any time with: canon update\n' "$(git -C "$TARGET" describe --tags --exact-match 2>/dev/null || echo '')"
fi
printf '\nDone.\n\n'
