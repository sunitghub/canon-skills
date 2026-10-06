#!/usr/bin/env bash
# fetch-daemon.sh — put a verified cockpit-daemon at tools/cockpit-daemon/cockpit-daemon (macOS and Linux; t-60f7).
# Windows ships a committed .exe, so this does nothing there. The binary is gitignored, so a clone has only the source:
# this downloads the prebuilt one published by scripts/release-daemon.sh and runs it only after its SHA-256 equals the line
# for <daemon commit> <target> in tools/cockpit-daemon.sha256 (read from the clone itself). If that is not possible it builds
# from source when Go is new enough, else says what to do. Called by install.sh, `canon update` and `canon`.
# Usage: fetch-daemon.sh [--quiet]     exit 0 = a current daemon is in place, 1 = none could be provided.
# CANON_FETCH_NO_BUILD=1 skips the build-from-source fallback (canon uses it at start so launching the board never compiles).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DAEMON_DIR="$REPO/tools/cockpit-daemon"
BIN="$DAEMON_DIR/cockpit-daemon"
MANIFEST="$SCRIPT_DIR/cockpit-daemon.sha256"
RELEASE_BASE="${CANON_DAEMON_RELEASE_BASE:-https://github.com/sunitghub/canon-skills/releases/download}"
quiet=0; [ "${1:-}" = --quiet ] && quiet=1

say() { echo "cockpit-daemon: $*"; }
die() { echo "cockpit-daemon: $*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) exit 0 ;;   # Windows (Git Bash) uses the committed cockpit-daemon-win.exe
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) die "no prebuilt daemon for CPU '$(uname -m)'. Build it: cd tools/cockpit-daemon && go build -o cockpit-daemon ." ;;
esac
target="$os-$arch"

# The daemon is named by the git tree hash of its source folder: it is the same in a shallow or partial clone and after a history rewrite, unlike the last commit that touched it.
full="$(git -C "$REPO" rev-parse -q --verify HEAD:tools/cockpit-daemon 2>/dev/null)" || full=""
[ -n "$full" ] || die "$REPO is not a git checkout with the daemon source, so the matching binary cannot be named. Reinstall: curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash"
key="${full:0:12}"; stamp="${full:0:8}"

if [ -x "$BIN" ]; then
  have="$("$BIN" --version 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')" || have=""
  if [ -n "$have" ] && [ "${full#"$have"}" != "$full" ]; then
    [ "$quiet" = 1 ] || say "up to date ($have)"
    exit 0
  fi
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

tmp=""
cleanup() { [ -z "$tmp" ] || rm -f -- "$tmp"; }
trap cleanup EXIT

fail_reason=""
# Move the finished temp file into place. mv into an existing directory would "succeed" by nesting the file, so refuse that explicitly.
install_tmp() {
  [ ! -d "$BIN" ] || { fail_reason="$BIN is a directory, not a file"; return 1; }
  chmod 0755 "$tmp" && mv -f -- "$tmp" "$BIN" || { fail_reason="could not move the verified file into place ($BIN)"; return 1; }
  tmp=""
}
try_download() {
  local want got url
  want="$(awk -v k="$key" -v t="$target" '$1==k && $2==t {print $3; exit}' "$MANIFEST" 2>/dev/null)" || want=""
  case "$want" in
    *[!0-9a-f]*|"") fail_reason="no checksum for $target at daemon commit $key in tools/cockpit-daemon.sha256 (not released yet)"; return 1 ;;
  esac
  [ "${#want}" = 64 ] || { fail_reason="the checksum line for $target is malformed"; return 1; }
  command -v curl >/dev/null 2>&1 || { fail_reason="curl is not installed"; return 1; }
  mkdir -p "$DAEMON_DIR"
  tmp="$(mktemp "$DAEMON_DIR/.cockpit-daemon.XXXXXX")"
  url="$RELEASE_BASE/cockpit-daemon-$key/cockpit-daemon-$target"
  curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp" "$url" 2>/dev/null || { fail_reason="download failed ($url)"; return 1; }
  got="$(sha256_of "$tmp")" || { fail_reason="no sha256sum or shasum to verify the download"; return 1; }
  [ "$got" = "$want" ] || { fail_reason="the download does not match its checksum (got ${got:0:12}…, want ${want:0:12}…); it was discarded"; return 1; }
  install_tmp || return 1
  say "fetched $target $key, sha256 verified"
}

build_from_source() {
  [ "${CANON_FETCH_NO_BUILD:-0}" = 1 ] && { fail_reason="$fail_reason (not building from source at start; run canon update)"; return 1; }
  command -v go >/dev/null 2>&1 || { fail_reason="$fail_reason; and Go is not installed to build it"; return 1; }
  local semver; semver="$(tr -d ' \t\n\r' < "$REPO/VERSION" 2>/dev/null)" || semver=dev
  tmp="$(mktemp "$DAEMON_DIR/.cockpit-daemon.XXXXXX")"
  if ( cd "$DAEMON_DIR" && GOTOOLCHAIN=local go build -buildvcs=false -ldflags "-X main.version=$semver -X main.commit=$stamp" -o "$tmp" . ) >/dev/null 2>&1; then
    install_tmp || return 1
    say "built from source ($stamp)"
  else
    fail_reason="$fail_reason; and building from source failed (needs Go $(awk '/^go /{print $2}' "$DAEMON_DIR/go.mod") or newer, found $(go env GOVERSION 2>/dev/null || echo none))"
    return 1
  fi
}

if try_download; then exit 0; fi
# A rejected download is said out loud before anything else is tried, so a checksum mismatch is never hidden by a successful fallback build.
echo "cockpit-daemon: $fail_reason" >&2
cleanup; tmp=""
if build_from_source; then exit 0; fi
die "could not provide a daemon for $target: $fail_reason.
  Next: install Go (brew install go, or https://go.dev/dl) and run: canon update
  or build it by hand: cd \"$DAEMON_DIR\" && go build -o cockpit-daemon ."
