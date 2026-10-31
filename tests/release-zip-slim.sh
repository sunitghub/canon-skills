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

# The size and file bounds come from tools/caps.tsv through the board's cap meter (t-19bb), which counts file bytes, never `du`'s disk
# blocks (the same zip read 4364 KB on APFS and 4656 KB on Linux, where every folder costs a 4 KB block; t-0d96).
export SPRINT_CHECK_NO_BROWSER=1   # an older board would take `caps` for a port and start (t-269d)
CAPS="$ROOT/tools/caps.tsv"; BOARD="$(build_board "$WORK")"
SIZE_CAP_KB="$("$BOARD" caps --list --table "$CAPS" | sed -n 's/^release-zip: \([0-9]*\) KB .*/\1/p')"
[[ "$SIZE_CAP_KB" =~ ^[0-9]+$ ]] || fail "release-zip-slim: tools/caps.tsv has no release-zip row"
unpacked_kb() { local out rc=0; out="$("$BOARD" caps --json --table "$CAPS" release-zip "$1" 2>&1)" || rc=$?; (( rc < 2 )) && [[ "$out" == *'"used":'* ]] || return 1; out="${out#*\"used\":}"; echo "${out%%,*}"; }
# cap_problem <row> <dir>: the meter's line when over ("release-zip: 4097 of 4096 KB, over by 1"); nothing within the cap. Exit 0
# alone is not "within": a missing row ("not capped") or path ("not present") is a problem too, never a dropped cap.
cap_problem() {
  local out rc=0; out="$("$BOARD" caps --table "$CAPS" "$1" "$2" 2>&1)" || rc=$?
  case "$rc:$out" in
    0:*" left") ;;
    1:*", over by "*) echo "$out" ;;
    0:*) echo "$1: no cap was measured for $2: $out" ;;
    *) echo "$1 could not be read under $2: $out" ;;
  esac
}
size_problem() { cap_problem release-zip "$1"; }

# check_zip <zip> <unpack folder>: prints the problems found, one per line (nothing = a good zip)
check_zip() {
  local zip="$1" u="$2" full="${3:-}" top p f n
  rm -rf "$u"; mkdir -p "$u"; unzip -q "$zip" -d "$u"; top="$u/canon-9.9.9"
  [[ -d "$top" ]] || { echo "no canon-9.9.9/ folder"; return; }
  # 1. what is left out
  [[ ! -e "$top/tests" ]] || echo "tests/ is in the zip"
  [[ ! -e "$top/tools/canon-go/cmd" && ! -e "$top/tools/canon-go/internal" ]] || echo "the Go source is in the zip"
  [[ ! -e "$top/tools/vendored.tsv" && ! -e "$top/tools/sprint-check-app/CLAUDE.md" ]] || echo "a developer-only file is in the zip"   # t-7299
  n="$( (cd "$top/meta" 2>/dev/null && find . -type f | wc -l | tr -d ' ') || echo 0)"
  # 2. what the install reads is there: the board's tour images (named by app.html itself) ...
  local shots; shots="$(grep -o 'src="/meta/screenshots/[A-Za-z0-9_.-]*"' "$top/tools/sprint-check-app/app.html" | sed 's#.*/##; s#"$##' | sort -u)"
  [[ -n "$shots" ]] || echo "app.html names no tour screenshots (the check cannot run)"
  for f in $shots; do [[ -f "$top/meta/screenshots/$f" ]] || echo "the tour image $f is missing"; done
  [[ "$n" == "$(printf '%s\n' "$shots" | grep -c .)" ]] || echo "meta/ holds $n files, not just the tour's $(printf '%s\n' "$shots" | grep -c .)"
  # ... and the files the tools read (path <TAB> what reads it)
  while IFS=$'\t' read -r p why; do
    [[ -f "$top/$p" ]] || echo "$p is missing ($why)"
  done <<'REQ'
tools/tkt	the ticket tool
tools/canon	the canon command
tools/skills.sh	skills add / refresh (SKILLS_ROOT is the install)
tools/sprint	sprint start / complete
tools/fetch-daemon.sh	fetches the two programs at start
tools/src-key.sh	sourced by fetch-daemon.sh
tools/cockpit-daemon.sha256	fetch-daemon.sh's manifest of release hashes
tools/cloud-env.sh	prints the cloud environment's setup script
tools/hooks-lib.sh	installs the pre-commit hook into a project
scripts/pre-commit-hook-template.sh	tools/hooks-lib.sh:40 copies it
tools/canon-go/go.mod	tools/cloud-env.sh reads the pinned toolchain
tools/canon-go/go.sum	the module's checksums beside go.mod
VERSION	canon version, fetch-daemon.sh, the board's header
install.sh	the macOS and Linux installer
install.ps1	the Windows installer
skills/sprint/SKILL.md	the sprint skill
agents/canon-reviewer.md	the close-gate reviewer
standards/efficiency.md	the global standards file skills add imports
docs/setup.md	linked from the tools' messages
tools/sprint-check-app/app.html	the board page (its tour images are checked above)
REQ
  # 3. everything else shipped is byte-identical to the tag, and nothing but the exclusions is missing
  local want got
  want="$(tree_files | grep -vE '^(tests/|tools/canon-go/cmd/|tools/canon-go/internal/|tools/vendored\.tsv$|tools/sprint-check-app/CLAUDE\.md$)' | grep -vE '^meta/' || true)"
  got="$(cd "$top" && find . -type f | sed 's#^\./##' | grep -v '^meta/' | LC_ALL=C sort)"
  [[ "$(printf '%s\n' "$want" | LC_ALL=C sort)" == "$got" ]] || echo "the files outside meta/ differ from the tag's tree minus the exclusions"
  if [[ -n "$full" ]]; then   # one git call per file: only for the zip the test expects to be good
    while IFS= read -r f; do
      [[ -f "$top/$f" ]] || continue
      [[ "$(git -C "$R" rev-parse "v9.9.9:$f")" == "$(git hash-object --no-filters "$top/$f")" ]] || echo "$f differs from the tag"
    done < <(printf '%s\n' "$want")
  fi
  # 4. size: the point of the exclusions
  size_problem "$top"
  cap_problem release-zip-files "$top"
}

