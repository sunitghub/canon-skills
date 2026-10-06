#!/usr/bin/env bash
# release-daemon.sh — build the macOS/Linux cockpit-daemon binaries, publish them as a GitHub release on canon-skills and record
# their SHA-256 in tools/cockpit-daemon.sha256 (t-60f7). Maintainer step: run it after the daemon source is committed and before
# the manifest (and the commit that carries it) is pushed to public, because installs verify what they download against it.
# Usage: scripts/release-daemon.sh [--dry-run]   (--dry-run builds and prints the manifest lines, publishes and writes nothing)
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RELEASE_REPO="${CANON_DAEMON_RELEASE_REPO:-sunitghub/canon-skills}"
MANIFEST="$REPO_ROOT/tools/cockpit-daemon.sha256"
TARGETS="darwin-arm64 darwin-amd64 linux-amd64 linux-arm64"
dry=0; [ "${1:-}" = --dry-run ] && dry=1

command -v go >/dev/null 2>&1 || { echo "release-daemon: go is required" >&2; exit 1; }
if [ "$dry" = 0 ]; then command -v gh >/dev/null 2>&1 || { echo "release-daemon: gh is required (gh auth login)" >&2; exit 1; }; fi
[ -z "$(git -C "$REPO_ROOT" status --porcelain -- tools/cockpit-daemon)" ] || { echo "release-daemon: tools/cockpit-daemon has uncommitted changes; commit them first so the release names real source" >&2; exit 1; }

full="$(git -C "$REPO_ROOT" log -1 --format=%H -- tools/cockpit-daemon)"
key="${full:0:12}"; stamp="${full:0:8}"
semver="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION")"
tag="cockpit-daemon-$key"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

lines=""
for t in $TARGETS; do
  ( cd "$REPO_ROOT/tools/cockpit-daemon" && CGO_ENABLED=0 GOOS="${t%-*}" GOARCH="${t#*-}" go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=$semver -X main.commit=$stamp" -o "$out/cockpit-daemon-$t" . )
  lines="$lines$key $t $(sha256_of "$out/cockpit-daemon-$t")"$'\n'
done
cp "$REPO_ROOT/THIRD-PARTY-NOTICES.md" "$out/THIRD-PARTY-NOTICES.md"

if [ "$dry" = 1 ]; then printf '%s' "$lines"; echo "release-daemon: dry run for $tag, nothing published or written"; exit 0; fi

if ! gh release view "$tag" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release create "$tag" --repo "$RELEASE_REPO" --target main --title "cockpit-daemon $key" \
    --notes "Prebuilt cockpit daemon for daemon source commit $full. Fetched and checksum-verified by tools/fetch-daemon.sh; see THIRD-PARTY-NOTICES.md." \
    "$out"/cockpit-daemon-* "$out/THIRD-PARTY-NOTICES.md"
fi

# Prove what users will download: fetch every asset back from the release and compare with what was built.
chk="$(mktemp -d)"; trap 'rm -rf "$out" "$chk"' EXIT
gh release download "$tag" --repo "$RELEASE_REPO" --dir "$chk" --pattern 'cockpit-daemon-*'
for t in $TARGETS; do
  [ -f "$chk/cockpit-daemon-$t" ] || { echo "release-daemon: asset cockpit-daemon-$t is missing from $tag; manifest not written" >&2; exit 1; }
  [ "$(sha256_of "$chk/cockpit-daemon-$t")" = "$(sha256_of "$out/cockpit-daemon-$t")" ] \
    || { echo "release-daemon: asset cockpit-daemon-$t on $tag differs from this build; delete the release and rerun. Manifest not written" >&2; exit 1; }
done

{ grep -v "^$key " "$MANIFEST" || true; printf '%s' "$lines"; } > "$MANIFEST.new" && mv "$MANIFEST.new" "$MANIFEST"
echo "release-daemon: published $tag and updated tools/cockpit-daemon.sha256; commit it, then push to public"
