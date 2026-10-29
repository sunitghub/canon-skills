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
need "a manifest that does not verify the release" "does not verify the release"
need "the marker file" ".canon-track"
need "the main opt-in" "canon update --to main"
need "the way back" "canon update --to latest"
need "that --to vX.Y.Z is not sticky" "not sticky"
need "the line canon version prints on main" "(development version, following main)"
need "the plain-update-only detached guard" "a *plain* update finds a detached commit"
need "CANON_REF" "CANON_REF=main"
need "a first install that cannot verify" "installs nothing"
# t-50f7: the versioned layout, its rollback and the one-time move of an older install
need "the versioned layout" "packages/vX.Y.Z/"
need "the rollback without a download" "a rollback is one command and downloads nothing"
need "the move of an older install" "Moving an older install into the layout"
need "the compat link" "~/.canon/tools\` becomes the link to \`current/tools"
for row in "Made by the installers at v0.4.0 or later" "A Windows zip install" "made before v0.4.0" "pinned at v0.3.0"; do need "the install-type row '$row'" "$row"; done

# every refusal the docs name, with the text the code prints for it. The code text must sit in a PRINTED message (an echo/die/throw line), so the same words in
# a help text or a comment cannot satisfy it (the first version of this check passed with the real guard deleted because the help text said the same).
refusal() {   # refusal <doc words> <file> <how the code prints: a fixed prefix on the line> <code text>
  need "the refusal '$1'" "$1"
  grep -F -- "$3" "$2" | grep -F -- "$4" >/dev/null || fail "doc-update-behavior: the docs name the refusal '$1' but no '$3' line in $(basename "$2") prints '$4'"
}
PRINT='echo "canon update:'
refusal "has no release" "$MANIFEST" 'die "' "lists no release I can read"
refusal "the manifest cannot be read, has no release" "$MANIFEST" 'die "' "cannot read the release manifest"
refusal "is missing on origin" "$CANON" "$PRINT" "was not found on origin"
refusal "points at a different commit than the manifest says" "$CANON" "$PRINT" "published manifest says"
refusal "has uncommitted changes" "$CANON" "$PRINT" "has uncommitted changes. Commit or stash them first"
refusal "local commits on \`main\`" "$CANON" "$PRINT" "local commit(s) on main"
refusal "cannot fast-forward" "$CANON" "$PRINT" "can't fast-forward"
refusal "another branch than \`main\`" "$CANON" "$PRINT" "not main. Switch to main first"
refusal "detached commit that is not a release tag" "$CANON" "$PRINT" "that is not a release tag"
refusal "the folder is not a git clone" "$CANON" "$PRINT" "isn't a git clone"
PKG="${DOC_UPDATE_PKG:-$ROOT/tools/pkg-lib.sh}"
refusal "this install's Cockpit is running" "$CANON" "$PRINT" "Cockpit is running ("
refusal "another \`canon update\` is running" "$PKG" 'PKG_ERR="' "another canon update is running"
refusal "the download fails" "$PKG" '_pkg_fail "' "the download of"
refusal "its SHA-256 does not match the manifest" "$PKG" '_pkg_fail "' "does not match the published checksum"
refusal "it cannot be unpacked" "$PKG" '_pkg_fail "' "could not unpack"
refusal "the board and daemon cannot be fetched for it" "$PKG" '_pkg_fail "' "could not be fetched"
refusal "if canon's daemon is running" "${DOC_UPDATE_PS1:-$ROOT/install.ps1}" 'throw "' "canon's daemon is running"
grep -qF ".canon-track" "$CANON" || fail "doc-update-behavior: tools/canon no longer uses the .canon-track marker the docs describe"
grep -qF "(development version, following main)" "$CANON" || fail "doc-update-behavior: tools/canon no longer prints the '(development version, following main)' line the docs describe"
# t-d744, t-bb84: the main-track notice has two copies: tools/canon's main_track_note and install.ps1, which downloads the zip itself and never
# runs canon update, so it prints its own. install.sh runs canon update, which prints the notice, so it must not print it again. The lines are
# read from main_track_note, so a reworded owner moves the check with it.
note="$(sed -n '/^main_track_note() {/,/^}/p' "$CANON" | sed -n 's/.*echo "\(You.re on the development version[^"]*\)".*/\1/p')"
next="$(sed -n '/^main_track_note() {/,/^}/p' "$CANON" | sed -n 's/.*echo "\(For the latest release instead[^"]*\)".*/\1/p')"
[[ -n "$note" && -n "$next" ]] || fail "doc-update-behavior: could not read the two notice lines from main_track_note in $CANON"
for f in "${DOC_UPDATE_PS1:-$ROOT/install.ps1}"; do
  for line in "$note" "$next"; do
    # a whole statement line, so the words in a comment or another string do not count
    sed 's/^[[:space:]]*//' "$f" | grep -xF -e "echo \"$line\"" -e "Write-Host \"    $line\"" >/dev/null && continue
    fail "doc-update-behavior: $f does not print tools/canon's main-track line word for word: $line"
  done
done
for line in "$note" "$next"; do   # install.sh: any line that prints either notice line, however it is spelled, is the duplicate t-bb84 removed
  [ "$(grep -cF -- "$line" "${DOC_UPDATE_INSTALL_SH:-$ROOT/install.sh}")" -eq 0 ] || fail "doc-update-behavior: install.sh prints the main-track notice itself, but the canon update it runs already does: $line"
done
grep -qF "docs/setup.md#how-canon-update-works" "$README" || fail "doc-update-behavior: the README does not point to the section"
echo "doc-update-behavior: ok (the section, its install-type table, the marker, the refusals and the README pointer match what tools/canon prints; install.ps1 prints its main-track notice word for word and install.sh leaves it to canon update)"
