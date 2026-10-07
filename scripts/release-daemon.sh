#!/usr/bin/env bash
# release-daemon.sh — build canon's prebuilt binaries, publish them as GitHub releases on canon-skills and record their SHA-256
# in tools/cockpit-daemon.sha256 (t-60f7, t-9383). Maintainer step: run it after the source is committed and before the manifest
# (and the commit that carries it) is pushed to public, because installs verify what they download against it.
#   cockpit-daemon  macOS + Linux (4 targets) and Windows amd64   release cockpit-daemon-<key of tools/cockpit-daemon>
#   board           Windows amd64   (tools/sprint-check-win.exe)           release sprint-check-<key of tools/sprint-check-go>
#   headless helper Windows amd64   (tools/sprint-headless-json-win.exe)   release sprint-headless-json-<key of its source>
# Every build uses -trimpath -buildvcs=false, so the same source gives the same bytes at any checkout path. A release that exists
# keeps its assets (a published asset is never overwritten); missing ones are added.
# Usage: scripts/release-daemon.sh [--dry-run]   (--dry-run builds and prints the manifest lines, publishes and writes nothing)
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RELEASE_REPO="${CANON_DAEMON_RELEASE_REPO:-sunitghub/canon-skills}"
MANIFEST="$REPO_ROOT/tools/cockpit-daemon.sha256"
UNIX_TARGETS="darwin-arm64 darwin-amd64 linux-amd64 linux-arm64"
dry=0; [ "${1:-}" = --dry-run ] && dry=1

command -v go >/dev/null 2>&1 || { echo "release-daemon: go is required" >&2; exit 1; }
if [ "$dry" = 0 ]; then command -v gh >/dev/null 2>&1 || { echo "release-daemon: gh is required (gh auth login)" >&2; exit 1; }; fi
for d in tools/cockpit-daemon tools/sprint-check-go tools/sprint-headless-json-go; do
  [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$d")" ] || { echo "release-daemon: $d has uncommitted changes; commit them first so the release names the source it was built from" >&2; exit 1; }
done

