#!/usr/bin/env bash
# fetch-daemon.sh — put canon's verified prebuilt program where canon expects it (t-60f7, t-9383, t-bdb0).
#   canon-go is one program holding the board server and the Cockpit daemon (`canon-go board`, `canon-go daemon`, t-bdb0):
#   macOS and Linux: tools/canon-go-bin/canon-go. Windows (Git Bash): tools/canon-go-win.exe. A checkout or a zip install has
#   only the source until this runs. (t-b62a: the board's helpers replaced the headless JSON helper.)
# The binary is gitignored. This downloads the one published by scripts/release-daemon.sh (release canon-go-<key>) and moves it
# into place only after its SHA-256 equals the line for <source key> canon-go-<target> in tools/cockpit-daemon.sha256 (read from
# the install itself; the file keeps its name, older trees read their own lines from it).
# The key is tools/src-key.sh's `canon-go` key; an install with no .git (a Windows zip install, a release package) uses the
# newest manifest line for the target instead. A failure never touches a binary that is already in place. If no download is
# possible it builds from source when Go is new enough, else says what to do. Once canon-go is in place the two programs it
# replaced (cockpit-daemon, sprint-check) are removed from this install. Called by install.ps1, pkg_install, `canon update` and `canon`.
# Usage: fetch-daemon.sh [--quiet]     exit 0 = the binary is in place, 1 = it could not be provided.
# CANON_FETCH_NO_BUILD=1 skips the build-from-source fallback (canon on Windows uses it at start). On macOS/Linux canon
# lets it build, so a committed but unreleased board or daemon change runs from source on a machine with Go (t-15d8).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MODULE_DIR="$REPO/tools/canon-go"   # t-bdb0: the board and the daemon are one program, cmd/canon-go
# shellcheck source=tools/src-key.sh
source "$SCRIPT_DIR/src-key.sh"   # canon_src_key and canon_ldflags: what the release key is built from, and the stamps
MANIFEST="$SCRIPT_DIR/cockpit-daemon.sha256"
RELEASE_BASE="${CANON_DAEMON_RELEASE_BASE:-https://github.com/sunitghub/canon-skills/releases/download}"
quiet=0; [ "${1:-}" = --quiet ] && quiet=1

LABEL="canon-go"
say() { echo "$LABEL: $*"; }
die() { echo "$LABEL: $*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;   # Git Bash; the exes are amd64 (an ARM64 PC runs them under emulation)
  *) exit 0 ;;
esac
if [ "$os" != windows ]; then
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) die "no prebuilt binaries for CPU '$(uname -m)'. Build it: cd tools/canon-go && go build -o ../canon-go-bin/canon-go ./cmd/canon-go" ;;
  esac
fi

