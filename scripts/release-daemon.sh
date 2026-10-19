#!/usr/bin/env bash
# release-daemon.sh — build canon's prebuilt binaries, publish them as GitHub releases on canon-skills and record their SHA-256
# in tools/cockpit-daemon.sha256 (t-60f7, t-9383). Maintainer step: run it after the source is committed and before the manifest
# (and the commit that carries it) is pushed to public, because installs verify what they download against it.
#   cockpit-daemon  macOS + Linux (4 targets) and Windows amd64   release cockpit-daemon-<its key>
#   board           macOS + Linux (4 targets, t-15d8) and Windows amd64 (tools/sprint-check-win.exe)   release sprint-check-<its key>
#   headless helper Windows amd64   (tools/sprint-headless-json-win.exe)   release sprint-headless-json-<its key>
# The daemon and the board are one Go module, tools/canon-go (t-8020), built from cmd/cockpit-daemon and cmd/sprint-check; each key
# covers only the paths that binary is built from (tools/src-key.sh), so a board-only change does not re-release the daemon.
# Every build uses -trimpath -buildvcs=false, so the same source gives the same bytes at any checkout path. A release that exists
# keeps its assets (a published asset is never overwritten); missing ones are added. No build carries VERSION (t-0859): the
# binaries read it from the install at run time, so a version bump leaves every key's bytes unchanged. A release that already
# existed before this run is recorded from its published asset, not rebuild-compared (t-7f09); a new one must equal its build.
# The Go toolchain is pinned, not whatever is installed: tools/canon-go/go.mod has a `toolchain` line, and the legacy headless helper has a
# GO_TOOLCHAIN file in its folder. Every build sets GOTOOLCHAIN to its pin explicitly (go.mod's `toolchain` line is only a minimum, and an
# exported GOTOOLCHAIN=local would ignore it), and every built binary is checked with `go version -m` against the pin before anything is published. A pin lives in the source folder on purpose: raising it changes the folder's tree hash, so the fixed
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
for d in tools/canon-go tools/sprint-headless-json-go; do
  [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$d")" ] || { echo "release-daemon: $d has uncommitted changes; commit them first so the release names the source it was built from" >&2; exit 1; }
done

# shellcheck source=tools/src-key.sh
source "$REPO_ROOT/tools/src-key.sh"   # each component's key: the same name tools/fetch-daemon.sh computes in any clone
src_key() { canon_src_key "$REPO_ROOT" "$1" || { echo "release-daemon: cannot name the $1 source at HEAD (tools/src-key.sh)" >&2; exit 1; }; }
full_d="$(src_key cockpit-daemon)"; key_d="${full_d:0:12}"
full_b="$(src_key sprint-check)"; key_b="${full_b:0:12}"
full_h="$(src_key sprint-headless-json)"; key_h="${full_h:0:12}"
MODULE="$REPO_ROOT/tools/canon-go"
out="$(mktemp -d)"; chk=""; trap 'rm -rf "$out" "$chk"' EXIT

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

pin_re='^go[0-9]+\.[0-9]+\.[0-9]+$'
daemon_pin="$(awk '/^toolchain /{print $2}' "$MODULE/go.mod" 2>/dev/null)" || daemon_pin=""
[[ "$daemon_pin" =~ $pin_re ]] || { echo "release-daemon: tools/canon-go/go.mod needs a line 'toolchain goX.Y.Z' naming the Go to build with, e.g. toolchain go1.27.2" >&2; exit 1; }
check_built() { # <binary> <pin>: the file must say it was built with exactly the pinned Go
  local got; got="$(go version -m "$1" 2>/dev/null)" || got=""; got="${got%%$'\n'*}"   # whole output, then its first line: head -n1 in the pipe SIGPIPEs go under pipefail (t-90bc)
  [[ "$got" == "$1: $2" ]] || { echo "release-daemon: $(basename "$1") was built with '${got##*: }', not the pinned $2; nothing was published" >&2; exit 1; }
}

