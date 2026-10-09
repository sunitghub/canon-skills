#!/usr/bin/env bash
# release-zip (t-34f1) — scripts/release-zip.sh builds canon-X.Y.Z.zip from a release tag's committed tree and prints the one manifest
# line `<tag> <zip sha256> <tag commit sha>` that getcanon.dev/releases.txt carries. The zip is a release asset because GitHub's own
# archive zips are not byte-stable. Throwaway repo per case; nothing here touches the network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v git >/dev/null 2>&1; then echo "release-zip: git absent — skipped"; exit 0; fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
zip_names() {   # file names (not folders) inside a zip, or nothing when this machine has no way to list one
  if command -v unzip >/dev/null 2>&1; then unzip -Z1 "$1" | grep -v '/$' || true
  elif command -v python3 >/dev/null 2>&1; then python3 -I -c 'import sys,zipfile; print("\n".join(n for n in zipfile.ZipFile(sys.argv[1]).namelist() if not n.endswith("/")))' "$1"
  else return 1; fi
}

R="$WORK/repo"; git init -q -b main "$R"; mkdir -p "$R/scripts" "$R/tools"
cp "$ROOT/scripts/release-zip.sh" "$R/scripts/" 2>/dev/null || true
echo 0.3.0 > "$R/VERSION"; echo 'echo hi' > "$R/tools/canon"; echo 'tracked' > "$R/README.md"
git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm release
git -C "$R" "${ident[@]}" tag -a v0.3.0 -m "canon 0.3.0"
commit="$(git -C "$R" rev-parse 'v0.3.0^{commit}')"
echo later > "$R/late.txt"; git -C "$R" "${ident[@]}" add late.txt; git -C "$R" "${ident[@]}" commit -qm "after the release"   # HEAD moves past the tag: the zip is the TAG's tree
echo 'dirty edit' >> "$R/README.md"; echo secret > "$R/untracked.txt"    # neither may enter the zip
OUT="$WORK/out"; mkdir -p "$OUT"

zipit() { (cd "$R" && bash scripts/release-zip.sh "$@" 2>&1); }

# Success: one line, shaped for the manifest, equal to an independent hash of the file.
set +e; line="$(zipit v0.3.0 "$OUT")"; code=$?; set -e
[[ "$code" == 0 ]] || fail "release-zip: exited $code: $line"
[ -f "$OUT/canon-0.3.0.zip" ] || fail "release-zip: no canon-0.3.0.zip in $OUT (got: $line)"
assert_eq "1" "$(printf '%s\n' "$line" | wc -l | tr -d ' ')"
re='^v[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64} [0-9a-f]{40}$'
[[ "$line" =~ $re ]] || fail "release-zip: the line is not a manifest line: $line"
assert_eq "v0.3.0 $(sha256_of "$OUT/canon-0.3.0.zip") $commit" "$line"
echo "release-zip: prints one manifest line equal to the zip's own hash and the tag's commit"

# Content: the committed tree under canon-0.3.0/, nothing from the working tree.
if names="$(zip_names "$OUT/canon-0.3.0.zip")"; then
  want="$(git -C "$R" ls-tree -r --name-only v0.3.0 | sed 's#^#canon-0.3.0/#' | LC_ALL=C sort)"
  assert_eq "$want" "$(printf '%s\n' "$names" | LC_ALL=C sort)"
  refute=$(printf '%s\n' "$names" | grep -c 'untracked.txt\|late.txt' || true); assert_eq "0" "$refute"
  echo "release-zip: holds exactly the tag's committed files under canon-0.3.0/ (dirty and untracked files absent)"
else
  echo "release-zip: SKIPPED the zip-contents check (no unzip and no python3 on this machine)"
fi

# The same tag builds the same bytes, so a lost asset can be rebuilt and still match its manifest line.
OUT2="$WORK/out2"; mkdir -p "$OUT2"; line2="$(zipit v0.3.0 "$OUT2")"
assert_eq "$line" "$line2"
echo "release-zip: rebuilding the tag gives the same hash"

# Every refusal says why and writes nothing.
refuse() {   # refuse <label> <expected message part> <args...>
  local label="$1" part="$2"; shift 2
  local o2="$WORK/o-$RANDOM"; mkdir -p "$o2"
  set +e; out="$(zipit "$@" "$o2" 2>&1)"; code=$?; set -e
  [[ "$code" != 0 ]] || fail "release-zip: did not refuse $label: $out"
  assert_contains "$out" "$part"
  assert_eq "" "$(ls "$o2")"
}
refuse "a tag that does not exist" "tag" v9.9.9
refuse "a branch name" "tag" main
refuse "a traversal" "tag" ../v0.3.0
refuse "an empty tag" "tag" ''
refuse "a malformed version" "tag" v1.2
set +e; out="$(zipit v0.3.0 "$WORK/no-such-dir" 2>&1)"; code=$?; set -e
[[ "$code" != 0 ]] || fail "release-zip: did not refuse a missing output folder"
assert_contains "$out" "output folder"
echo "release-zip: refuses a missing tag, a non-release name, and a missing output folder, writing nothing"
echo "release-zip: ok"
