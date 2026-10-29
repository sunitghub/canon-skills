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
  https://nodejs.org/dist/index.json) key=node_index ;;
  https://api.osv.dev/v1/query)
    name="$(printf '%s' "$body" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    ver="$(printf '%s' "$body" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
    [[ "$body" == *'"ecosystem":"npm"'* ]] || { echo "curl: (22) stub: OSV query without ecosystem npm: $body" >&2; exit 22; }
    key="osv_$(printf '%s' "${name}_${ver:-ANY}" | tr '@/' '__')" ;;
  *) echo "curl: (6) stub: unexpected URL $url" >&2; exit 6 ;;
esac
echo "$key" >> "$STUB_DIR/calls"
if [[ -e "$STUB_DIR/$key.fail" ]]; then echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; fi
if [[ -e "$STUB_DIR/$key" ]]; then cat "$STUB_DIR/$key"; exit 0; fi
echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
EOF
printf '#!/bin/sh\necho "real curl called in a test: $*" >&2\nexit 99\n' > "$WORK/nonet/curl"
chmod +x "$WORK/bin/stub-curl" "$WORK/nonet/curl"

# a fixture template with fixed pins: the cases never move when the real template's pins are bumped
TPLF="$WORK/template.yml"
printf '%s\n' 'jobs:' '  grade:' '    steps:' '      - name: Set up a patched Node' '        uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0' \
  '        with:' '          node-version: 22.23.4         # exact' '          package-manager-cache: false' '      - name: Install Claude Code CLI' \
  '        run: npm install -g @anthropic-ai/claude-code@2.1.309' '      - name: Checkout the PR' '        with:' '          node-version: 99.9.9' > "$TPLF"
# a fixture manifest with fixed rows (xterm 5.3.0 as first vendored): the cases test the checker, not the vendored release,
# so they never move when tools/vendored.tsv is bumped (t-d689)
MANF="$WORK/vendored.tsv"
printf '%s\t%s\t%s\t%s\thttps://github.com/xtermjs/xterm.js\tMIT\t%s\t%s\n' \
  xterm.js xterm @xterm/xterm 5.3.0 f0aea0f7 terminal xterm.css xterm @xterm/xterm 5.3.0 832f3f2c stylesheet \
  xterm-addon-fit.js xterm-addon-fit @xterm/addon-fit 0.8.0 10f3194c fit > "$MANF"
NODEIDX='[{"version":"v24.1.0","date":"2026-10-01","lts":false,"security":true},{"version":"v22.23.4","date":"2026-10-20","files":["linux-x64"],"npm":"10.9.0","lts":"Jod","security":true},{"version":"v22.23.3","date":"2026-10-12","lts":"Jod","security":false}]'

ADV='{"vulns":[{"id":"GHSA-test-plnt-0001","summary":"planted","aliases":["CVE-2099-0001"],"affected":[{"package":{"name":"xterm","ecosystem":"npm"},"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"5.3.1"}]}]}],"severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:N"}],"database_specific":{"severity":"HIGH"}}]}'
OLD='{"vulns":[{"id":"GHSA-old0-only-3900","affected":[{"ranges":[{"type":"SEMVER","events":[{"introduced":"3.9.0"},{"fixed":"3.9.2"}]}]}],"database_specific":{"severity":"CRITICAL"}}]}'

