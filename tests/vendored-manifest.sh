#!/usr/bin/env bash
# vendored-manifest (t-93ff) — tools/vendored.tsv owns the facts about each third-party file the daemon embeds from
# web/vendor/: every file has a row, every row has its file, each file's SHA-256 matches its row (nobody edits a vendored
# file by hand), and THIRD-PARTY-NOTICES.md has a `## <package> <version>` heading for each row.
# tests/fetch-daemon.sh check 10b (each file named in the notices) stays. Each failure is planted in a scratch copy below,
# so a pass proves the checks bite. Bash 3.2-safe; hashes with sha256sum or shasum -a 256, whichever exists.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
MANIFEST=tools/vendored.tsv
VENDOR=tools/canon-go/internal/daemon/web/vendor

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check() {   # check <root>: print one line per broken rule, nothing when all hold
  local r="$1" m="$1/$MANIFEST" f pkg track ver up lic sum why
  [[ -f "$m" ]] || { echo "missing $MANIFEST"; return 0; }
  for f in "$r/$VENDOR"/*; do
    [[ -e "$f" ]] || continue
    awk -F'\t' -v f="$(basename "$f")" '!/^#/ && $1 == f {found=1} END {exit !found}' "$m" \
      || echo "no manifest row for $VENDOR/$(basename "$f")"
  done
  while IFS=$'\t' read -r f pkg track ver up lic sum why; do
    [[ -z "$f" || "$f" == \#* ]] && continue
    [[ -n "$why" ]] || { echo "row $f: fewer than 8 tab-separated columns"; continue; }
    if [[ ! -f "$r/$VENDOR/$f" ]]; then echo "row $f: no such file in $VENDOR"; continue; fi
    [[ "$(sha256 "$r/$VENDOR/$f")" == "$sum" ]] || echo "row $f: SHA-256 differs from the file (edited by hand, or the row is stale)"
    grep -qxF "## $pkg $ver" "$r/THIRD-PARTY-NOTICES.md" || echo "row $f: no '## $pkg $ver' heading in THIRD-PARTY-NOTICES.md"
  done < "$m"
}

got="$(check "$ROOT")"
[[ -z "$got" ]] || fail "vendored-manifest: $got"
rows="$(grep -cv '^#' "$ROOT/$MANIFEST")"
[[ "$rows" -ge 3 ]] || fail "vendored-manifest: expected the three vendored xterm rows, saw $rows"

# revert checks: break one rule per scratch copy; the check must name it
T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/vendored-manifest.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
n=0
plant() {   # plant <expected substring> <shell snippet run in the copy>
  n=$((n + 1)); local d="$WORK/$n"; mkdir -p "$d/tools" "$d/$VENDOR"
  cp "$ROOT/$MANIFEST" "$d/$MANIFEST"; cp "$ROOT/$VENDOR"/* "$d/$VENDOR/"; cp "$ROOT/THIRD-PARTY-NOTICES.md" "$d/"
  (cd "$d" && eval "$2")
  local out; out="$(check "$d")"
  [[ "$out" == *"$1"* ]] || fail "vendored-manifest: planting '$2' should report '$1', got: ${out:-nothing}"
}
plant "no manifest row for $VENDOR/extra.js" "echo 'x' > $VENDOR/extra.js"
plant "row xterm.css: no such file" "rm $VENDOR/xterm.css"
plant "row xterm.js: SHA-256 differs" "printf '\n' >> $VENDOR/xterm.js"
plant "row xterm-addon-fit.js: SHA-256 differs" "sed -i.bak 's/10f3194c/00f3194c/' $MANIFEST"
plant "row xterm.js: no '## xterm 5.3.0' heading" "sed -i.bak 's/^## xterm 5.3.0\$/## xterm 5.2.0/' THIRD-PARTY-NOTICES.md"
plant "row xterm-addon-fit.js: no '## xterm-addon-fit 0.9.0' heading" "sed -i.bak 's/	0\\.8\\.0	/	0.9.0	/' $MANIFEST"
plant "fewer than 8 tab-separated columns" "sed -i.bak 's/	the stylesheet.*\$//' $MANIFEST"
plant "missing $MANIFEST" "rm $MANIFEST"

echo "vendored-manifest: ok ($rows rows match web/vendor/ and THIRD-PARTY-NOTICES.md; $n planted breaks caught)"
