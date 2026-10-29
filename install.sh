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

# t-50f7: the install is versioned: $TARGET/packages/<vX.Y.Z>/ (or packages/main, a clone) and $TARGET/current, a link to one of them.
# $TARGET stays the home: it also holds the data (cockpit/, events/, ...). An older install is a clone at $TARGET itself.
TOOLS="$TARGET/current/tools"
if [[ -f "$TARGET/current/tools/skills.sh" || -f "$TARGET/tools/skills.sh" ]]; then
  [[ -f "$TOOLS/skills.sh" ]] || TOOLS="$TARGET/tools"
  printf 'canon already installed at %s\nUpdating...\n' "$TARGET"
  # an explicit CANON_REF picks the version; otherwise the install keeps its own track (latest release unless it follows main)
  upd=(update); [[ -z "${CANON_REF_GIVEN-}" ]] || upd=(update --to "$CANON_REF")
  if ! bash "$TOOLS/canon" "${upd[@]}"; then
    printf 'warning: canon update did not finish — nothing was changed, or your local changes conflict. Skipping update.\n' >&2
  fi
  [[ ! -f "$TARGET/current/tools/skills.sh" ]] || TOOLS="$TARGET/current/tools"   # the update may have moved an older install into the layout
else
  # The clone this replaced refused a folder with anything in it; so does this, so canon never spreads into a folder of yours (~/Documents).
  # Allowed: canon's own data, as `canon uninstall --keep-data` leaves it (the names of tools/pkg-lib.sh pkg_is_data), packages/, .DS_Store.
  if [[ -e "$TARGET" && ! -d "$TARGET" ]]; then printf 'error: %s exists and is not a folder. Nothing was written.\n' "$TARGET" >&2; exit 1; fi
  for e in "$TARGET"/* "$TARGET"/.[!.]* "$TARGET"/..?*; do
    [[ -e "$e" || -L "$e" ]] || continue
    case "${e##*/}" in
      cockpit|events|themes|settings.json|integrity|logs|.canon-track|.canon-cache|packages|.DS_Store) ;;
      *) printf 'error: %s is not empty and is not a canon install (it holds %s). Install into a new or empty folder (CANON_HOME=<folder>, or the folder as an argument). Nothing was written.\n' "$TARGET" "${e##*/}" >&2; exit 1 ;;
    esac
  done
  printf 'Installing canon → %s\n' "$TARGET"
  # on failure remove only what this run made: an existing folder (empty, or holding data kept from an earlier install) is the user's
  target_existed=0; [[ -e "$TARGET" ]] && target_existed=1
  packages_existed=0; [[ -e "$TARGET/packages" ]] && packages_existed=1
  undo() {
    [[ -z "${boot-}" ]] || rm -rf -- "$boot"
    if [[ "$target_existed" == 0 ]]; then rm -rf -- "$TARGET"; return 0; fi
    [[ "$packages_existed" == 1 ]] || rm -rf -- "$TARGET/packages"
    if [[ -L "$TARGET/current" ]]; then rm -f -- "$TARGET/current"; fi
    if [[ -L "$TARGET/tools" ]]; then rm -f -- "$TARGET/tools"; fi
    return 0
  }
  mkdir -p "$TARGET/packages"
  # t-0d25: depth 1 (sizes and how to get full history: docs/setup.md). The clone only carries the code that builds the layout: inside
  # packages/ (where `canon update` finds its home), under a dot name no update counts as a package, and removed once it is done.
  boot="$(mktemp -d "$TARGET/packages/.boot.XXXXXX")"
  boot="$(cd -P -- "$boot" && pwd -P)"   # t-6450: canon update finds its home by physical path; ps must show the same spelling
  if ! git clone --depth 1 -- "$CANON_REPO" "$boot"; then
    undo
    printf 'error: clone failed. Check your git config and try again.\n' >&2
    exit 1
  fi
  # t-65c9: install the verified release (or the requested ref). If that cannot be verified nothing is left installed.
  if ! bash "$boot/tools/canon" update --to "$CANON_REF"; then
    undo
    printf 'error: could not install a verified canon release, so nothing was installed.\n       To install the development version instead: CANON_REF=main  (then run this again)\n' >&2
    exit 1
  fi
  rm -rf -- "$boot"
fi

printf 'Wiring agent hooks...\n'
bash "$TOOLS/skills.sh" init

RC_FILE="$HOME/.bashrc"
[[ "${SHELL:-}" == */zsh ]] && RC_FILE="$HOME/.zshrc"

# what current names (a package), or for an older install what its clone is on; the binaries came with the package or its canon update
installed="$(readlink "$TARGET/current" 2>/dev/null)" || installed=""; installed="${installed##*/}"
if [[ -z "$installed" ]]; then
  if [[ "$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)" == main ]]; then installed=main; else installed="$(git -C "$TARGET" describe --tags --exact-match 2>/dev/null || echo '')"; fi
fi
if [[ "$installed" == main ]]; then
  # The development-version notice came from `canon update` above (t-bb84: printing it here too showed it twice)
  printf '\nInstalled the development version (main).\n'
else
  printf '\nInstalled the verified release %s. Update any time with: canon update\n' "$installed"
fi
printf '\nDone.\n\n'
# t-5738: a first-time user has no project folder yet; say where to go (canon works in the home folder too, but a project folder keeps tickets with the project)
printf 'Next: open a terminal in your project folder (for example %s/projects/demo; make it with mkdir -p, then git init) and run: canon\n\n' "$HOME"