# The manifest may carry CRLF line ends (a Windows git checkout with core.autocrlf): strip them before reading.
manifest_lines() { tr -d '\r' < "$MANIFEST" 2>/dev/null || true; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

tmp=""
cleanup() { [ -z "$tmp" ] || rm -f -- "$tmp"; }
trap cleanup EXIT

# Per-component settings, set by the loop at the bottom:
#   COMP (component name for tools/src-key.sh: its key and its sources), TARGET (manifest column 2), ASSET (file name in the release), TAG (release prefix),
#   DEST (absolute path the binary must land at), VERSION_CHECK (1 = the binary prints its commit stamp: macOS/Linux).
COMP=""; TARGET=""; ASSET=""; TAG=""; DEST=""; VERSION_CHECK=0; NEXT=""
key=""; full=""; stamp=""; fail_reason=""

# Move the finished temp file into place. mv into an existing directory would "succeed" by nesting the file, so refuse that explicitly.
install_tmp() {
  [ ! -d "$DEST" ] || { fail_reason="$DEST is a directory, not a file"; return 1; }
  chmod 0755 "$tmp" && mv -f -- "$tmp" "$DEST" || { fail_reason="could not move the verified file into place ($DEST)"; return 1; }
  tmp=""
}

# A binary already in place is current if it carries this commit's stamp (macOS/Linux) or hashes to the manifest line.
is_current() {
  [ -f "$DEST" ] || return 1
  if [ "$VERSION_CHECK" = 1 ]; then
    [ -x "$DEST" ] || return 1
    local have; have="$("$DEST" --version 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')" || have=""
    [ -n "$have" ] && [ "${full#"$have"}" != "$full" ]
  else
    local want; want="$(manifest_lines | awk -v k="$key" -v t="$TARGET" '$1==k && $2==t {print $3; exit}')" || want=""
    [ "${#want}" = 64 ] && [ "$(sha256_of "$DEST" 2>/dev/null)" = "$want" ]
  fi
}

try_download() {
  local want got url
  want="$(manifest_lines | awk -v k="$key" -v t="$TARGET" '$1==k && $2==t {print $3; exit}')" || want=""
  case "$want" in
    *[!0-9a-f]*|"") fail_reason="no checksum for $TARGET at source commit $key in tools/cockpit-daemon.sha256 (not released yet)"; return 1 ;;
  esac
  [ "${#want}" = 64 ] || { fail_reason="the checksum line for $TARGET is malformed"; return 1; }
  command -v curl >/dev/null 2>&1 || { fail_reason="curl is not installed"; return 1; }
  mkdir -p "$(dirname "$DEST")"
  tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").XXXXXX")"
  url="$RELEASE_BASE/$TAG-$key/$ASSET"
  curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp" "$url" 2>/dev/null || { fail_reason="download failed ($url)"; return 1; }
  got="$(sha256_of "$tmp")" || { fail_reason="no sha256sum or shasum to verify the download"; return 1; }
  [ "$got" = "$want" ] || { fail_reason="the download does not match its checksum (got ${got:0:12}..., want ${want:0:12}...); it was discarded"; return 1; }
  install_tmp || return 1
  say "fetched $TARGET $key, sha256 verified"
}

build_from_source() {
  [ "${CANON_FETCH_NO_BUILD:-0}" = 1 ] && { fail_reason="$fail_reason (not building from source at start; run canon update)"; return 1; }
  command -v go >/dev/null 2>&1 || { fail_reason="$fail_reason; and Go is not installed to build it"; return 1; }
  [ -d "$MODULE_DIR/cmd/$COMP" ] || { fail_reason="$fail_reason; and this install does not carry the source (the end-user zip leaves it out): run canon update, reinstall, or clone the repository to build"; return 1; }
  local semver; semver="$(tr -d ' \t\n\r' < "$REPO/VERSION" 2>/dev/null)" || semver=dev
  mkdir -p "$(dirname "$DEST")"
  tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").XXXXXX")"
  local ok=1 stamps ldflags
  stamps="$(canon_ldflags "$REPO")" || stamps="-X main.commit=$stamp"   # the daemon key needs the git trees; without them, no stale check
  ldflags="-X main.version=$semver $stamps"
  ( cd "$MODULE_DIR" && GOTOOLCHAIN=local go build -buildvcs=false -ldflags "$ldflags" -o "$tmp" "./cmd/$COMP" ) >/dev/null 2>&1 || ok=0
  if [ "$ok" = 1 ]; then
    install_tmp || return 1
    say "built from source ($stamp)"
  else
    local need; need="$(awk '/^go /{print $2}' "$MODULE_DIR/go.mod" 2>/dev/null)" || need=""
    fail_reason="$fail_reason; and building from source failed${need:+ (needs Go $need or newer, found $(go env GOVERSION 2>/dev/null || echo none))}"
    return 1
  fi
}

