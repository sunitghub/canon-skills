#!/usr/bin/env bash
# release-daemon.sh — build canon's prebuilt program, publish it as a GitHub release on canon-skills and record its SHA-256
# in tools/cockpit-daemon.sha256 (t-60f7, t-9383, t-bdb0). Maintainer step: run it after the source is committed and before the manifest
# (and the commit that carries it) is pushed to public, because installs verify what they download against it.
#   canon-go  macOS + Linux (4 targets) and Windows amd64   release canon-go-<key>, assets canon-go-<os>-<arch>[.exe]
# canon-go is one program (tools/canon-go/cmd/canon-go) holding the board and the daemon (t-bdb0); its key is tools/src-key.sh's
# `canon-go` key (the hash of the daemon and board part keys), and every build stamps the daemon part's key (-X main.daemonKey) so a
# board-only release does not mark a running daemon stale. Manifest lines are `<key> canon-go-<target> <sha256>`, appended: the lines
# of the older cockpit-daemon-* and sprint-check-* releases stay, because older trees still fetch those (never deleted) assets.
# Every build uses -trimpath -buildvcs=false, so the same source gives the same bytes at any checkout path. A release that exists
# keeps its assets (a published asset is never overwritten); missing ones are added. No build carries VERSION (t-0859): the
# binaries read it from the install at run time, so a version bump leaves every key's bytes unchanged. A release that already
# existed before this run is recorded from its published asset, not rebuild-compared (t-7f09); a new one must equal its build.
# The Go toolchain is pinned, not whatever is installed: tools/canon-go/go.mod has a `toolchain` line (t-b62a retired the headless helper and
# its GO_TOOLCHAIN file). Every build sets GOTOOLCHAIN to the pin explicitly (go.mod's `toolchain` line is only a minimum, and an
# exported GOTOOLCHAIN=local would ignore it), and every built binary is checked with `go version -m` against the pin before anything is published. The pin lives in go.mod on purpose: raising it changes the key (go.mod is in it, tools/src-key.sh), so the fixed
# build is a NEW release and the old release (which an older tag's manifest still points at) keeps its assets (t-7efe).
# Usage: scripts/release-daemon.sh [--dry-run]   (--dry-run builds and prints the manifest lines, publishes and writes nothing)
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RELEASE_REPO="${CANON_DAEMON_RELEASE_REPO:-sunitghub/canon-skills}"
MANIFEST="$REPO_ROOT/tools/cockpit-daemon.sha256"
UNIX_TARGETS="darwin-arm64 darwin-amd64 linux-amd64 linux-arm64"
dry=0; [ "${1:-}" = --dry-run ] && dry=1

command -v go >/dev/null 2>&1 || { echo "release-daemon: go is required" >&2; exit 1; }
if [ "$dry" = 0 ]; then command -v gh >/dev/null 2>&1 || { echo "release-daemon: gh is required (gh auth login)" >&2; exit 1; }; fi
[ -z "$(git -C "$REPO_ROOT" status --porcelain -- tools/canon-go)" ] || { echo "release-daemon: tools/canon-go has uncommitted changes; commit them first so the release names the source it was built from" >&2; exit 1; }

# shellcheck source=tools/src-key.sh
source "$REPO_ROOT/tools/src-key.sh"   # the key and the stamps: the same names tools/fetch-daemon.sh computes in any clone
full="$(canon_src_key "$REPO_ROOT" canon-go)" && stamps="$(canon_ldflags "$REPO_ROOT")" \
  || { echo "release-daemon: cannot name the canon-go source at HEAD (tools/src-key.sh)" >&2; exit 1; }
key="${full:0:12}"
MODULE="$REPO_ROOT/tools/canon-go"
out="$(mktemp -d)"; chk=""; trap 'rm -rf "$out" "$chk"' EXIT

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

pin_re='^go[0-9]+\.[0-9]+\.[0-9]+$'
module_pin="$(awk '/^toolchain /{print $2}' "$MODULE/go.mod" 2>/dev/null)" || module_pin=""
[[ "$module_pin" =~ $pin_re ]] || { echo "release-daemon: tools/canon-go/go.mod needs a line 'toolchain goX.Y.Z' naming the Go to build with, e.g. toolchain go1.27.2" >&2; exit 1; }
check_built() { # <binary> <pin>: the file must say it was built with exactly the pinned Go
  local got; got="$(go version -m "$1" 2>/dev/null)" || got=""; got="${got%%$'\n'*}"   # whole output, then its first line: head -n1 in the pipe SIGPIPEs go under pipefail (t-90bc)
  [[ "$got" == "$1: $2" ]] || { echo "release-daemon: $(basename "$1") was built with '${got##*: }', not the pinned $2; nothing was published" >&2; exit 1; }
}

