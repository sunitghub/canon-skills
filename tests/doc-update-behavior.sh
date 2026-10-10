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

section="$(awk '/^### How canon update works[[:space:]]*$/{f=1;next} f && /^#+ /{exit} f' "$DOC")"   # no regex interval: an older mawk would read it literally and run the section to the end of the file
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
need "the plain-update-only detached guard" "a *plain* update finds a detached commit"
need "CANON_REF" "CANON_REF=main"
need "a first install that cannot verify" "installs nothing"
for row in "Made by the installers at v0.4.0 or later" "A Windows zip install" "made before v0.4.0" "pinned at v0.3.0"; do need "the install-type row '$row'" "$row"; done

# every refusal the docs name, with the text the code prints for it. The code text must sit in a PRINTED message (an echo/die/throw line), so the same words in
# a help text or a comment cannot satisfy it (the first version of this check passed with the real guard deleted because the help text said the same).
refusal() {   # refusal <doc words> <file> <how the code prints: a fixed prefix on the line> <code text>
  need "the refusal '$1'" "$1"
  grep -F -- "$3" "$2" | grep -qF -- "$4" || fail "doc-update-behavior: the docs name the refusal '$1' but no '$3' line in $(basename "$2") prints '$4'"
}
PRINT='echo "canon update:'
refusal "has no release" "$MANIFEST" 'die "' "lists no release I can read"
refusal "the manifest cannot be read, has no release" "$MANIFEST" 'die "' "cannot read the release manifest"
refusal "is missing on origin" "$CANON" "$PRINT" "was not found on origin"
refusal "points at a different commit than the manifest says" "$CANON" "$PRINT" "published manifest says"
refusal "has uncommitted changes" "$CANON" "$PRINT" "has uncommitted changes — commit or stash them first"
refusal "local commits on \`main\`" "$CANON" "$PRINT" "local commit(s) on main"
refusal "cannot fast-forward" "$CANON" "$PRINT" "can't fast-forward"
refusal "another branch than \`main\`" "$CANON" "$PRINT" "not main — switch to main first"
refusal "detached commit that is not a release tag" "$CANON" "$PRINT" "that is not a release tag"
refusal "the folder is not a git clone" "$CANON" "$PRINT" "isn't a git clone"
refusal "if canon's daemon is running" "${DOC_UPDATE_PS1:-$ROOT/install.ps1}" 'throw "' "canon's daemon is running"
grep -qF ".canon-track" "$CANON" || fail "doc-update-behavior: tools/canon no longer uses the .canon-track marker the docs describe"
grep -qF "Following main" "$CANON" || fail "doc-update-behavior: tools/canon no longer prints the 'Following main' line the docs describe"
grep -qF "docs/setup.md#how-canon-update-works" "$README" || fail "doc-update-behavior: the README does not point to the section"
echo "doc-update-behavior: ok (the section, its install-type table, the marker, the refusals and the README pointer match what tools/canon prints)"