# fetch_one: provide one binary. Returns 0 when it is in place, 1 with a message on stderr otherwise. Never touches DEST on failure.
fetch_one() {
  fail_reason=""
  # The key comes from the git trees of the component's sources (tools/src-key.sh): the same in a shallow or partial clone and
  # after a history rewrite, unlike the last commit that touched them.
  full="$(canon_src_key "$REPO" "$COMP")" || full=""
  if [ -z "$full" ] && { [ "$os" = windows ] || [ ! -e "$REPO/.git" ]; }; then
    # A zip install (Windows) or a release package (t-50f7, macOS/Linux) has no .git: the newest manifest line for this target names
    # what was released with this copy of the tools.
    full="$(manifest_lines | awk -v t="$TARGET" '$2==t {k=$1} END{print k}')" || full=""
    case "$full" in *[!0-9a-f]*) full="" ;; esac
  fi
  if [ -z "$full" ]; then
    echo "$LABEL: $REPO is not a git checkout with the $COMP source, so the matching binary cannot be named. Reinstall: curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash" >&2
    return 1
  fi
  key="${full:0:12}"; stamp="${full:0:8}"

  if is_current; then
    [ "$quiet" = 1 ] || say "up to date ($key)"
    return 0
  fi
  if try_download; then return 0; fi
  # A rejected download is said out loud before anything else is tried, so a checksum mismatch is never hidden by a successful fallback build.
  echo "$LABEL: $fail_reason" >&2
  cleanup; tmp=""
  if build_from_source; then return 0; fi
  echo "$LABEL: could not provide $(basename "$DEST") for $TARGET: $fail_reason.
  Next: $NEXT" >&2
  return 1
}

# The component list: label|component (tools/src-key.sh)|manifest target|release asset|release prefix|destination|required|version-check
# t-bdb0: one program; the release prefix and the target both say canon-go, so its lines never mix with the older programs' lines.
if [ "$os" = windows ]; then
  COMPONENTS="canon-go|canon-go|canon-go-windows-amd64|canon-go-windows-amd64.exe|canon-go|tools/canon-go-win.exe|1|0"
  LEGACY="tools/cockpit-daemon-win.exe tools/sprint-check-win.exe"
else
  COMPONENTS="canon-go|canon-go|canon-go-$os-$arch|canon-go-$os-$arch|canon-go|tools/canon-go-bin/canon-go|1|1"
  LEGACY="tools/cockpit-daemon/cockpit-daemon tools/sprint-check-bin/sprint-check"
fi

# remove_legacy: t-bdb0, once canon-go is in place, delete the two programs it replaced from THIS install (an update from an older tree
# leaves them; on Windows they are ~7 MB more than canon-go). Only a regular file at exactly those paths, never through a symlink; a
# program that is still running on Windows cannot be deleted and is named, never forced.
remove_legacy() {
  local rel f
  for rel in $LEGACY; do
    f="$REPO/$rel"
    [ -f "$f" ] && [ ! -L "$f" ] && [ ! -L "$(dirname "$f")" ] || continue
    if rm -f -- "$f" 2>/dev/null && [ ! -e "$f" ]; then say "removed $rel (replaced by canon-go)"
    else echo "$LABEL: could not remove $rel (still running?); run canon stop, then canon update" >&2; fi
    [ "$(dirname "$rel")" = tools ] || rmdir -- "$(dirname "$f")" 2>/dev/null || true   # its own folder, only when empty
  done
  return 0
}

rc=0
while IFS='|' read -r LABEL COMP TARGET ASSET TAG rel required VERSION_CHECK; do
  [ -n "$LABEL" ] || continue
  DEST="$REPO/$rel"
  if [ "$os" = windows ]; then NEXT="run canon update (or the installer again) once online"
  else NEXT="install Go (brew install go, or https://go.dev/dl) and run: canon update
  or build it by hand: cd \"$MODULE_DIR\" && go build -o \"$DEST\" ./cmd/$COMP"; fi
  if ! fetch_one; then
    if [ "$required" = 1 ]; then rc=1; fi
  fi
  cleanup; tmp=""   # a failed source build or move must not leave its temp file for the next component (or in the clone, where git would call it dirty)
done <<EOF
$COMPONENTS
EOF
if [ "$rc" = 0 ]; then remove_legacy; fi
exit "$rc"