# the working copy's script builds a good zip
build "$ROOT/scripts/release-zip.sh" "$WORK/out" || fail "release-zip-slim: the build failed"
problems="$(check_zip "$WORK/out/canon-9.9.9.zip" "$WORK/u1" full)"
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
cv="$(cd "$P" && HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" bash "$top/tools/canon" version 2>&1 || true)"
[[ "$cv" == *"$(cat "$top/VERSION")"* ]] || fail "release-zip-slim: canon version did not name $(cat "$top/VERSION"): $cv"
sl_zip="$(cd "$P" && HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" bash "$top/tools/skills.sh" list 2>&1 || true)"
sl_full="$(cd "$P" && HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" bash "$R/tools/skills.sh" list 2>&1 || true)"
assert_eq "$sl_full" "$sl_zip"   # the skills list is the same from the unpacked zip as from the full tree
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
bad also-gomod  's#tools/canon-go/cmd tools/canon-go/internal #tools/canon-go #'
bad ship-devfiles 's# tools/vendored\.tsv tools/sprint-check-app/CLAUDE\.md\)#)#'
bad forgot-tests 's#^SLIM_EXCLUDE=\(tests #SLIM_EXCLUDE=(#'
bad no-keep-shots 's#^  keep_shots="\$\(git .*$#  keep_shots=""#'
# the size bound measures bytes, not disk blocks, and can fail: filler that costs blocks but no bytes leaves the reading alone, real bytes push it over the cap
fat="$WORK/fat"; cp -R "$WORK/u1" "$fat"; ft="$fat/canon-9.9.9"; base_kb="$(unpacked_kb "$ft")"
for i in $(seq 1 200); do printf x > "$ft/.tiny$i"; done
for i in $(seq 1 100); do mkdir "$ft/.dir$i"; done
(( $(unpacked_kb "$ft") - base_kb < 10 )) || fail "release-zip-slim: 200 one-byte files and 100 empty folders moved the size reading from $base_kb to $(unpacked_kb "$ft") KB: it measures disk blocks"
[[ -z "$(size_problem "$ft")" ]] || fail "release-zip-slim: the filler alone put the zip over the size cap"
head -c 716800 /dev/zero > "$ft/.pad"
[[ "$(size_problem "$ft")" == "release-zip: "*" of $SIZE_CAP_KB KB, over by "* ]] || fail "release-zip-slim: a 700 KB file did not take the zip over the size cap: '$(size_problem "$ft")'"
# check_zip itself reports an oversize zip (the call to size_problem must stay in it)
if command -v zip >/dev/null 2>&1; then
  (cd "$fat" && zip -qr "$WORK/fat.zip" canon-9.9.9)
  [[ "$(check_zip "$WORK/fat.zip" "$WORK/u2")" == *"of $SIZE_CAP_KB KB, over by"* ]] || fail "release-zip-slim: check_zip did not report a zip over the size cap"
fi
# the boundary and the rounding: the cap itself is fine, one byte more is 1 KB over; 1 byte reads 1 KB, 1024 reads 1, 1025 reads 2
bd="$WORK/bd"; mkdir -p "$bd"; head -c $(( SIZE_CAP_KB * 1024 )) /dev/zero > "$bd/f"
[[ -z "$(size_problem "$bd")" ]] || fail "release-zip-slim: exactly $SIZE_CAP_KB KB of bytes was reported over the cap"
printf x >> "$bd/f"
assert_eq "release-zip: $(( SIZE_CAP_KB + 1 )) of $SIZE_CAP_KB KB, over by 1" "$(size_problem "$bd")"
printf x > "$bd/f"; assert_eq 1 "$(unpacked_kb "$bd")"
head -c 1024 /dev/zero > "$bd/f"; assert_eq 1 "$(unpacked_kb "$bd")"
head -c 1025 /dev/zero > "$bd/f"; assert_eq 2 "$(unpacked_kb "$bd")"
# a file that cannot be read still counts (its size, not its content), and a folder that cannot be read is reported, never left out
# of the sum (root reads anything: skipped there)
if [[ "$(id -u)" != 0 ]]; then
  ub="$WORK/ub"; mkdir -p "$ub/d"; head -c 1025 /dev/zero > "$ub/f"; chmod 000 "$ub/f"
  assert_eq 2 "$(unpacked_kb "$ub")"
  chmod 000 "$ub/d"
  [[ "$(size_problem "$ub")" == *"could not be read"* ]] || fail "release-zip-slim: an unreadable folder was left out of the size sum without a word"
  chmod 700 "$ub/d"; chmod 600 "$ub/f"
fi
echo "release-zip-slim: the size bound counts file bytes (folders and tiny files cost nothing), rounds up, fails past $SIZE_CAP_KB KB (tools/caps.tsv) and reports a folder it cannot read"

echo "release-zip-slim: ok (revert checks: dropping scripts/ or go.mod, forgetting tests/ or the developer-only files, or losing the tour images each fails the check)"
