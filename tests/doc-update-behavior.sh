#!/usr/bin/env bash
# doc-update-behavior (t-153f): docs/setup.md's "How canon update works" section says what `canon update` does. This pins it two ways: the section and its
# key facts must exist, and every refusal the docs name must still be a refusal tools/canon (or the manifest tool) really prints, so a deleted guard or a
# reworded message fails here instead of leaving the docs describing behaviour that is gone. The behaviours themselves are proved by tests/canon-update.sh,
# tests/install-sh.sh and tests/release-manifest.sh; this test only keeps the documentation tied to them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
DOC="${DOC_UPDATE_DOC:-$ROOT/docs/setup.md}"; README="${DOC_UPDATE_README:-$ROOT/README.md}"
CANON="${DOC_UPDATE_CANON:-$ROOT/tools/canon}"; MANIFEST="${DOC_UPDATE_MANIFEST:-$ROOT/tools/release-manifest.sh}"

section="$(awk '/^### How canon update works[[:space:]]*$/{f=1;next} f && /^#{1,3} /{exit} f' "$DOC")"
[[ -n "$section" ]] || fail "doc-update-behavior: $DOC has no '### How canon update works' section"

need() {   # need <label> <fixed text the section must contain>
  grep -qF -- "$2" <<<"$section" || fail "doc-update-behavior: the section does not mention $1 ('$2')"
}
need "the manifest URL" "https://getcanon.dev/releases.txt"
need "the marker file" ".canon-track"
need "the main opt-in" "canon update --to main"
need "the way back" "canon update --to latest"
need "that --to vX.Y.Z is not sticky" "not sticky"
need "the line canon version prints on main" "Following main"
need "CANON_REF" "CANON_REF=main"
need "a first install that cannot verify" "installs nothing"
for row in "Made by the installers at v0.4.0 or later" "A Windows zip install" "made before v0.4.0" "pinned at v0.3.0"; do need "the install-type row '$row'" "$row"; done

# every refusal the docs name, with the text the code prints for it
refusal() {   # refusal <doc words> <file> <code text>
  need "the refusal '$1'" "$1"
  grep -qF -- "$3" "$2" || fail "doc-update-behavior: the docs name the refusal '$1' but $(basename "$2") no longer prints '$3'"
}
refusal "uncommitted changes" "$CANON" "has uncommitted changes"
refusal "local commits on \`main\`" "$CANON" "local commit(s) on main"
refusal "another branch than \`main\`" "$CANON" "not main"
refusal "detached commit that is not a release tag" "$CANON" "is not a release tag"
refusal "the manifest cannot be read" "$MANIFEST" "cannot read the release manifest"
refusal "has no release" "$MANIFEST" "lists no release I can read"
grep -qF ".canon-track" "$CANON" || fail "doc-update-behavior: tools/canon no longer uses the .canon-track marker the docs describe"
grep -qF "Following main" "$CANON" || fail "doc-update-behavior: tools/canon no longer prints the 'Following main' line the docs describe"
grep -qF "docs/setup.md#how-canon-update-works" "$README" || fail "doc-update-behavior: the README does not point to the section"
echo "doc-update-behavior: ok (the section, its install-type table, the marker, the refusals and the README pointer match what tools/canon prints)"
