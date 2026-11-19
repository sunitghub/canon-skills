#!/usr/bin/env bash
# changelog-release (t-5ed4) — protects canon's release commit (docs/releasing.md step 3): per-ticket fragments in changelog.d/ never
# conflict between two tickets, and scripts/changelog-release.sh builds the dated section from [Unreleased] and the fragments in the
# order they landed on main (not commit dates, not names), removes them, writes VERSION and stages all, committing nothing. Every
# refusal changes no file. Throwaway repos only; no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
command -v git >/dev/null 2>&1 || { echo "changelog-release: git absent, skipped"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
SCRIPT="$ROOT/scripts/changelog-release.sh"

CL_BASE='# Changelog

Intro text.

## [Unreleased]

- Fixed: an entry written before fragments (t-0000).

## [0.8.0] - 2026-11-01

- Old entry.'

fresh() {   # fresh [changelog text]: a repo on main with VERSION 0.8.0 and the CHANGELOG, one commit
  local d; d="$(mktemp -d "$WORK/r.XXXXXX")"
  git init -q -b main "$d"; echo 0.8.0 > "$d/VERSION"; printf '%s\n' "${1-$CL_BASE}" > "$d/CHANGELOG.md"
  git -C "$d" add -A; git -C "$d" commit -qm init
  printf '%s' "$d"
}
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" "${@:2}"; }   # at <date> <cmd…>: a commit made "at" that date
cr() { local d="$1"; shift; (cd "$d" && bash "$SCRIPT" "$@" 2>&1); }

# 1. two tickets' fragments merge into main in either order with no conflict
d="$(fresh)"
for t in a b; do
  git -C "$d" checkout -q -b "t-$t" main; mkdir -p "$d/changelog.d"
  echo "- Fixed: ticket $t (t-000$t)." > "$d/changelog.d/t-000$t.md"; git -C "$d" add changelog.d; git -C "$d" commit -qm "t-$t"
done
for order in "t-a t-b" "t-b t-a"; do
  git -C "$d" checkout -q -B "m-${order// /-}" main
  for b in $order; do git -C "$d" merge -q --no-edit "$b" >/dev/null 2>&1 || fail "changelog-release: merging $b ($order) conflicted"; done
done
echo "changelog-release: two tickets' fragments merge in either order"

# 2. the release section: [Unreleased] first, then fragments by landing on main's first-parent history. The first to land is named
# last and dated latest; the merged one was committed earliest; two added in one commit go by name. A \ and a CRLF line survive.
d="$(fresh)"; mkdir -p "$d/changelog.d"
git -C "$d" checkout -q -b side main
printf -- '- Fixed: merged second (t-aaaa).\n' > "$d/changelog.d/t-aaaa.md"
git -C "$d" add changelog.d; at "2020-01-01T00:00:00Z" git -C "$d" commit -qm side
git -C "$d" checkout -q main; mkdir -p "$d/changelog.d"
printf -- '- Added: landed first, path a\\b (t-ffff).\r\n  continued line.\n\n' > "$d/changelog.d/t-ffff.md"
git -C "$d" add changelog.d; at "2030-01-01T00:00:00Z" git -C "$d" commit -qm first
at "2025-01-01T00:00:00Z" git -C "$d" merge -q --no-ff --no-edit side
printf -- '- Changed: same commit, c (t-cccc).\n' > "$d/changelog.d/t-cccc.md"
printf -- '- Changed: same commit, b (t-bbbb).\n' > "$d/changelog.d/t-bbbb.md"
git -C "$d" add changelog.d; at "2021-01-01T00:00:00Z" git -C "$d" commit -qm third
head="$(git -C "$d" rev-parse HEAD)"
out="$(cr "$d" 0.9.0 --date 2026-11-19)" || fail "changelog-release: a good release refused: $out"
expect='# Changelog

Intro text.

## [Unreleased]

## [0.9.0] - 2026-11-19

- Fixed: an entry written before fragments (t-0000).
- Added: landed first, path a\b (t-ffff).
  continued line.
- Fixed: merged second (t-aaaa).
- Changed: same commit, b (t-bbbb).
- Changed: same commit, c (t-cccc).

## [0.8.0] - 2026-11-01

- Old entry.'
assert_eq "$expect" "$(cat "$d/CHANGELOG.md")"
assert_eq "0.9.0" "$(cat "$d/VERSION")"
assert_eq "$head" "$(git -C "$d" rev-parse HEAD)"                       # nothing committed
assert_eq "" "$(git -C "$d" ls-files -- changelog.d)"                   # the fragments are removed from the index
[[ ! -e "$d/changelog.d/t-ffff.md" ]] || fail "changelog-release: a fragment is still on disk"
assert_eq "" "$(git -C "$d" status --porcelain --untracked-files=all | grep -v '^[MD] ' || true)"   # everything staged, nothing left unstaged
assert_eq "D  changelog.d/t-aaaa.md|D  changelog.d/t-bbbb.md|D  changelog.d/t-cccc.md|D  changelog.d/t-ffff.md|M  CHANGELOG.md|M  VERSION" \
  "$(git -C "$d" status --porcelain | LC_ALL=C sort | paste -sd'|' -)"
assert_contains "$out" "4 fragment(s): changelog.d/t-ffff.md changelog.d/t-aaaa.md changelog.d/t-bbbb.md changelog.d/t-cccc.md"
echo "changelog-release: the section holds [Unreleased] then every fragment once, in landing order; staged, not committed"

# fragments alone (an empty [Unreleased]) make a section too
d="$(fresh "$(printf '# Changelog\n\n## [Unreleased]\n\n## [0.8.0] - 2026-11-01\n\n- Old entry.')")"; mkdir -p "$d/changelog.d"
echo "- Fixed: only one (t-1111)." > "$d/changelog.d/t-1111.md"; git -C "$d" add changelog.d; git -C "$d" commit -qm one
cr "$d" 0.8.1 --date 2026-11-20 >/dev/null || fail "changelog-release: fragments with an empty [Unreleased] refused"
assert_eq $'# Changelog\n\n## [Unreleased]\n\n## [0.8.1] - 2026-11-20\n\n- Fixed: only one (t-1111).\n\n## [0.8.0] - 2026-11-01\n\n- Old entry.' "$(cat "$d/CHANGELOG.md")"
echo "changelog-release: fragments with an empty [Unreleased]"

# [Unreleased] lines alone (no fragment) make a section; a tracked file in changelog.d/ that is not a top-level .md is no fragment: kept, not read
d="$(fresh)"; mkdir -p "$d/changelog.d/sub"; echo "- not a fragment" > "$d/changelog.d/notes.txt"; echo "- nor this" > "$d/changelog.d/sub/x.md"
git -C "$d" add changelog.d; git -C "$d" commit -qm other
out="$(cr "$d" 0.8.1 --date 2026-11-20)" || fail "changelog-release: [Unreleased] lines alone refused: $out"
assert_eq $'# Changelog\n\nIntro text.\n\n## [Unreleased]\n\n## [0.8.1] - 2026-11-20\n\n- Fixed: an entry written before fragments (t-0000).\n\n## [0.8.0] - 2026-11-01\n\n- Old entry.' "$(cat "$d/CHANGELOG.md")"
assert_eq "changelog.d/notes.txt|changelog.d/sub/x.md" "$(git -C "$d" ls-files -- changelog.d | paste -sd'|' -)"
assert_contains "$out" "[Unreleased] lines, then 0 fragment(s); VERSION 0.8.1; all staged"
assert_contains "$out" "next: git diff --cached, then git commit -m 'chore: release 0.8.1'"
echo "changelog-release: [Unreleased] lines alone; other files in changelog.d/ are left alone"

# 3. each refusal exits 1, names its reason and changes no file
snap() { (cd "$1" && git status --porcelain --untracked-files=all; cat VERSION CHANGELOG.md; { find changelog.d -type f 2>/dev/null || true; } | LC_ALL=C sort) ; }
refuses() {   # refuses <label> <repo> <reason part> <args…>
  local label="$1" d="$2" want="$3" before out code=0; shift 3
  before="$(snap "$d")"
  out="$(cr "$d" "$@")" || code=$?
  [[ "$code" == 1 ]] || fail "changelog-release: $label: exit $code, not 1: $out"
  assert_contains "$out" "$want"
  assert_eq "$before" "$(snap "$d")"
  echo "changelog-release: refuses $label"
}
withfrag() { local d; d="$(fresh "${2-$CL_BASE}")"; mkdir -p "$d/changelog.d"; printf '%s\n' "$1" > "$d/changelog.d/t-1111.md"; git -C "$d" add changelog.d; git -C "$d" commit -qm frag; printf '%s' "$d"; }

d="$(withfrag "- Fixed: x (t-1111).")"; git -C "$d" checkout -q -b other
refuses "off main" "$d" "run it on main" 0.9.0
d="$(withfrag "- Fixed: x (t-1111).")"
refuses "a version that is not X.Y.Z" "$d" "X.Y.Z" 0.9
refuses "a version with a suffix" "$d" "X.Y.Z" 0.9.0-rc1
refuses "a version with a prefix" "$d" "X.Y.Z" v0.9.0
refuses "a date with a short day" "$d" "YYYY-MM-DD" 0.9.0 --date 2026-11-1
refuses "a date with a prefix" "$d" "YYYY-MM-DD" 0.9.0 --date x2026-11-19
for args in "" "--force 0.9.0" "0.9.0 0.9.1" "0.9.0 --date"; do   # usage errors exit 2, changing nothing
  before="$(snap "$d")"; code=0; out="$(cr "$d" $args)" || code=$?   # word splitting intended
  [[ "$code" == 2 ]] || fail "changelog-release: usage '$args' exited $code, not 2: $out"
  assert_contains "$out" "usage: scripts/changelog-release.sh <X.Y.Z>"; assert_eq "$before" "$(snap "$d")"
done
echo "changelog-release: usage errors exit 2"
refuses "an existing section" "$d" "already has a '## [0.8.0]' section" 0.8.0
echo "- late" >> "$d/CHANGELOG.md"
refuses "an uncommitted CHANGELOG.md" "$d" "uncommitted" 0.9.0
d="$(withfrag "- Fixed: x (t-1111).")"; echo "- Fixed: y (t-2222)." > "$d/changelog.d/t-2222.md"
refuses "an untracked fragment" "$d" "changelog.d/t-2222.md" 0.9.0
d="$(withfrag "- Fixed: x (t-1111)." "$(printf '# Changelog\n\n## [0.8.0] - 2026-11-01\n\n- Old entry.')")"
refuses "no [Unreleased] heading" "$d" "no '## [Unreleased]' heading" 0.9.0
d="$(fresh "$(printf '# Changelog\n\n## [Unreleased]\n\n## [0.8.0] - 2026-11-01\n\n- Old entry.')")"
refuses "nothing to release" "$d" "nothing to release" 0.9.0
git -C "$d" rm -q CHANGELOG.md; git -C "$d" commit -qm gone; snap() { (cd "$1" && git status --porcelain --untracked-files=all; cat VERSION); }
refuses "no CHANGELOG.md" "$d" "no CHANGELOG.md" 0.9.0
snap() { (cd "$1" && git status --porcelain --untracked-files=all; cat VERSION CHANGELOG.md; { find changelog.d -type f 2>/dev/null || true; } | LC_ALL=C sort) ; }
d="$(withfrag "Fixed: no list marker (t-1111).")"
refuses "a fragment with no '- ' line" "$d" "changelog.d/t-1111.md has no line starting '- '" 0.9.0
echo "changelog-release: ok"
