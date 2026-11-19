#!/usr/bin/env bash
# changelog-release.sh — t-5ed4: builds canon's release commit from per-ticket changelog fragments. A sprint writes its entry as
# changelog.d/<id>.md (the `- Fixed: … (t-xxxx)` lines it would have put under [Unreleased]), so two tickets never edit CHANGELOG.md
# and their PRs never conflict there. This script moves the [Unreleased] lines, then every fragment in the order it landed on main
# (its adding commit's place in main's first-parent history; ties by file name), under `## [X.Y.Z] - DATE`; removes the fragments;
# writes VERSION; stages all three. It commits nothing: read `git diff --cached`, then commit. docs/releasing.md step 3.
#   scripts/changelog-release.sh <X.Y.Z> [--date YYYY-MM-DD]     DATE defaults to today (UTC)
# It refuses, changing nothing, off main; on a version that is not X.Y.Z or already has a section; when VERSION, CHANGELOG.md or
# changelog.d/ has uncommitted or untracked changes; with no `## [Unreleased]` heading; with nothing to release; or when a fragment
# has no `- ` line.
set -euo pipefail

usage() { echo "usage: scripts/changelog-release.sh <X.Y.Z> [--date YYYY-MM-DD]" >&2; exit 2; }
die() { echo "changelog-release: $*" >&2; exit 1; }

version="" day=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) [[ $# -ge 2 ]] || usage; day="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$version" ]] || usage; version="$1"; shift ;;
  esac
done
[[ -n "$version" ]] || usage
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must be X.Y.Z (got '$version')"
[[ -n "$day" ]] || day="$(date -u +%Y-%m-%d)"
[[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "the date must be YYYY-MM-DD (got '$day')"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
git_() { git -C "$ROOT" "$@"; }
CL="$ROOT/CHANGELOG.md"

branch="$(git_ symbolic-ref -q --short HEAD 2>/dev/null || true)"
[[ "$branch" == main ]] || die "run it on main (HEAD is ${branch:-detached}): the fragments' order is main's history"
dirty="$(git_ status --porcelain --untracked-files=all -- VERSION CHANGELOG.md changelog.d)" || die "git could not read the tree's status"
[[ -z "$dirty" ]] || die "VERSION, CHANGELOG.md or changelog.d/ has uncommitted or untracked changes; commit them first:"$'\n'"$dirty"
[[ -f "$CL" ]] || die "no CHANGELOG.md"
grep -q '^## \[Unreleased\][[:space:]]*$' "$CL" || die "CHANGELOG.md has no '## [Unreleased]' heading"
! grep -qF "## [$version]" "$CL" || die "CHANGELOG.md already has a '## [$version]' section"

# the fragments, oldest landing first: first-parent depth of the commit that added each on main, then the name
frags=(); keyed=""; f=""; at=""; depth=""
while IFS= read -r f; do
  [[ "$f" =~ ^changelog\.d/[^/]+\.md$ ]] || continue
  grep -q '^- ' "$ROOT/$f" || die "$f has no line starting '- ' (a fragment holds CHANGELOG list lines)"
  at="$(git_ log --first-parent --diff-filter=A --format=%H -- "$f" | tail -n 1)" || die "git could not read the history of $f"
  [[ -n "$at" ]] || die "git found no commit on main that added $f"
  depth="$(git_ rev-list --first-parent --count "$at")" || die "git could not place $at in main's history"
  keyed+="$(printf '%012d %s' "$depth" "$f")"$'\n'
done < <(git_ -c core.quotepath=off ls-files -- changelog.d)
while IFS= read -r f; do [[ -n "$f" ]] && frags+=("${f#* }"); done < <(printf '%s' "$keyed" | LC_ALL=C sort)

trim() { tr -d '\r' | awk 'NF { for (; b > 0; b--) print ""; print; seen = 1; next } seen { b++ }'; }   # no blank lines at either end
unrel="$(awk '/^## \[Unreleased\][[:space:]]*$/ { f = 1; next } f && /^## / { exit } f' "$CL" | trim)"
body="$unrel"
for f in ${frags[@]+"${frags[@]}"}; do body+="${body:+$'\n'}$(trim < "$ROOT/$f")"; done
[[ -n "$body" ]] || die "nothing to release: no fragment in changelog.d/ and nothing under [Unreleased]"

tmp="$(mktemp "$ROOT/.changelog-release.XXXXXX")"; trap 'rm -f "$tmp"' EXIT
# head and body through the environment: awk -v would turn a `\` in an entry into an escape
CR_HEAD="## [$version] - $day" CR_BODY="$body" awk '
  !done && /^## \[Unreleased\][[:space:]]*$/ { print; print ""; print ENVIRON["CR_HEAD"]; print ""; print ENVIRON["CR_BODY"]; print ""; skip = 1; done = 1; next }
  skip && /^## / { skip = 0 }
  !skip' "$CL" > "$tmp" || die "could not write the new CHANGELOG.md"
cat "$tmp" > "$CL"
echo "$version" > "$ROOT/VERSION"
[[ ${#frags[@]} -eq 0 ]] || git_ rm -q -- "${frags[@]}"
git_ add -- VERSION CHANGELOG.md
echo "changelog-release: ## [$version] - $day: $( [[ -n "$unrel" ]] && printf '[Unreleased] lines, then ')${#frags[@]} fragment(s)${frags[0]+: ${frags[*]}}; VERSION $version; all staged"
echo "next: git diff --cached, then git commit -m 'chore: release $version'"
