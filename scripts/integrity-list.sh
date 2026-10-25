#!/usr/bin/env bash
# integrity-list.sh — the file list a release carries for Admin > Integrity (t-2af0).
#   scripts/integrity-list.sh <vX.Y.Z> <output-folder> [<rev>]
# Writes <output-folder>/integrity-X.Y.Z.json from the committed tree of <rev> (default: the tag), the same bytes `git archive` puts in
# the release zip, and prints one line, `<tag> <sha256 of that file>`, which is what getcanon.dev/integrity.txt carries. The list is NOT
# a fourth field of releases.txt: both release-manifest.sh and install.ps1 read a line there as exactly three fields, so a fourth would hide
# the release from every installed canon. The file has the tag, its commit, `path -> sha256` for every file (one per line), and which paths
# are gate files and gate prompts (the ones whose change blocks `sprint complete`). A path outside [A-Za-z0-9._/@+-] fails the build: the
# JSON is hand-written, and an odd name is something to see before it ships. scripts/release.sh calls this; docs/releasing.md has the pipeline.
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
die() { echo "integrity-list: $*" >&2; exit 1; }

tag="${1-}"; out="${2-}"; rev="${3-}"
re='^v[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$tag" =~ $re ]] || die "tag must look like v0.3.0 (got '$tag')"
[ -n "$out" ] && [ -d "$out" ] || die "output folder '$out' does not exist"
version="${tag#v}"
[ -n "$rev" ] || rev="refs/tags/$tag"
commit="$(git -C "$REPO_ROOT" rev-parse -q --verify "$rev^{commit}" 2>/dev/null)" || die "'$rev' does not exist here"

if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "no sha256sum or shasum on this machine"; fi

# The seven files that decide a close or choose who grades it, and the prompts and protocol the gates read. One owner: the Go check
# reads these lists from the signed-off JSON, never from the install it is checking.
GATE_FILES=(tools/sprint tools/gate-snapshot.sh tools/subagent-log.sh tools/evidence.sh tools/sprint-headless tools/sprint-headless-eval tools/gate-model.sh)
GATE_PROMPTS=(agents/canon-reviewer.md agents/canon-evaluator.md skills/sprint/reference/review.md skills/sprint/reference/eval.md skills/sprint/reference/shared-gate-protocol.md)

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
git -C "$REPO_ROOT" archive --format=tar "$rev" | tar -x -C "$work" || die "git archive failed for $rev"
rows="$work.rows"; : > "$rows"
while IFS= read -r -d '' f; do
  p="${f#./}"
  [[ "$p" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "the path '$p' has a character the list does not allow"
  printf '%s %s\n' "$(sha "$work/$p")" "$p" >> "$rows"
done < <(cd "$work" && find . -type f -print0 | LC_ALL=C sort -z)
[ -s "$rows" ] || die "the tree of $rev has no files"
for g in "${GATE_FILES[@]}" "${GATE_PROMPTS[@]}"; do grep -q " $g\$" "$rows" || { rm -f "$rows"; die "gate path '$g' is not in the tree of $rev"; }; done

json="$out/integrity-$version.json"
{
  printf '{\n"tag": "%s",\n"commit": "%s",\n' "$tag" "$commit"
  printf '"gate_files": ['; sep=""; for g in "${GATE_FILES[@]}"; do printf '%s"%s"' "$sep" "$g"; sep=", "; done; printf '],\n'
  printf '"gate_prompts": ['; sep=""; for g in "${GATE_PROMPTS[@]}"; do printf '%s"%s"' "$sep" "$g"; sep=", "; done; printf '],\n'
  printf '"files": {\n'
  awk '{ printf "%s\"%s\": \"%s\"", (NR > 1 ? ",\n" : ""), $2, $1 } END { printf "\n" }' "$rows"
  printf '}\n}\n'
} > "$json"
rm -f "$rows"
printf '%s %s\n' "$tag" "$(sha "$json")"