# Build everything first; nothing is published until every build has worked.
lines=""   # <key> <target> <sha256>
build_module() { # <goos-goarch> <output file>: canon-go for one target, stamped (canon_ldflags), with its pin
  ( cd "$MODULE" && GOTOOLCHAIN="$module_pin" CGO_ENABLED=0 GOOS="${1%-*}" GOARCH="${1#*-}" go build -trimpath -buildvcs=false \
      -ldflags "-s -w $stamps" -o "$2" ./cmd/canon-go )
  check_built "$2" "$module_pin"
}
for t in $UNIX_TARGETS; do
  build_module "$t" "$out/canon-go-$t"
  lines="$lines$key canon-go-$t $(sha256_of "$out/canon-go-$t")"$'\n'
done
build_module windows-amd64 "$out/canon-go-windows-amd64.exe"
lines="$lines$key canon-go-windows-amd64 $(sha256_of "$out/canon-go-windows-amd64.exe")"$'\n'
cp "$REPO_ROOT/THIRD-PARTY-NOTICES.md" "$out/THIRD-PARTY-NOTICES.md"

if [ "$dry" = 1 ]; then printf '%s' "$lines"; echo "release-daemon: dry run for canon-go-$key; nothing published or written"; exit 0; fi

# Whether the release existed before this run: its assets were published from an earlier build and are never replaced.
ex=0; if gh release view "canon-go-$key" --repo "$RELEASE_REPO" >/dev/null 2>&1; then ex=1; fi

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
    grep -qx "$(basename "$f")" <<<"$have" || gh release upload "$tag" "$f" --repo "$RELEASE_REPO"
  done
}
publish "canon-go-$key" "$full" "$out"/canon-go-darwin-* "$out"/canon-go-linux-* "$out/canon-go-windows-amd64.exe"

# Prove what users will download: fetch every asset back and record its hash. An asset of a release created in this run
# must equal this build. An existing release's asset is recorded as published (t-7f09: an earlier build, or one made before
# t-0859 took VERSION out of the bytes, need not match today's); only a manifest line that names another hash for it fails.
chk="$(mktemp -d)"; final=""   # <key> <target> <sha256> of what users will download
record() { # <key> <target> <tag> <asset> <existed 0|1>
  local got built want
  gh release download "$3" --repo "$RELEASE_REPO" --dir "$chk" --pattern "$4" --clobber
  [ -f "$chk/$4" ] || { echo "release-daemon: asset $4 is missing from $3; manifest not written" >&2; exit 1; }
  got="$(sha256_of "$chk/$4")"; built="$(sha256_of "$out/$4")"
  if [ "$5" = 1 ]; then
    want="$(awk -v k="$1" -v t="$2" '$1 == k && $2 == t { h = $3 } END { print h }' "$MANIFEST")"
    [ -z "$want" ] || [ "$want" = "$got" ] \
      || { echo "release-daemon: asset $4 on $3 hashes $got, but tools/cockpit-daemon.sha256 records $want for $1 $2; manifest not written" >&2; exit 1; }
    [ "$got" = "$built" ] || echo "release-daemon: warning: $4 on $3 (an existing release) differs from this build; the manifest records the published asset" >&2
  else
    [ "$got" = "$built" ] \
      || { echo "release-daemon: asset $4 on $3 differs from this build (a published asset is never overwritten; delete the release and rerun). Manifest not written" >&2; exit 1; }
  fi
  final="$final$1 $2 $got"$'\n'
}
for t in $UNIX_TARGETS; do record "$key" "canon-go-$t" "canon-go-$key" "canon-go-$t" "$ex"; done
record "$key" canon-go-windows-amd64 "canon-go-$key" canon-go-windows-amd64.exe "$ex"

# Replace any earlier line for the same key and target, then append: the newest line for a target is the last one.
tmpm="$MANIFEST.new"; cp "$MANIFEST" "$tmpm"
while read -r k t _; do
  [ -n "$k" ] || continue
  grep -v "^$k $t " "$tmpm" > "$tmpm.2" || true; mv "$tmpm.2" "$tmpm"
done <<EOF
$final
EOF
printf '%s' "$final" >> "$tmpm"; mv "$tmpm" "$MANIFEST"
echo "release-daemon: published canon-go-$key and updated tools/cockpit-daemon.sha256; commit it, run scripts/check-binaries-released.sh --download, then push to public"
