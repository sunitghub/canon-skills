#!/usr/bin/env bash
# check-binaries-released.sh — the push guard for the prebuilt binaries (t-9383, and the "release before push" rule of t-60f7).
# Run it before pushing to public: for every binary canon ships as a release asset, the newest line in tools/cockpit-daemon.sha256
# must carry the git tree hash of that component's CURRENT source folder. A Go change without a re-run of scripts/release-daemon.sh
# leaves the manifest naming an older build, so an install would fetch an exe built from different source (or none).
# Not part of scripts/test.sh on purpose: it is red between a source commit and its release, which is the state it exists to catch.
#   scripts/check-binaries-released.sh              exit 0 = every component is released at HEAD, 1 = names what is not
#   scripts/check-binaries-released.sh --download   also download every asset and compare its SHA-256 with the manifest line
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="$REPO_ROOT/tools/cockpit-daemon.sha256"
RELEASE_BASE="${CANON_DAEMON_RELEASE_BASE:-https://github.com/sunitghub/canon-skills/releases/download}"
download=0; [ "${1:-}" = --download ] && download=1

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

bad=0
# source folder | manifest target | release prefix | asset file name
while IFS='|' read -r src target prefix asset; do
  [ -n "$src" ] || continue
  full="$(git -C "$REPO_ROOT" rev-parse -q --verify "HEAD:$src" 2>/dev/null)" || full=""
  key="${full:0:12}"
  newest="$(tr -d '\r' < "$MANIFEST" | awk -v t="$target" '$2==t {k=$1} END{print k}')"
  if [ -z "$key" ]; then echo "NOT RELEASED  $target: $src is not in this checkout's HEAD" >&2; bad=1; continue; fi
  if [ "$newest" != "$key" ]; then
    echo "NOT RELEASED  $target: $src is at $key but the newest manifest line is ${newest:-missing}; run scripts/release-daemon.sh and commit the manifest" >&2
    bad=1; continue
  fi
  if [ "$download" = 1 ]; then
    want="$(tr -d '\r' < "$MANIFEST" | awk -v k="$key" -v t="$target" '$1==k && $2==t {print $3; exit}')"
    tmp="$(mktemp)"
    if curl -fsSL --connect-timeout 10 --max-time 180 -o "$tmp" "$RELEASE_BASE/$prefix-$key/$asset" 2>/dev/null && [ "$(sha256_of "$tmp")" = "$want" ]; then
      echo "ok            $target ($key): asset downloaded, sha256 matches the manifest"
    else
      echo "BAD ASSET     $target ($key): $RELEASE_BASE/$prefix-$key/$asset is missing or does not match the manifest" >&2; bad=1
    fi
    rm -f "$tmp"
  else
    echo "ok            $target ($key)"
  fi
done <<LIST
tools/cockpit-daemon|darwin-arm64|cockpit-daemon|cockpit-daemon-darwin-arm64
tools/cockpit-daemon|darwin-amd64|cockpit-daemon|cockpit-daemon-darwin-amd64
tools/cockpit-daemon|linux-amd64|cockpit-daemon|cockpit-daemon-linux-amd64
tools/cockpit-daemon|linux-arm64|cockpit-daemon|cockpit-daemon-linux-arm64
tools/cockpit-daemon|windows-amd64|cockpit-daemon|cockpit-daemon-windows-amd64.exe
tools/sprint-check-go|sprint-check-windows-amd64|sprint-check|sprint-check-windows-amd64.exe
tools/sprint-headless-json-go|sprint-headless-json-windows-amd64|sprint-headless-json|sprint-headless-json-windows-amd64.exe
LIST
exit "$bad"