tree_of() { git -C "$REPO_ROOT" rev-parse "HEAD:$1"; }   # the source folder's tree hash: the same name tools/fetch-daemon.sh computes in any clone
full_d="$(tree_of tools/cockpit-daemon)"; key_d="${full_d:0:12}"
full_b="$(tree_of tools/sprint-check-go)"; key_b="${full_b:0:12}"
full_h="$(tree_of tools/sprint-headless-json-go)"; key_h="${full_h:0:12}"
semver="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION")"
out="$(mktemp -d)"; chk=""; trap 'rm -rf "$out" "$chk"' EXIT

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# Build everything first; nothing is published until every build has worked.
lines=""   # <key> <target> <sha256>
for t in $UNIX_TARGETS; do
  ( cd "$REPO_ROOT/tools/cockpit-daemon" && CGO_ENABLED=0 GOOS="${t%-*}" GOARCH="${t#*-}" go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=$semver -X main.commit=${full_d:0:8}" -o "$out/cockpit-daemon-$t" . )
  lines="$lines$key_d $t $(sha256_of "$out/cockpit-daemon-$t")"$'\n'
done
( cd "$REPO_ROOT/tools/cockpit-daemon" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -buildvcs=false \
    -ldflags "-s -w -X main.version=$semver -X main.commit=${full_d:0:8}" -o "$out/cockpit-daemon-windows-amd64.exe" . )
lines="$lines$key_d windows-amd64 $(sha256_of "$out/cockpit-daemon-windows-amd64.exe")"$'\n'
# The board and the headless helper are legacy packages (no go.mod, stdlib only). GOPATH-mode builds leak the checkout path
# into the binary even with -trimpath (live-checked: three checkouts gave three hashes), so build them as a module from a
# staged copy of their sources: same code, a fixed module path, and the same bytes anywhere.
build_legacy() { # <source dir under the repo> <module name> <commit stamp> <output file>
  local stage; stage="$(mktemp -d)"
  find "$REPO_ROOT/$1" -maxdepth 1 -name '*.go' ! -name '*_test.go' -exec cp {} "$stage/" \;
  printf 'module canon/%s\n\ngo %s\n' "$2" "$(go env GOVERSION | sed 's/^go//')" > "$stage/go.mod"
  ( cd "$stage" && GOTOOLCHAIN=local GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=$semver -X main.commit=$3" -o "$4" . )
  rm -rf "$stage"
}
build_legacy tools/sprint-check-go sprint-check "${full_b:0:8}" "$out/sprint-check-windows-amd64.exe"
lines="$lines$key_b sprint-check-windows-amd64 $(sha256_of "$out/sprint-check-windows-amd64.exe")"$'\n'
build_legacy tools/sprint-headless-json-go sprint-headless-json "${full_h:0:8}" "$out/sprint-headless-json-windows-amd64.exe"
lines="$lines$key_h sprint-headless-json-windows-amd64 $(sha256_of "$out/sprint-headless-json-windows-amd64.exe")"$'\n'
cp "$REPO_ROOT/THIRD-PARTY-NOTICES.md" "$out/THIRD-PARTY-NOTICES.md"

if [ "$dry" = 1 ]; then printf '%s' "$lines"; echo "release-daemon: dry run for cockpit-daemon-$key_d, sprint-check-$key_b, sprint-headless-json-$key_h; nothing published or written"; exit 0; fi

# publish <tag> <full source hash> <asset file name>... : create the release if absent, else add only the assets it lacks.
publish() {
  local tag="$1" full="$2" have f; shift 2
  if ! gh release view "$tag" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$RELEASE_REPO" --target main --title "$tag" \
      --notes "Prebuilt binaries for source tree $full. Fetched and checksum-verified by tools/fetch-daemon.sh; see THIRD-PARTY-NOTICES.md." \
      "$@" "$out/THIRD-PARTY-NOTICES.md"
    return
  fi
  have="$(gh release view "$tag" --repo "$RELEASE_REPO" --json assets -q '.assets[].name')"
  for f in "$@"; do
    printf '%s\n' "$have" | grep -qx "$(basename "$f")" || gh release upload "$tag" "$f" --repo "$RELEASE_REPO"
  done
}
publish "cockpit-daemon-$key_d" "$full_d" "$out"/cockpit-daemon-darwin-* "$out"/cockpit-daemon-linux-* "$out/cockpit-daemon-windows-amd64.exe"
publish "sprint-check-$key_b" "$full_b" "$out/sprint-check-windows-amd64.exe"
publish "sprint-headless-json-$key_h" "$full_h" "$out/sprint-headless-json-windows-amd64.exe"

# Prove what users will download: fetch every asset back from its release and compare with what was built.
chk="$(mktemp -d)"
verify() { # <tag> <asset>
  gh release download "$1" --repo "$RELEASE_REPO" --dir "$chk" --pattern "$2" --clobber
  [ -f "$chk/$2" ] || { echo "release-daemon: asset $2 is missing from $1; manifest not written" >&2; exit 1; }
  [ "$(sha256_of "$chk/$2")" = "$(sha256_of "$out/$2")" ] \
    || { echo "release-daemon: asset $2 on $1 differs from this build (a published asset is never overwritten; delete the release and rerun). Manifest not written" >&2; exit 1; }
}
for t in $UNIX_TARGETS; do verify "cockpit-daemon-$key_d" "cockpit-daemon-$t"; done
verify "cockpit-daemon-$key_d" "cockpit-daemon-windows-amd64.exe"
verify "sprint-check-$key_b" "sprint-check-windows-amd64.exe"
verify "sprint-headless-json-$key_h" "sprint-headless-json-windows-amd64.exe"

# Replace any earlier line for the same key and target, then append: the newest line for a target is the last one.
tmpm="$MANIFEST.new"; cp "$MANIFEST" "$tmpm"
while read -r k t _; do
  [ -n "$k" ] || continue
  grep -v "^$k $t " "$tmpm" > "$tmpm.2" || true; mv "$tmpm.2" "$tmpm"
done <<EOF
$lines
EOF
printf '%s' "$lines" >> "$tmpm"; mv "$tmpm" "$MANIFEST"
echo "release-daemon: published cockpit-daemon-$key_d, sprint-check-$key_b, sprint-headless-json-$key_h and updated tools/cockpit-daemon.sha256; commit it, then push to public"
