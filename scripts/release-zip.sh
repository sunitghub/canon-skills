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

# What an end user's zip leaves out (t-3954): nothing in the install reads these. Git installs (a clone) keep everything. One list, here.
# A new top-level folder ships unless it is named here; docs/releasing.md says why each of these is safe, and tests/release-zip-slim.sh
# fails if a file the install reads falls under this list.
#   tests/                    canon's own tests (the many tests/ mentions in tools/ are about the USER's project)
#   meta/                     README screenshots and GIFs, EXCEPT the images the board's product tour shows (keep_shots below)
#   tools/canon-go/{cmd,internal}   the Go source: a zip install picks its prebuilt binary from the release manifest, never the source;
#                                   go.mod and go.sum stay (tools/cloud-env.sh reads the pinned toolchain from go.mod)
#   tools/vendored.tsv, tools/sprint-check-app/CLAUDE.md   read only by canon's own CI (check-vendored) and its developers (t-7299)
SLIM_EXCLUDE=(tests tools/canon-go/cmd tools/canon-go/internal tools/vendored.tsv tools/sprint-check-app/CLAUDE.md)
tag_ref="refs/tags/$tag"
keep_shots=""   # the screenshots the board's page names, read from the same tag so the list cannot drift from app.html
if git -C "$REPO_ROOT" cat-file -e "$tag_ref:tools/sprint-check-app/app.html" 2>/dev/null; then
  keep_shots="$(git -C "$REPO_ROOT" show "$tag_ref:tools/sprint-check-app/app.html" | grep -o 'src="/meta/screenshots/[A-Za-z0-9_.-]*"' | sed 's#.*/##; s#"$##' | sort -u || true)"
fi
exclude=()
for p in "${SLIM_EXCLUDE[@]}"; do exclude+=(":(exclude)$p"); done
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in *[!A-Za-z0-9._/@+-]*) die "a path under meta/ has a character the slim list cannot name: $f" ;; esac
  base="${f##*/}"
  if [ "${f%/*}" = "meta/screenshots" ]; then case $'\n'"$keep_shots"$'\n' in *$'\n'"$base"$'\n'*) continue ;; esac; fi
  exclude+=(":(exclude)$f")
done < <(git -C "$REPO_ROOT" ls-tree -r --name-only "$tag_ref" -- meta 2>/dev/null)

zip="$out/canon-$version.zip"
git -C "$REPO_ROOT" archive --format=zip --prefix="canon-$version/" -o "$zip" "$tag_ref" -- . "${exclude[@]}" || { rm -f "$zip"; die "git archive failed for $tag"; }
printf '%s %s %s\n' "$tag" "$(sha "$zip")" "$commit"