# Build everything first; nothing is published until every build has worked.
lines=""   # <key> <target> <sha256>
build_module() { # <cmd name> <commit stamp> <goos-goarch> <output file>: one binary from the canon-go module, with its pin
  ( cd "$MODULE" && GOTOOLCHAIN="$daemon_pin" CGO_ENABLED=0 GOOS="${3%-*}" GOARCH="${3#*-}" go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.commit=$2" -o "$4" "./cmd/$1" )
  check_built "$4" "$daemon_pin"
}
for t in $UNIX_TARGETS; do
  build_module cockpit-daemon "${full_d:0:8}" "$t" "$out/cockpit-daemon-$t"
  lines="$lines$key_d $t $(sha256_of "$out/cockpit-daemon-$t")"$'\n'
done
build_module cockpit-daemon "${full_d:0:8}" windows-amd64 "$out/cockpit-daemon-windows-amd64.exe"
lines="$lines$key_d windows-amd64 $(sha256_of "$out/cockpit-daemon-windows-amd64.exe")"$'\n'
# The headless helper is a legacy package (no go.mod, stdlib only; the board was one until t-8020). GOPATH-mode builds leak the
# checkout path into the binary even with -trimpath (live-checked: three checkouts gave three hashes), so build it as a module from
# a staged copy of its sources: same code, a fixed module path, and the same bytes anywhere.
build_legacy() { # <source dir under the repo> <module name> <commit stamp> <output file> [<goos-goarch>, default windows-amd64]
  local stage pin t="${5:-windows-amd64}"
  pin="$(tr -d ' \t\n\r' < "$REPO_ROOT/$1/GO_TOOLCHAIN" 2>/dev/null)" || pin=""
  [[ "$pin" =~ $pin_re ]] || { echo "release-daemon: $1/GO_TOOLCHAIN must name the Go toolchain to build with, e.g. go1.27.2" >&2; exit 1; }
  stage="$(mktemp -d)"
  find "$REPO_ROOT/$1" -maxdepth 1 -name '*.go' ! -name '*_test.go' -exec cp {} "$stage/" \;
  printf 'module canon/%s\n\ngo %s\n' "$2" "${pin#go}" > "$stage/go.mod"
  ( cd "$stage" && GOTOOLCHAIN="$pin" GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS="${t%-*}" GOARCH="${t#*-}" go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.commit=$3" -o "$4" . )
  rm -rf "$stage"
  check_built "$4" "$pin"
}
for t in $UNIX_TARGETS; do   # t-15d8: the Go board is the only board on macOS/Linux too
  build_module sprint-check "${full_b:0:8}" "$t" "$out/sprint-check-$t"
  lines="$lines$key_b sprint-check-$t $(sha256_of "$out/sprint-check-$t")"$'\n'
done
build_module sprint-check "${full_b:0:8}" windows-amd64 "$out/sprint-check-windows-amd64.exe"
lines="$lines$key_b sprint-check-windows-amd64 $(sha256_of "$out/sprint-check-windows-amd64.exe")"$'\n'
build_legacy tools/sprint-headless-json-go sprint-headless-json "${full_h:0:8}" "$out/sprint-headless-json-windows-amd64.exe"
lines="$lines$key_h sprint-headless-json-windows-amd64 $(sha256_of "$out/sprint-headless-json-windows-amd64.exe")"$'\n'
cp "$REPO_ROOT/THIRD-PARTY-NOTICES.md" "$out/THIRD-PARTY-NOTICES.md"

if [ "$dry" = 1 ]; then printf '%s' "$lines"; echo "release-daemon: dry run for cockpit-daemon-$key_d, sprint-check-$key_b, sprint-headless-json-$key_h; nothing published or written"; exit 0; fi

# Which releases existed before this run: their assets were published from an earlier build and are never replaced.
existed() { gh release view "$1" --repo "$RELEASE_REPO" >/dev/null 2>&1; }
ex_d=0; if existed "cockpit-daemon-$key_d"; then ex_d=1; fi
ex_b=0; if existed "sprint-check-$key_b"; then ex_b=1; fi
ex_h=0; if existed "sprint-headless-json-$key_h"; then ex_h=1; fi

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
publish "sprint-check-$key_b" "$full_b" "$out"/sprint-check-darwin-* "$out"/sprint-check-linux-* "$out/sprint-check-windows-amd64.exe"
publish "sprint-headless-json-$key_h" "$full_h" "$out/sprint-headless-json-windows-amd64.exe"

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
for t in $UNIX_TARGETS; do record "$key_d" "$t" "cockpit-daemon-$key_d" "cockpit-daemon-$t" "$ex_d"; done
record "$key_d" windows-amd64 "cockpit-daemon-$key_d" cockpit-daemon-windows-amd64.exe "$ex_d"
for t in $UNIX_TARGETS; do record "$key_b" "sprint-check-$t" "sprint-check-$key_b" "sprint-check-$t" "$ex_b"; done
record "$key_b" sprint-check-windows-amd64 "sprint-check-$key_b" sprint-check-windows-amd64.exe "$ex_b"
record "$key_h" sprint-headless-json-windows-amd64 "sprint-headless-json-$key_h" sprint-headless-json-windows-amd64.exe "$ex_h"

# Replace any earlier line for the same key and target, then append: the newest line for a target is the last one.
tmpm="$MANIFEST.new"; cp "$MANIFEST" "$tmpm"
while read -r k t _; do
  [ -n "$k" ] || continue
  grep -v "^$k $t " "$tmpm" > "$tmpm.2" || true; mv "$tmpm.2" "$tmpm"
done <<EOF
$final
EOF
printf '%s' "$final" >> "$tmpm"; mv "$tmpm" "$MANIFEST"
echo "release-daemon: published cockpit-daemon-$key_d, sprint-check-$key_b, sprint-headless-json-$key_h and updated tools/cockpit-daemon.sha256; commit it, run scripts/check-binaries-released.sh --download, then push to public"
