#!/usr/bin/env bash
# check-vendored (t-93ff) — scripts/check-vendored.sh against stubbed npm registry and OSV answers; nothing here touches
# the network (VENDORED_CURL points at a stub, and a `curl` on PATH that fails loudly catches any call that slips past it).
# Every case runs on the jq path (when jq exists) and on the grep/sed fallback (VENDORED_NO_JQ=1). Each case is then
# shown by a revert: the line that handles it is broken in a scratch copy of the script, and the case must fail.
# Bash 3.2-safe.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
SCRIPT="$ROOT/scripts/check-vendored.sh"
T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/check-vendored.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

# the stub: a canned answer per URL and request body, read from $STUB_DIR/<key>; <key>.fail makes it fail like curl -f
mkdir -p "$WORK/bin" "$WORK/nonet"
cat > "$WORK/bin/stub-curl" <<'EOF'
#!/usr/bin/env bash
url=""; body=""
while [[ $# -gt 0 ]]; do case "$1" in -d) body="$2"; shift 2 ;; -H|-X|--max-time) shift 2 ;; *) url="$1"; shift ;; esac; done
case "$url" in
  https://registry.npmjs.org/*/latest) key="npm_$(printf '%s' "${url#https://registry.npmjs.org/}" | sed 's#/latest$##; s#[@/]#_#g')" ;;
  https://api.osv.dev/v1/query)
    name="$(printf '%s' "$body" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    ver="$(printf '%s' "$body" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
    [[ "$body" == *'"ecosystem":"npm"'* ]] || { echo "curl: (22) stub: OSV query without ecosystem npm: $body" >&2; exit 22; }
    key="osv_${name}_${ver:-ANY}" ;;
  *) echo "curl: (6) stub: unexpected URL $url" >&2; exit 6 ;;
esac
echo "$key" >> "$STUB_DIR/calls"
if [[ -e "$STUB_DIR/$key.fail" ]]; then echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; fi
if [[ -e "$STUB_DIR/$key" ]]; then cat "$STUB_DIR/$key"; exit 0; fi
echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
EOF
printf '#!/bin/sh\necho "real curl called in a test: $*" >&2\nexit 99\n' > "$WORK/nonet/curl"
chmod +x "$WORK/bin/stub-curl" "$WORK/nonet/curl"

ADV='{"vulns":[{"id":"GHSA-test-plnt-0001","summary":"planted","aliases":["CVE-2099-0001"],"affected":[{"package":{"name":"xterm","ecosystem":"npm"},"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"5.3.1"}]}]}],"severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:N"}],"database_specific":{"severity":"HIGH"}}]}'
OLD='{"vulns":[{"id":"GHSA-old0-only-3900","affected":[{"ranges":[{"type":"SEMVER","events":[{"introduced":"3.9.0"},{"fixed":"3.9.2"}]}]}],"database_specific":{"severity":"CRITICAL"}}]}'

stubs() {   # stubs <xterm latest> <addon latest>: a fresh STUB_DIR, both registries answer, OSV answers {} for the vendored versions
  STUB_DIR="$(mktemp -d "$WORK/stub.XXXXXX")"; export STUB_DIR
  printf '{"name":"@xterm/xterm","version":"%s","dist":{"tarball":"x"}}' "$1" > "$STUB_DIR/npm__xterm_xterm"
  printf '{"name":"@xterm/addon-fit","version":"%s"}' "$2" > "$STUB_DIR/npm__xterm_addon-fit"
  echo '{}' > "$STUB_DIR/osv_xterm_5.3.0"; echo '{}' > "$STUB_DIR/osv_xterm-addon-fit_0.8.0"
  printf '%s' "$ADV" > "$STUB_DIR/osv_xterm_ANY"; printf '%s' "$OLD" > "$STUB_DIR/osv_xterm_3.9.0"
}
run() {   # run <script> [args]: OUT and RC, with the mode in $NOJQ
  set +e
  OUT="$(PATH="$WORK/nonet:$PATH" VENDORED_CURL="$WORK/bin/stub-curl" VENDORED_NO_JQ="$NOJQ" GITHUB_STEP_SUMMARY="${SUMMARY_FILE:-}" bash "$@" 2>&1)"
  RC=$?
  set -e
}
want() {   # want <rc> <substring...>: print why not, return 1
  [[ "$RC" == "$1" ]] || { echo "exit $RC, want $1: $OUT"; return 1; }
  shift; local s; for s in "$@"; do [[ "$OUT" == *"$s"* ]] || { echo "no '$s' in: $OUT"; return 1; }; done
}

# the cases: each takes the script to run and returns non-zero (saying why) when the behaviour is wrong
case_up_to_date() { stubs 5.3.0 0.8.0; run "$1"; want 0 "| 5.3.0 | 5.3.0 | up to date | none |" "every package is up to date"; }
case_newer() {
  stubs 6.0.0 0.11.0; run "$1"
  want 0 "| xterm (now @xterm/xterm) | 5.3.0 | 6.0.0 | 1 major | none | https://github.com/xtermjs/xterm.js/releases |" \
    "| 0.8.0 | 0.11.0 | 3 minor |" "newer version: @xterm/xterm 6.0.0" "a newer version exists (information, not a failure)"
}
case_advisory() {
  stubs 5.3.0 0.8.0; printf '%s' "$ADV" > "$STUB_DIR/osv_xterm_5.3.0"; run "$1"
  want 1 "GHSA-test-plnt-0001 (HIGH, fixed in 5.3.1)" "ADVISORY: xterm 5.3.0 is affected by GHSA-test-plnt-0001" "FAIL: an advisory affects"
}
case_other_version() { stubs 5.3.0 0.8.0; run "$1"; want 0 "every package is up to date" || return 1; [[ "$OUT" != *GHSA* ]] || { echo "advisory leaked: $OUT"; return 1; }; }
case_registry_error() {
  stubs 5.3.0 0.8.0; : > "$STUB_DIR/npm__xterm_xterm.fail"; run "$1"
  want 2 "npm registry lookup failed for @xterm/xterm" "503" "FAIL: a lookup failed; advisories are unknown, not absent"
}
case_osv_error() {
  stubs 5.3.0 0.8.0; : > "$STUB_DIR/osv_xterm-addon-fit_0.8.0.fail"; run "$1"
  want 2 "OSV lookup failed for xterm-addon-fit 0.8.0" "| 0.8.0 | 0.8.0 | up to date | lookup failed |" "advisories are unknown, not absent"
}
case_bad_registry() { stubs 5.3.0 0.8.0; echo '<html>busy</html>' > "$STUB_DIR/npm__xterm_addon-fit"; run "$1"; want 2 "npm registry lookup for @xterm/addon-fit" "answered no readable version"; }
case_bad_osv() { stubs 5.3.0 0.8.0; echo '{"vulns":[{"summary":"no id"}]}' > "$STUB_DIR/osv_xterm_5.3.0"; run "$1"; want 2 "OSV lookup for xterm 5.3.0 answered something unreadable"; }
CASES="case_up_to_date case_newer case_advisory case_other_version case_registry_error case_osv_error case_bad_registry case_bad_osv"

MODES="1"; if command -v jq >/dev/null 2>&1; then MODES="0 1"; else echo "check-vendored: jq not installed; only the fallback path runs"; fi
for NOJQ in $MODES; do
  for c in $CASES; do why="$("$c" "$SCRIPT")" || fail "check-vendored ($c, VENDORED_NO_JQ=$NOJQ): $why"; done
done
# xterm.js and xterm.css are one release: one registry and one OSV lookup, not two
NOJQ=1; stubs 5.3.0 0.8.0; run "$SCRIPT"
assert_eq "1 1" "$(grep -cx npm__xterm_xterm "$STUB_DIR/calls") $(grep -cx osv_xterm_5.3.0 "$STUB_DIR/calls")"

# --summary appends the same table to $GITHUB_STEP_SUMMARY; without --summary it writes nothing there
NOJQ=1; stubs 6.0.0 0.11.0; SUMMARY_FILE="$WORK/summary.md"; echo "earlier step" > "$SUMMARY_FILE"
run "$SCRIPT"; [[ "$(cat "$SUMMARY_FILE")" == "earlier step" ]] || fail "check-vendored: wrote the summary without --summary"
run "$SCRIPT" --summary; s="$(cat "$SUMMARY_FILE")"
assert_contains "$s" "earlier step"; assert_contains "$s" "| package | vendored | latest | behind |"; assert_contains "$s" "| 6.0.0 | 1 major |"
SUMMARY_FILE=""

# --sha prints exactly the manifest row's hash, by name or by path, and nothing else
for f in xterm.js xterm.css xterm-addon-fit.js; do
  row="$(awk -F'\t' -v f="$f" '$1 == f {print $7}' "$ROOT/tools/vendored.tsv")"
  assert_eq "$row" "$(bash "$SCRIPT" --sha "$f")"
  assert_eq "$row" "$(bash "$SCRIPT" --sha "$ROOT/tools/canon-go/internal/daemon/web/vendor/$f")"
done

# mutation-sweep follow-ups (t-93ff): the edges a surviving mutant showed no test reached
# how far behind: patch, minor, and a "latest" older than the vendored version (a deprecated package's tag)
for pair in "5.3.2|2 patch" "5.4.1|1 minor" "4.3.5|ahead of latest" "4.19.1|ahead of latest" "5.2.5|ahead of latest"; do
  NOJQ=1; stubs "${pair%%|*}" 0.8.0; run "$SCRIPT"
  want 0 "| 5.3.0 | ${pair%%|*} | ${pair#*|} |" >/dev/null || fail "check-vendored: latest ${pair%%|*} should read '${pair#*|}': $OUT"
done
# advisory columns: CVSS-only severity (jq reads the score; the fallback says n/a), no fix, two fixed-in versions
CV='{"vulns":[{"id":"GHSA-cvss-only-0001","severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:L"}]},{"id":"GHSA-two0-fixs-0002","affected":[{"ranges":[{"events":[{"introduced":"0"},{"fixed":"5.3.1"}]},{"events":[{"introduced":"5.4.0"},{"fixed":"5.4.2"}]}]}]}]}'
for NOJQ in $MODES; do
  stubs 5.3.0 0.8.0; printf '%s' "$CV" > "$STUB_DIR/osv_xterm_5.3.0"; run "$SCRIPT"
  if [[ "$NOJQ" == 0 ]]; then sev="CVSS:3.1/AV:L"; else sev="severity n/a"; fi
  want 1 "GHSA-cvss-only-0001 ($sev, fixed in no fix)" "GHSA-two0-fixs-0002 (severity n/a, fixed in 5.3.1 or 5.4.2)" >/dev/null \
    || fail "check-vendored: advisory columns (VENDORED_NO_JQ=$NOJQ): $OUT"
done
# an unreadable OSV answer that is not JSON at all, and a registry answer with two "version" values (jq reads the top level)
for NOJQ in $MODES; do
  for bad in '<html>rate limited</html>' '{} trailing' 'x{"vulns":[]}' '{"vulns":[]}x'; do
    stubs 5.3.0 0.8.0; printf '%s\n' "$bad" > "$STUB_DIR/osv_xterm-addon-fit_0.8.0"; run "$SCRIPT"
    want 2 "OSV lookup for xterm-addon-fit 0.8.0 answered something unreadable" >/dev/null || fail "check-vendored: OSV answer '$bad' (VENDORED_NO_JQ=$NOJQ): $OUT"
  done
  stubs 5.3.0 0.8.0; echo '{"version":"6.0.0","engines":{"version":"1.0.0"}}' > "$STUB_DIR/npm__xterm_xterm"; run "$SCRIPT"
  if [[ "$NOJQ" == 0 ]]; then want 0 "| 6.0.0 | 1 major |" >/dev/null || fail "check-vendored: jq top-level version: $OUT"
  else want 2 "npm registry lookup for @xterm/xterm" >/dev/null || fail "check-vendored: fallback took one of two versions: $OUT"; fi
done
# the manifest: comment and blank lines are skipped, a row whose track is its own package shows the bare name, a short row fails
NOJQ=1; stubs 5.3.0 0.8.0; M="$WORK/manifest.tsv"
printf '# header\n\nxterm.js\txterm\txterm\t5.3.0\thttps://github.com/xtermjs/xterm.js\tMIT\tabc\twhy\n' > "$M"
printf '{"name":"xterm","version":"5.3.0"}' > "$STUB_DIR/npm_xterm"
OUT="$(PATH="$WORK/nonet:$PATH" VENDORED_MANIFEST="$M" VENDORED_CURL="$WORK/bin/stub-curl" VENDORED_NO_JQ=1 bash "$SCRIPT" 2>&1)" && RC=0 || RC=$?
want 0 "| xterm | 5.3.0 | 5.3.0 | up to date | none |" >/dev/null || fail "check-vendored: same-track row or skipped lines: $OUT"
printf 'xterm.css\txterm\t@xterm/xterm\t5.3.0\n' >> "$M"; printf '\n' >> "$M"
OUT="$(PATH="$WORK/nonet:$PATH" VENDORED_MANIFEST="$M" VENDORED_CURL="$WORK/bin/stub-curl" VENDORED_NO_JQ=1 bash "$SCRIPT" 2>&1)" && RC=0 || RC=$?
want 2 "manifest row xterm.css has fewer than 8 columns" >/dev/null || fail "check-vendored: short row: $OUT"
OUT="$(VENDORED_MANIFEST="$WORK/none.tsv" bash "$SCRIPT" 2>&1)" && RC=0 || RC=$?
want 2 "check-vendored: no manifest at $WORK/none.tsv" >/dev/null || fail "check-vendored: missing manifest: $OUT"
# a registry failure shows in the table, not only in the notes
NOJQ=1; stubs 5.3.0 0.8.0; : > "$STUB_DIR/npm__xterm_addon-fit.fail"; run "$SCRIPT"
want 2 "| xterm-addon-fit (now @xterm/addon-fit) | 0.8.0 | lookup failed | ? |" >/dev/null || fail "check-vendored: registry failure row: $OUT"
# --summary with no $GITHUB_STEP_SUMMARY (a local run) writes nowhere and prints no error
NOJQ=1; stubs 5.3.0 0.8.0; SUMMARY_FILE=""; run "$SCRIPT" --summary
want 0 "every package is up to date" >/dev/null || fail "check-vendored: --summary without a summary file: $OUT"
[[ "$OUT" != *"No such file"* ]] || fail "check-vendored: --summary without a summary file wrote somewhere: $OUT"
# usage: --sha exits 0; a bad option, a bare --sha, extra arguments and a missing file each exit 64 with a reason
bash "$SCRIPT" --sha xterm.js >/dev/null || fail "check-vendored: --sha exited non-zero"
for a in "--bogus" "--sha" "--sha xterm.js extra"; do
  OUT="$(bash "$SCRIPT" $a 2>&1)" && RC=0 || RC=$?
  want 64 "Usage: scripts/check-vendored.sh" >/dev/null || fail "check-vendored: '$a' should print usage and exit 64: $OUT"
done
OUT="$(bash "$SCRIPT" --sha no-such-file 2>&1)" && RC=0 || RC=$?
want 64 "check-vendored: no such file: no-such-file" >/dev/null || fail "check-vendored: --sha on a missing file: $OUT"

# revert checks: break the line that handles a case in a scratch copy; that case must then fail
n=0
revert() {   # revert <case> <modes> <sed expression>
  n=$((n + 1)); local m="$WORK/mutant.$n.sh"; sed -E "$3" "$SCRIPT" > "$m"
  cmp -s "$m" "$SCRIPT" && fail "check-vendored: revert '$3' changed nothing"
  for NOJQ in $2; do
    [[ " $MODES " == *" $NOJQ "* ]] || continue
    if "$1" "$m" >/dev/null; then fail "check-vendored: $1 still passes with '$3' (VENDORED_NO_JQ=$NOJQ)"; fi
  done
}
revert case_up_to_date "0 1" 's/then echo "up to date"/then echo "0 patch"/'
revert case_newer "0 1" 's/\|\| \{ NEWER=1;/|| true || { NEWER=1;/'
revert case_advisory "0 1" 's/^      AFFECTED=1$/      AFFECTED=0/'
revert case_other_version "0 1" 's/,\\"version\\":\\"\$2\\"//'
revert case_registry_error "0 1" 's/\|\| \{ echo "npm registry lookup failed/|| true || { echo "npm registry lookup failed/'
revert case_osv_error "0 1" 's/\|\| \{ echo "OSV lookup failed/|| true || { echo "OSV lookup failed/'
revert case_bad_registry "0 1" 's/if ! grep -qxE "\$SEMVER" <<< "\$v" \|\|.*then (.*)$/if false; then \1/'
revert case_bad_osv "0" 's/and all\(\(\.vulns \/\/ \[\]\)\[\]; type == "object" and \(\.id \| type\) == "string"\)//'
revert case_bad_osv "1" 's/&& ! grep -qE .*<<< "\$flat"; then$/\&\& false; then/'
revert case_advisory "1" 's/ \|\| \[\[ -n "\$chunk" \]\]//'   # the last chunk has no newline: read alone drops it, a silent miss
revert case_advisory "1" 's/s\/\^@@ID@@\/\/p/s\/^@@NOPE@@\/\/p/'
revert case_up_to_date "1" 's/^    if grep -qE .\^\[\[:space:\]\]\*\\\{\[\[:space:\]\]\*\\\}.*return 0; fi$/    true/'

echo "check-vendored: ok (8 cases on modes [$MODES], version gaps, advisory columns, manifest rows, --summary, --sha, usage; $n reverts caught)"
