#!/usr/bin/env bash
# release.sh — cut a canon release (t-30fc): an annotated tag v<VERSION> on `public` (canon-skills, what consumers install) and a
# GitHub release whose notes are that version's CHANGELOG section. Maintainer step: run it after the release commit (VERSION bump +
# dated CHANGELOG section) is on public main. docs/releasing.md has the whole pipeline.
#   scripts/release.sh              tag, push that one tag, create the GitHub release
#   scripts/release.sh --dry-run    check everything and print what it would do; creates and pushes nothing
# It refuses, changing nothing, unless: VERSION is X.Y.Z; CHANGELOG.md has a `## [X.Y.Z] - YYYY-MM-DD` section with content; VERSION
# and CHANGELOG.md match HEAD; HEAD is main and equals public/main (the tag names what consumers get); the tag is on neither side.
set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE="${CANON_RELEASE_REMOTE:-public}"
RELEASE_REPO="${CANON_RELEASE_REPO:-sunitghub/canon-skills}"
dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "usage: scripts/release.sh [--dry-run]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: scripts/release.sh [--dry-run]" >&2; exit 2; }

die() { echo "release: $*" >&2; exit 1; }
git_() { git -C "$REPO_ROOT" "$@"; }

[ -z "$(git_ status --porcelain -- VERSION CHANGELOG.md)" ] || die "VERSION or CHANGELOG.md has uncommitted changes; commit them first"

version="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION" 2>/dev/null)" || version=""
re='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$version" =~ $re ]] || die "VERSION must be X.Y.Z (got '$version')"
tag="v$version"

# the notes: this version's CHANGELOG section, found by its dated header (`## [0.3.0] - 2026-10-08`, never `[0.3.01]` or `[0.3.0-rc1]`)
section="$(tr -d '\r' < "$REPO_ROOT/CHANGELOG.md" 2>/dev/null | awk -v ver="$version" '
  BEGIN { pre = "## [" ver "] - " }
  f == 0 && index($0, pre) == 1 && substr($0, length(pre) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*$/ { f = 1; print "FOUND"; next }
  f == 1 && /^## / { exit }
  f == 1 { print }
')" || section=""
[[ "$section" == FOUND* ]] || die "CHANGELOG.md has no dated '## [$version] - YYYY-MM-DD' section"
notes="$(printf '%s\n' "${section#FOUND}" | awk 'NF { p = 1 } p { b[++n] = $0 } END { while (n > 0 && b[n] !~ /[^ \t]/) n--; for (i = 1; i <= n; i++) print b[i] }')"
[ -n "$notes" ] || die "the CHANGELOG.md section for $version is empty"

[ "$(git_ rev-parse --abbrev-ref HEAD)" = main ] || die "release from main (this checkout is on '$(git_ rev-parse --abbrev-ref HEAD)')"
git_ fetch -q "$REMOTE" main 2>/dev/null || die "cannot reach remote '$REMOTE'"
[ "$(git_ rev-parse HEAD)" = "$(git_ rev-parse "$REMOTE/main")" ] || die "HEAD is not $REMOTE/main: push or pull first, so the tag names exactly what consumers get"

if git_ rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then die "tag $tag already exists locally"; fi
remote_tag="$(git_ ls-remote --tags "$REMOTE" "refs/tags/$tag")" || die "cannot list tags on remote '$REMOTE'"
[ -z "$remote_tag" ] || die "tag $tag already exists on $REMOTE"
if [ "$dry" = 0 ]; then command -v gh >/dev/null 2>&1 || die "gh is required (gh auth login)"; fi

if [ "$dry" = 1 ]; then
  echo "release: dry run — would tag $tag at $(git_ rev-parse --short HEAD), push only refs/tags/$tag to $REMOTE, and create the GitHub release on $RELEASE_REPO with these notes:"
  printf '%s\n' "$notes"
  exit 0
fi

notes_file="$(mktemp)"; trap 'rm -f "$notes_file"' EXIT
printf '%s\n' "$notes" > "$notes_file"
git_ tag -a "$tag" -m "canon $version"
git_ push -q "$REMOTE" "refs/tags/$tag"
echo "release: pushed tag $tag to $REMOTE"
if ! gh release create "$tag" --repo "$RELEASE_REPO" --title "canon $version" --notes-file "$notes_file"; then
  die "tag $tag is already pushed but the GitHub release was not created; finish with: gh release create $tag --repo $RELEASE_REPO --title 'canon $version' --notes-file <notes>"
fi
echo "release: $tag released"
