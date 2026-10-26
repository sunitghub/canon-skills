#!/usr/bin/env bash
# release-zip-slim (t-3954) — protects the end-user download: scripts/release-zip.sh leaves tests/, most of meta/ and the Go source out of
# canon-X.Y.Z.zip, and what the install reads must all still be in it. Builds the zip from a shallow clone of THIS repo's HEAD with the
# working copy's release-zip.sh, unpacks it, checks the absent paths, the present paths (named from the tools, the board's tour images from
# app.html itself), byte-equality with the tag, the size bounds and reproducibility, then runs the tools from the unpacked tree. A revert
# check shows each check can fail. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

command -v git >/dev/null 2>&1 || { echo "release-zip-slim: git absent, skipped"; exit 0; }
command -v unzip >/dev/null 2>&1 || { echo "release-zip-slim: unzip absent, skipped"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

R="$WORK/repo"
git clone -q --depth 1 "file://$ROOT" "$R" 2>/dev/null || fail "release-zip-slim: could not clone $ROOT"
git -C "$R" "${ident[@]}" tag -a v9.9.9 -m "canon 9.9.9"
tree_files() { git -C "$R" ls-tree -r --name-only v9.9.9; }
[[ -f "$R/tools/sprint-check-app/app.html" && -d "$R/tests" ]] || fail "release-zip-slim: the clone is not this repository's tree"

# build <script> <outfolder>: the zip for the tag, with the given copy of release-zip.sh (the working copy, or a deliberately broken one)
build() {
  mkdir -p "$2"; cp "$1" "$R/scripts/release-zip.sh"
  (cd "$R" && bash scripts/release-zip.sh v9.9.9 "$2" >"$2/line" 2>&1) || { cat "$2/line" >&2; return 1; }
}

# check_zip <zip> <unpack folder>: prints the problems found, one per line (nothing = a good zip)
check_zip() {
  local zip="$1" u="$2" top bad="" p f n kb files
  rm -rf "$u"; mkdir -p "$u"; unzip -q "$zip" -d "$u"; top="$u/canon-9.9.9"
  [[ -d "$top" ]] || { echo "no canon-9.9.9/ folder"; return; }
  # 1. what is left out
  [[ ! -e "$top/tests" ]] || echo "tests/ is in the zip"
  [[ ! -e "$top/tools/canon-go/cmd" && ! -e "$top/tools/canon-go/internal" ]] || echo "the Go source is in the zip"
  n="$( (cd "$top/meta" 2>/dev/null && find . -type f | wc -l | tr -d ' ') || echo 0)"
  # 2. what the install reads is there: the board's tour images (named by app.html itself) ...
  local shots; shots="$(grep -o 'src="/meta/screenshots/[A-Za-z0-9_.-]*"' "$top/tools/sprint-check-app/app.html" | sed 's#.*/##; s#"$##' | sort -u)"
  [[ -n "$shots" ]] || echo "app.html names no tour screenshots (the check cannot run)"
  for f in $shots; do [[ -f "$top/meta/screenshots/$f" ]] || echo "the tour image $f is missing"; done
  [[ "$n" == "$(printf '%s\n' "$shots" | grep -c .)" ]] || echo "meta/ holds $n files, not just the tour's $(printf '%s\n' "$shots" | grep -c .)"
  # ... and the files named by the tools (each with the line that reads it)
  for p in tools/tkt tools/canon tools/skills.sh tools/sprint tools/fetch-daemon.sh tools/src-key.sh tools/cloud-env.sh tools/hooks-lib.sh \
           scripts/pre-commit-hook-template.sh tools/canon-go/go.mod tools/canon-go/go.sum tools/cockpit-daemon.sha256 VERSION install.sh install.ps1 \
           skills/sprint/SKILL.md agents/canon-reviewer.md standards/efficiency.md docs/setup.md tools/sprint-check-app/app.html; do
    [[ -f "$top/$p" ]] || echo "$p is missing (the install reads it)"
  done
  # 3. everything else shipped is byte-identical to the tag, and nothing but the exclusions is missing
  local want got
  want="$(tree_files | grep -vE '^(tests/|tools/canon-go/cmd/|tools/canon-go/internal/)' | grep -vE '^meta/' || true)"
  got="$(cd "$top" && find . -type f | sed 's#^\./##' | grep -v '^meta/' | LC_ALL=C sort)"
  [[ "$(printf '%s\n' "$want" | LC_ALL=C sort)" == "$got" ]] || echo "the files outside meta/ differ from the tag's tree minus the exclusions"
  while IFS= read -r f; do
    [[ -f "$top/$f" ]] || continue
    [[ "$(git -C "$R" rev-parse "v9.9.9:$f")" == "$(git hash-object --no-filters "$top/$f")" ]] || echo "$f differs from the tag"
  done < <(printf '%s\n' "$want" | head -400)
  # 4. size: the point of the exclusions
  kb="$(du -sk "$top" | cut -f1)"; files="$(find "$top" -type f | wc -l | tr -d ' ')"
  (( kb <= 4608 )) || echo "unpacked size ${kb} KB is over 4608 KB"
  (( files <= 300 )) || echo "$files files is over 300"
}

# the working copy's script builds a good zip
build "$ROOT/scripts/release-zip.sh" "$WORK/out" || fail "release-zip-slim: the build failed"
problems="$(check_zip "$WORK/out/canon-9.9.9.zip" "$WORK/u1")"
[[ -z "$problems" ]] || fail "release-zip-slim: the zip is wrong:
$problems"
echo "release-zip-slim: leaves out tests, the Go source and all but the tour's screenshots; every path the install reads is present and identical to the tag"

# reproducible: the same tag builds the same bytes (a lost asset can be rebuilt to match its manifest line)
build "$ROOT/scripts/release-zip.sh" "$WORK/out2"
assert_eq "$(cat "$WORK/out/line")" "$(cat "$WORK/out2/line")"
echo "release-zip-slim: two builds give the same zip hash"

# the manifest line keeps its shape
re='^v9\.9\.9 [0-9a-f]{64} [0-9a-f]{40}$'
[[ "$(cat "$WORK/out/line")" =~ $re ]] || fail "release-zip-slim: not a manifest line: $(cat "$WORK/out/line")"

# the tools run from the unpacked tree, in a scratch project, with the user's HOME kept out of it
top="$WORK/u1/canon-9.9.9"; P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q
(cd "$P" && HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" bash "$top/tools/tkt" --version >/dev/null 2>&1) || fail "release-zip-slim: tkt --version did not run from the unpacked zip"
(cd "$P" && HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" bash "$top/tools/canon" version 2>&1 | grep -q "$(cat "$top/VERSION")") || fail "release-zip-slim: canon version did not name $(cat "$top/VERSION")"
out="$(bash "$top/tools/cloud-env.sh" script --go 2>&1)"; [[ "$out" == *"go.dev/dl"* && "$out" == *"canon-go/go.mod"* ]] || fail "release-zip-slim: cloud-env.sh script --go is wrong from the unpacked zip"
grep -q '^toolchain go' "$top/tools/canon-go/go.mod" || fail "release-zip-slim: go.mod has no toolchain line"
echo "release-zip-slim: tkt, canon and cloud-env run from the unpacked zip; go.mod keeps its toolchain line"

# revert checks: a list that drops something the install reads, or that forgets an exclusion, must be caught
bad() {   # bad <name> <sed expression on the script>
  local d="$WORK/bad-$1"; mkdir -p "$d"; sed -E "$2" "$ROOT/scripts/release-zip.sh" > "$d/release-zip.sh"
  cmp -s "$d/release-zip.sh" "$ROOT/scripts/release-zip.sh" && fail "release-zip-slim: the revert edit '$1' changed nothing (the list moved?)"
  build "$d/release-zip.sh" "$d/out" >/dev/null 2>&1 || true
  [[ -f "$d/out/canon-9.9.9.zip" ]] || fail "release-zip-slim: the broken build '$1' made no zip"
  [[ -n "$(check_zip "$d/out/canon-9.9.9.zip" "$d/u")" ]] || fail "release-zip-slim: the check passed a zip built with the list broken by '$1'"
}
bad also-scripts 's#^SLIM_EXCLUDE=\(tests #SLIM_EXCLUDE=(scripts tests #'
bad also-gomod  's#tools/canon-go/cmd tools/canon-go/internal\)#tools/canon-go)#'
bad forgot-tests 's#^SLIM_EXCLUDE=\(tests #SLIM_EXCLUDE=(#'
bad no-keep-shots 's#^  keep_shots="\$\(git .*$#  keep_shots=""#'
echo "release-zip-slim: ok (revert checks: dropping scripts/ or go.mod, forgetting tests/, or losing the tour images each fails the check)"
