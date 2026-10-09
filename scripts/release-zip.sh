#!/usr/bin/env bash
# release-zip.sh — build a release's zip and print its manifest line (t-34f1).
#   scripts/release-zip.sh <vX.Y.Z> <output-folder>
# Writes <output-folder>/canon-X.Y.Z.zip from the tag's COMMITTED tree (top folder canon-X.Y.Z/; working-tree changes never enter it),
# and prints one line, `<tag> <zip sha256> <tag commit sha>`, which is what getcanon.dev/releases.txt carries. The zip is a release asset
# because GitHub's own archive zips are not byte-stable. `git archive` output is normally reproducible, but the hash that counts is the uploaded file's: a rebuild with a different git may differ, so publish the line the rebuild prints.
# scripts/release.sh calls this and attaches the zip; docs/releasing.md has the whole pipeline.
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
die() { echo "release-zip: $*" >&2; exit 1; }

tag="${1-}"; out="${2-}"
re='^v[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$tag" =~ $re ]] || die "tag must look like v0.3.0 (got '$tag')"
[ -n "$out" ] && [ -d "$out" ] || die "output folder '$out' does not exist"
version="${tag#v}"

commit="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)" || die "tag $tag does not exist here"

if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "no sha256sum or shasum on this machine"; fi

zip="$out/canon-$version.zip"
git -C "$REPO_ROOT" archive --format=zip --prefix="canon-$version/" -o "$zip" "refs/tags/$tag" || { rm -f "$zip"; die "git archive failed for $tag"; }
printf '%s %s %s\n' "$tag" "$(sha "$zip")" "$commit"
