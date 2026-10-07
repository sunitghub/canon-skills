#!/usr/bin/env bash
# fetch-daemon.sh — put verified prebuilt binaries where canon expects them (t-60f7, t-9383).
#   macOS and Linux: the cockpit daemon at tools/cockpit-daemon/cockpit-daemon.
#   Windows (Git Bash): the daemon, the board server and the headless JSON helper at tools/*-win.exe — they are
#   no longer committed, so a checkout or a zip install has only the source until this runs.
# Every binary is gitignored. This downloads the one published by scripts/release-daemon.sh and moves it into place only
# after its SHA-256 equals the line for <source key> <target> in tools/cockpit-daemon.sha256 (read from the install itself).
# The key is the git tree hash of the component's source folder; an install with no .git (a Windows zip install) uses the
# newest manifest line for the target instead. A failure never touches a binary that is already in place. If no download is
# possible it builds from source when Go is new enough, else says what to do. Called by install.sh, install.ps1,
# `canon update` and `canon`.
# Usage: fetch-daemon.sh [--quiet]     exit 0 = every required binary is in place, 1 = one could not be provided.
# Required: the daemon (and, on Windows, the board). The headless helper only warns.
# CANON_FETCH_NO_BUILD=1 skips the build-from-source fallback (canon uses it at start so launching the board never compiles).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DAEMON_DIR="$REPO/tools/cockpit-daemon"
MANIFEST="$SCRIPT_DIR/cockpit-daemon.sha256"
RELEASE_BASE="${CANON_DAEMON_RELEASE_BASE:-https://github.com/sunitghub/canon-skills/releases/download}"
quiet=0; [ "${1:-}" = --quiet ] && quiet=1

LABEL="cockpit-daemon"
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
    *) die "no prebuilt daemon for CPU '$(uname -m)'. Build it: cd tools/cockpit-daemon && go build -o cockpit-daemon ." ;;
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
#   SRC (source folder under the repo), TARGET (manifest column 2), ASSET (file name in the release), TAG (release prefix),
#   DEST (absolute path the binary must land at), VERSION_CHECK (1 = the binary prints its commit stamp: macOS/Linux daemon).
SRC=""; TARGET=""; ASSET=""; TAG=""; DEST=""; VERSION_CHECK=0; NEXT=""
key=""; full=""; stamp=""; fail_reason=""

# Move the finished temp file into place. mv into an existing directory would "succeed" by nesting the file, so refuse that explicitly.
install_tmp() {
  [ ! -d "$DEST" ] || { fail_reason="$DEST is a directory, not a file"; return 1; }
  chmod 0755 "$tmp" && mv -f -- "$tmp" "$DEST" || { fail_reason="could not move the verified file into place ($DEST)"; return 1; }
  tmp=""
}

# A binary already in place is current if it carries this commit's stamp (daemon on macOS/Linux) or hashes to the manifest line.
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
  local semver; semver="$(tr -d ' \t\n\r' < "$REPO/VERSION" 2>/dev/null)" || semver=dev
  mkdir -p "$(dirname "$DEST")"
  tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").XXXXXX")"
  local ok=1 ldflags="-X main.version=$semver -X main.commit=$stamp"
  if [ "$SRC" = tools/cockpit-daemon ]; then
    ( cd "$DAEMON_DIR" && GOTOOLCHAIN=local go build -buildvcs=false -ldflags "$ldflags" -o "$tmp" . ) >/dev/null 2>&1 || ok=0
  else   # the board and the headless helper are legacy (no go.mod) packages built from the repo root
    ( cd "$REPO" && GO111MODULE=off GOTOOLCHAIN=local go build -buildvcs=false -ldflags "$ldflags" -o "$tmp" "./$SRC" ) >/dev/null 2>&1 || ok=0
  fi
  if [ "$ok" = 1 ]; then
    install_tmp || return 1
    say "built from source ($stamp)"
  else
    local need; need="$(awk '/^go /{print $2}' "$REPO/$SRC/go.mod" 2>/dev/null)" || need=""
    fail_reason="$fail_reason; and building from source failed${need:+ (needs Go $need or newer, found $(go env GOVERSION 2>/dev/null || echo none))}"
    return 1
  fi
}

# fetch_one: provide one binary. Returns 0 when it is in place, 1 with a message on stderr otherwise. Never touches DEST on failure.
fetch_one() {
  fail_reason=""
  # The key is the git tree hash of the source folder: the same in a shallow or partial clone and after a history rewrite,
  # unlike the last commit that touched it.
  full="$(git -C "$REPO" rev-parse -q --verify "HEAD:$SRC" 2>/dev/null)" || full=""
  if [ -z "$full" ] && [ "$os" = windows ]; then
    # A zip install has no .git: the newest manifest line for this target names what was released with this copy of the tools.
    full="$(manifest_lines | awk -v t="$TARGET" '$2==t {k=$1} END{print k}')" || full=""
    case "$full" in *[!0-9a-f]*) full="" ;; esac
  fi
  if [ -z "$full" ]; then
    echo "$LABEL: $REPO is not a git checkout with the $SRC source, so the matching binary cannot be named. Reinstall: curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash" >&2
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

# The component list: label|source folder|manifest target|release asset|release prefix|destination|required|version-check
if [ "$os" = windows ]; then
  COMPONENTS="cockpit-daemon|tools/cockpit-daemon|windows-amd64|cockpit-daemon-windows-amd64.exe|cockpit-daemon|tools/cockpit-daemon-win.exe|1|0
sprint-check-win|tools/sprint-check-go|sprint-check-windows-amd64|sprint-check-windows-amd64.exe|sprint-check|tools/sprint-check-win.exe|1|0
sprint-headless-json-win|tools/sprint-headless-json-go|sprint-headless-json-windows-amd64|sprint-headless-json-windows-amd64.exe|sprint-headless-json|tools/sprint-headless-json-win.exe|0|0"
else
  COMPONENTS="cockpit-daemon|tools/cockpit-daemon|$os-$arch|cockpit-daemon-$os-$arch|cockpit-daemon|tools/cockpit-daemon/cockpit-daemon|1|1"
fi

rc=0
while IFS='|' read -r LABEL SRC TARGET ASSET TAG rel required VERSION_CHECK; do
  [ -n "$LABEL" ] || continue
  DEST="$REPO/$rel"
  if [ "$os" = windows ]; then NEXT="run canon update (or the installer again) once online"
  else NEXT="install Go (brew install go, or https://go.dev/dl) and run: canon update
  or build it by hand: cd \"$DAEMON_DIR\" && go build -o cockpit-daemon ."; fi
  if ! fetch_one; then
    if [ "$required" = 1 ]; then rc=1; fi
  fi
  cleanup; tmp=""   # a failed source build or move must not leave its temp file for the next component (or in the clone, where git would call it dirty)
done <<EOF
$COMPONENTS
EOF
exit "$rc"
