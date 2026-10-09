#!/usr/bin/env bash
# release (t-30fc) — scripts/release.sh cuts a release: annotated tag v<VERSION> pushed to `public` (that tag only) and a GitHub
# release whose notes are the CHANGELOG section. Every precondition refuses with nothing created and nothing pushed. Each case runs
# in a throwaway repo with a bare `public` remote and a stub `gh` first in PATH; nothing here touches the network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

if ! command -v git >/dev/null 2>&1; then echo "release: git absent — skipped"; exit 0; fi

# git config must not leak in (a global tag.gpgSign or hooks path would change the result)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/bin/sh
# stub: log the call; keep the notes file; GH_FAIL=1 fails like a rejected API call
echo "$*" >> "$GH_LOG"
prev=""; for a in "$@"; do [ "$prev" = --notes-file ] && cp "$a" "$GH_NOTES"; prev="$a"; done
[ "${GH_FAIL:-0}" = 0 ] || { echo "gh: HTTP 422 (stub)" >&2; exit 1; }
SH
chmod +x "$BIN/gh"
export GH_LOG="$WORK/gh.log" GH_NOTES="$WORK/gh.notes"; : > "$GH_LOG"

CHANGELOG_OK='# Changelog

## [Unreleased]
- nothing yet

## [0.3.0] - 2026-10-08
### Added
- one thing
- another thing

## [0.2.0] - 2026-09-01
- old'
EXPECT_NOTES=$'### Added\n- one thing\n- another thing'

fresh() {   # prints a repo on main, equal to a bare `public` remote, VERSION 0.3.0, CHANGELOG with a dated 0.3.0 section
  local d; d="$(mktemp -d "$WORK/r.XXXXXX")"   # not a counter: this runs in a $(...) subshell
  git init -q --bare -b main "$d.pub.git"; git init -q -b main "$d"; mkdir -p "$d/scripts"
  cp "$ROOT/scripts/release.sh" "$d/scripts/" 2>/dev/null || true
  echo 0.3.0 > "$d/VERSION"; printf '%s\n' "$CHANGELOG_OK" > "$d/CHANGELOG.md"
  git -C "$d" "${ident[@]}" add -A; git -C "$d" "${ident[@]}" commit -qm init
  git -C "$d" remote add public "$d.pub.git"; git -C "$d" push -q public main 2>/dev/null
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name test
  printf '%s' "$d"
}
rel() { local d="$1"; shift; (cd "$d" && PATH="$BIN:$PATH" bash scripts/release.sh "$@" 2>&1); }
untouched() {   # untouched <repo>: no tag anywhere, public main where it was, no gh call
  local d="$1"
  assert_eq "" "$(git -C "$d" tag)"
  assert_eq "" "$(git -C "$d.pub.git" tag)"
  assert_eq "" "$(cat "$GH_LOG")"
}
refuses() {   # refuses <label> <repo> <expected message part> [args]
  local label="$1" d="$2" part="$3"; shift 3; : > "$GH_LOG"
  set +e; out="$(rel "$d" "$@")"; code=$?; set -e
  [[ "$code" != 0 ]] || fail "release: did not refuse $label: $out"
  assert_contains "$out" "$part"
  untouched "$d"
  echo "release: refused $label"
}

# The success path.
d="$(fresh)"; before="$(git -C "$d.pub.git" rev-parse main)"; : > "$GH_LOG"
set +e; out="$(rel "$d")"; code=$?; set -e; [[ "$code" == 0 ]] || fail "release: the success path exited $code: $out"
assert_eq "tag" "$(git -C "$d" cat-file -t refs/tags/v0.3.0)"                                  # annotated
assert_eq "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d" rev-parse 'v0.3.0^{commit}')"
assert_eq "v0.3.0" "$(git -C "$d.pub.git" tag)"                                                  # exactly that tag on public
assert_eq "$before" "$(git -C "$d.pub.git" rev-parse main)"                                      # main untouched
assert_contains "$(cat "$GH_LOG")" "release create v0.3.0"
assert_contains "$(cat "$GH_LOG")" "--repo sunitghub/canon-skills"
assert_eq "$EXPECT_NOTES" "$(cat "$GH_NOTES")"                                                   # exactly the CHANGELOG section
assert_contains "$out" "v0.3.0"
echo "release: tags, pushes only the tag, creates the release with the CHANGELOG section"

# Another local tag must not travel with it (push is the one tag, not --tags).
d="$(fresh)"; git -C "$d" "${ident[@]}" tag local-only; : > "$GH_LOG"
rel "$d" >/dev/null
assert_eq "v0.3.0" "$(git -C "$d.pub.git" tag)"

# The rest of the tree may be dirty: a tag names a commit, so only VERSION and CHANGELOG.md must match HEAD.
d="$(fresh)"; echo scratch > "$d/untracked.txt"; echo '# local edit' >> "$d/scripts/release.sh"; : > "$GH_LOG"
set +e; out="$(rel "$d")"; code=$?; set -e
[[ "$code" == 0 ]] || fail "release: a dirty tree outside VERSION/CHANGELOG.md blocked the release: $out"
assert_eq "v0.3.0" "$(git -C "$d.pub.git" tag)"
echo "release: a dirty tree outside VERSION and CHANGELOG.md does not block"

# --dry-run reports and creates nothing.
d="$(fresh)"; : > "$GH_LOG"
set +e; out="$(rel "$d" --dry-run)"; code=$?; set -e; [[ "$code" == 0 ]] || fail "release: --dry-run exited $code: $out"
assert_contains "$out" "v0.3.0"; assert_contains "$out" "dry run"; untouched "$d"
echo "release: --dry-run creates nothing"