stubs() {   # stubs <xterm latest> <addon latest>: a fresh STUB_DIR, both registries answer, OSV answers {} for the vendored versions
  STUB_DIR="$(mktemp -d "$WORK/stub.XXXXXX")"; export STUB_DIR; TEMPLATE_FILE=""
  printf '{"name":"@xterm/xterm","version":"%s","dist":{"tarball":"x"}}' "$1" > "$STUB_DIR/npm__xterm_xterm"
  printf '{"name":"@xterm/addon-fit","version":"%s"}' "$2" > "$STUB_DIR/npm__xterm_addon-fit"
  echo '{}' > "$STUB_DIR/osv_xterm_5.3.0"; echo '{}' > "$STUB_DIR/osv_xterm-addon-fit_0.8.0"
  printf '%s' "$ADV" > "$STUB_DIR/osv_xterm_ANY"; printf '%s' "$OLD" > "$STUB_DIR/osv_xterm_3.9.0"
  printf '%s' "$NODEIDX" > "$STUB_DIR/node_index"                                        # the template pins: Node 22.23.4 (the newest of line 22), CLI 2.1.309
  printf '{"name":"@anthropic-ai/claude-code","version":"2.1.309"}' > "$STUB_DIR/npm__anthropic-ai_claude-code"
  echo '{}' > "$STUB_DIR/osv__anthropic-ai_claude-code_2.1.309"
}
run() {   # run <script> [args]: OUT and RC, with the mode in $NOJQ
  set +e
  OUT="$(PATH="$WORK/nonet:$PATH" VENDORED_MANIFEST="$MANF" VENDORED_CURL="$WORK/bin/stub-curl" VENDORED_NO_JQ="$NOJQ" VENDORED_TEMPLATE="${TEMPLATE_FILE:-$TPLF}" GITHUB_STEP_SUMMARY="${SUMMARY_FILE:-}" bash "$@" 2>&1)"
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

# t-2d0f: the CI gate template's Node and CLI pins
pins() {   # pins <node> <cli>: a template with other pins (TEMPLATE_FILE)
  TEMPLATE_FILE="$WORK/pins.yml"; sed -e "s/node-version: 22\.23\.4/node-version: $1/" -e "s/claude-code@2\.1\.309/claude-code@$2/" "$TPLF" > "$TEMPLATE_FILE"
}
nodeidx() { printf '%s' "$1" > "$STUB_DIR/node_index"; }
NOTSEC='{"version":"v22.24.0","date":"2026-10-30","lts":"Jod","security":false}'
SEC5='{"version":"v22.23.5","date":"2026-10-24","lts":"Jod","security":true}'
case_node_security() {
  stubs 5.3.0 0.8.0; nodeidx "[$SEC5,${NODEIDX#[}"; run "$1"
  want 1 "ADVISORY: node 22.23.4 pinned in tools/canon-gate-template.yml has a newer security release: fixed in 22.23.5" \
    "| node 22.23.4 (CI gate) | 22.23.4 | 22.23.5 | 1 patch | security release (fixed in 22.23.5) |" "FAIL: an advisory affects"
}
case_node_current() { stubs 5.3.0 0.8.0; nodeidx "[$SEC5,${NODEIDX#[}"; pins 22.23.5 2.1.309; run "$1"; want 0 "| node 22.23.5 (CI gate) | 22.23.5 | 22.23.5 | up to date | none |" "every package is up to date"; }
case_node_nonsecurity() {
  stubs 5.3.0 0.8.0; nodeidx "[$NOTSEC,${NODEIDX#[}"; run "$1"
  want 0 "newer version: node 22.24.0 (pinned 22.23.4, 1 minor behind; not a security release)" "| node 22.23.4 (CI gate) | 22.23.4 | 22.24.0 | 1 minor | none |"
}
case_node_no_security_line() { stubs 5.3.0 0.8.0; nodeidx '[{"version":"v22.23.4","security":false},{"version":"v22.23.3","security":false}]'; run "$1"; want 0 "| node 22.23.4 (CI gate) |" "none |"; }
case_node_other_major() { stubs 5.3.0 0.8.0; nodeidx '[{"version":"v24.2.0","security":true},{"version":"v220.23.9","security":true}]'; run "$1"; want 2 "has no release of major 22" "| node 22.23.4 (CI gate) | 22.23.4 | lookup failed |"; }
case_node_decoy() {   # a "version"/"security" text inside another field or a nested object is not an entry's own key
  stubs 5.3.0 0.8.0; nodeidx '[{"version":"v22.23.4","note":"\"version\":\"v22.99.9\",\"security\":true","extra":{"version":"v22.98.0","security":true},"security":false}]'; run "$1"
  want 0 "| node 22.23.4 (CI gate) | 22.23.4 | 22.23.4 | up to date | none |"
}
case_node_garbage() {
  local bad; for bad in '<html>busy</html>' '[]' '{"version":"v22.23.5","security":true}' '[{"version":"v22.23.5"}]' '[{"security":true}]' '[{"version":"v22.23.5","security":"yes"}]' '[{"version":"v22.23.5","security":true}] x' '[{"version":"v22.23.5","security":true}'; do
    stubs 5.3.0 0.8.0; nodeidx "$bad"; run "$1"; want 2 "Node index (https://nodejs.org/dist/index.json) answered something unreadable" "| lookup failed |" >/dev/null || { echo "answer '$bad': $OUT"; return 1; }
  done
}
case_node_curl_error() { stubs 5.3.0 0.8.0; : > "$STUB_DIR/node_index.fail"; run "$1"; want 2 "Node index lookup failed (https://nodejs.org/dist/index.json)" "503" "advisories are unknown, not absent"; }
case_cli_advisory() {
  stubs 5.3.0 0.8.0; printf '%s' "$ADV" > "$STUB_DIR/osv__anthropic-ai_claude-code_2.1.309"; run "$1"
  want 1 "ADVISORY: @anthropic-ai/claude-code 2.1.309 pinned in tools/canon-gate-template.yml is affected by GHSA-test-plnt-0001 (HIGH, fixed in 5.3.1)" \
    "| @anthropic-ai/claude-code (CI gate) | 2.1.309 | 2.1.309 | up to date | GHSA-test-plnt-0001 (HIGH, fixed in 5.3.1) |"
}
case_cli_clean_newer() {
  stubs 5.3.0 0.8.0; printf '{"version":"2.2.0"}' > "$STUB_DIR/npm__anthropic-ai_claude-code"; run "$1"
  want 0 "newer version: @anthropic-ai/claude-code 2.2.0 (pinned 2.1.309, 1 minor behind)" "| 2.1.309 | 2.2.0 | 1 minor | none |"
}
case_cli_unreadable() { stubs 5.3.0 0.8.0; echo '<html>x</html>' > "$STUB_DIR/osv__anthropic-ai_claude-code_2.1.309"; run "$1"; want 2 "OSV lookup for @anthropic-ai/claude-code 2.1.309 answered something unreadable"; }
case_cli_npm_error() { stubs 5.3.0 0.8.0; : > "$STUB_DIR/npm__anthropic-ai_claude-code.fail"; run "$1"; want 2 "npm registry lookup failed for @anthropic-ai/claude-code" "| lookup failed | ? |"; }
case_pin_missing() {   # a pin the script cannot find exits 2 and names the template line it looked for
  stubs 5.3.0 0.8.0; TEMPLATE_FILE="$WORK/nopins.yml"; grep -vE 'node-version:|claude-code@' "$TPLF" > "$TEMPLATE_FILE"; run "$1"
  want 2 "no exact 'node-version: x.y.z' in the actions/setup-node step of tools/canon-gate-template.yml" \
    "no single 'npm install -g @anthropic-ai/claude-code@x.y.z' line in tools/canon-gate-template.yml" "| node (CI gate) | not found |"
}
case_pin_unparsable() { stubs 5.3.0 0.8.0; pins 22 2.1.309; run "$1"; want 2 "no exact 'node-version: x.y.z'" "(found: 22)"; }
case_worst_wins() {   # a failing vendored row and a failing template row: 2 over 1 over 0
  stubs 5.3.0 0.8.0; printf '%s' "$ADV" > "$STUB_DIR/osv_xterm_5.3.0"; nodeidx "[$SEC5,${NODEIDX#[}"; run "$1"; want 1 "ADVISORY: xterm 5.3.0" "fixed in 22.23.5" || return 1
  : > "$STUB_DIR/osv__anthropic-ai_claude-code_2.1.309.fail"; run "$1"; want 2 "ADVISORY: xterm 5.3.0" "fixed in 22.23.5" "OSV lookup failed for @anthropic-ai/claude-code" || return 1
  stubs 5.3.0 0.8.0; : > "$STUB_DIR/osv_xterm_5.3.0.fail"; nodeidx "[$SEC5,${NODEIDX#[}"; run "$1"; want 2 "fixed in 22.23.5" "OSV lookup failed for xterm"
}
case_template_rows() {   # --summary carries both template rows into $GITHUB_STEP_SUMMARY
  stubs 5.3.0 0.8.0; SUMMARY_FILE="$WORK/tsummary.md"; : > "$SUMMARY_FILE"; run "$1" --summary; local r=$? s; s="$(cat "$SUMMARY_FILE")"; SUMMARY_FILE=""
  [[ "$s" == *"| node 22.23.4 (CI gate) | 22.23.4 | 22.23.4 | up to date | none |"* && "$s" == *"| @anthropic-ai/claude-code (CI gate) | 2.1.309 | 2.1.309 | up to date | none |"* ]] \
    || { echo "rows missing from the summary: $s"; return 1; }
  want 0 "every package is up to date"
}
CASES="$CASES case_node_security case_node_current case_node_nonsecurity case_node_no_security_line case_node_other_major case_node_decoy case_node_garbage case_node_curl_error case_cli_advisory case_cli_clean_newer case_cli_unreadable case_cli_npm_error case_pin_missing case_pin_unparsable case_worst_wins case_template_rows"

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
OUT="$(PATH="$WORK/nonet:$PATH" VENDORED_MANIFEST="$M" VENDORED_CURL="$WORK/bin/stub-curl" VENDORED_TEMPLATE="$TPLF" VENDORED_NO_JQ=1 bash "$SCRIPT" 2>&1)" && RC=0 || RC=$?
want 0 "| xterm | 5.3.0 | 5.3.0 | up to date | none |" >/dev/null || fail "check-vendored: same-track row or skipped lines: $OUT"
printf 'xterm.css\txterm\t@xterm/xterm\t5.3.0\n' >> "$M"; printf '\n' >> "$M"
OUT="$(PATH="$WORK/nonet:$PATH" VENDORED_MANIFEST="$M" VENDORED_CURL="$WORK/bin/stub-curl" VENDORED_TEMPLATE="$TPLF" VENDORED_NO_JQ=1 bash "$SCRIPT" 2>&1)" && RC=0 || RC=$?
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
revert case_node_security "0 1" 's/\(\( k > pk && k > fixedk \)\)/(( 0 ))/'
revert case_node_other_major "0 1" 's/^  \(\( found \)\) \|\|/  true ||/'
revert case_node_garbage "0" 's/all\(\.\[\]; type == "object" and \(\.version \| type\) == "string" and \(\.security \| type\) == "boolean"\)/true/'
revert case_node_garbage "1" 's/if \(ver != "" && \(sec == "true" \|\| sec == "false"\)\)/if (ver != "")/'
revert case_node_decoy "1" 's/d = 3; st = "after"; continue \}/d = 2; st = "key"; continue }/'   # a nested object read as the entry's own keys
revert case_cli_advisory "0 1" 's/^      AFFECTED=1$/      AFFECTED=0/;s/^(.*NOTES\+=\("ADVISORY: \$CLI.*)$/\1/'

echo "check-vendored: ok (24 cases on modes [$MODES], template pins, version gaps, advisory columns, manifest rows, --summary, --sha, usage; $n reverts caught)"