# Each precondition refuses, naming the problem, and leaves no tag and no push.
for v in 0.3 v0.3.0 0.3.0-rc1 '' abc; do
  d="$(fresh)"; printf '%s\n' "$v" > "$d/VERSION"; git -C "$d" "${ident[@]}" commit -qam v
  git -C "$d" push -q public main 2>/dev/null
  refuses "VERSION '$v'" "$d" "VERSION"
done
d="$(fresh)"; printf '%s\n' "# Changelog" "## [Unreleased]" > "$d/CHANGELOG.md"; git -C "$d" "${ident[@]}" commit -qam c; git -C "$d" push -q public main 2>/dev/null
refuses "a CHANGELOG with no 0.3.0 section" "$d" "CHANGELOG.md"
for hdr in '## [0.3.0]' '## [0.3.0] - soon' '## [0.3.0] - 2026-10-8' '## [0.3.01] - 2026-10-08' '## [0.3.0-rc1] - 2026-10-08'; do
  d="$(fresh)"; printf '%s\n' "# Changelog" "$hdr" "- a thing" > "$d/CHANGELOG.md"; git -C "$d" "${ident[@]}" commit -qam c; git -C "$d" push -q public main 2>/dev/null
  refuses "a CHANGELOG header '$hdr'" "$d" "CHANGELOG.md"
done
d="$(fresh)"; printf '%s\n' "# Changelog" "## [0.3.0] - 2026-10-08" "" "## [0.2.0] - 2026-09-01" "- old" > "$d/CHANGELOG.md"; git -C "$d" "${ident[@]}" commit -qam c; git -C "$d" push -q public main 2>/dev/null
refuses "an empty 0.3.0 section" "$d" "empty"
d="$(fresh)"; echo "- late edit" >> "$d/CHANGELOG.md"
refuses "an uncommitted CHANGELOG" "$d" "uncommitted"
d="$(fresh)"; echo 0.3.1 > "$d/VERSION"
refuses "an uncommitted VERSION" "$d" "uncommitted"
d="$(fresh)"; git -C "$d" checkout -q -b feature
refuses "a branch other than main" "$d" "main"
d="$(fresh)"; echo x > "$d/x"; git -C "$d" "${ident[@]}" add x; git -C "$d" "${ident[@]}" commit -qm ahead
refuses "a HEAD ahead of public/main" "$d" "public/main"
d="$(fresh)"; git clone -q "$d.pub.git" "$d.other" 2>/dev/null; echo y > "$d.other/y"; git -C "$d.other" "${ident[@]}" add y; git -C "$d.other" "${ident[@]}" commit -qm newer; git -C "$d.other" push -q origin main 2>/dev/null
refuses "a HEAD behind public/main" "$d" "public/main"
d="$(fresh)"; git -C "$d" "${ident[@]}" tag v0.3.0
set +e; : > "$GH_LOG"; out="$(rel "$d")"; code=$?; set -e
[[ "$code" != 0 ]] || fail "release: did not refuse an existing local tag"; assert_contains "$out" "already exists"; assert_eq "" "$(git -C "$d.pub.git" tag)"; assert_eq "" "$(cat "$GH_LOG")"
d="$(fresh)"; git -C "$d" "${ident[@]}" tag v0.3.0; git -C "$d" push -q public refs/tags/v0.3.0 2>/dev/null; git -C "$d" tag -d v0.3.0 >/dev/null
set +e; : > "$GH_LOG"; out="$(rel "$d")"; code=$?; set -e
[[ "$code" != 0 ]] || fail "release: did not refuse a tag that exists on public"; assert_contains "$out" "already exists"; assert_eq "" "$(git -C "$d" tag)"; assert_eq "" "$(cat "$GH_LOG")"
# An unreachable remote is an error, not "no such tag".
d="$(fresh)"; git -C "$d" remote set-url public "$WORK/does-not-exist.git"
refuses "an unreachable public remote" "$d" "public"
# The fetch above would catch a dead remote first; this reaches the tag lookup alone: a git whose ls-remote fails must not read as "no such tag".
d="$(fresh)"; LSR="$WORK/lsr-git"; mkdir -p "$LSR"; REAL_GIT="$(command -v git)"
printf '#!/bin/sh\ncase " $* " in *" ls-remote "*) echo "fatal: ls-remote failed (stub)" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" > "$LSR/git"; chmod +x "$LSR/git"
: > "$GH_LOG"; set +e; out="$(cd "$d" && PATH="$LSR:$BIN:$PATH" bash scripts/release.sh 2>&1)"; code=$?; set -e
[[ "$code" != 0 ]] || fail "release: a failing ls-remote was read as 'no such tag': $out"
assert_contains "$out" "cannot list tags"; untouched "$d"

# gh failing after the tag is pushed: say so and how to finish; never delete the pushed tag.
d="$(fresh)"; : > "$GH_LOG"
set +e; out="$(GH_FAIL=1 rel "$d")"; code=$?; set -e
[[ "$code" != 0 ]] || fail "release: a failed gh release exited 0"
assert_contains "$out" "already pushed"; assert_contains "$out" "gh release create v0.3.0"
assert_eq "v0.3.0" "$(git -C "$d.pub.git" tag)"
echo "release: every precondition refuses; a failed gh call keeps the pushed tag and says how to finish"
echo "release: ok"
