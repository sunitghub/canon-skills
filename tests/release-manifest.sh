#!/usr/bin/env bash
# release-manifest (t-34f1) — tools/release-manifest.sh reads the published manifest (https://getcanon.dev/releases.txt, one
# `<tag> <zip sha256> <tag commit sha>` line per release) and answers for one tag. It trusts a release only when the manifest has exactly
# one distinct well-formed line for it; everything else refuses with a reason. The manifest is untrusted input, so the hostile shapes and a
# random loop are here. Nothing touches the network: CANON_MANIFEST_URL points at files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
SCRIPT="$ROOT/tools/release-manifest.sh"
command -v curl >/dev/null 2>&1 || { echo "release-manifest: FAIL curl is missing, this test cannot run" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
H1="$(printf 'a%.0s' $(seq 1 64))"; C1="$(printf 'b%.0s' $(seq 1 40))"
H2="$(printf 'c%.0s' $(seq 1 64))"; C2="$(printf 'd%.0s' $(seq 1 40))"
GOOD="v0.3.0 $H1 $C1"

furl() {   # file URL for curl: Git for Windows' curl is a native build that does not understand /tmp, so give it C:/Users/... there
  if command -v cygpath >/dev/null 2>&1; then printf 'file:///%s' "$(cygpath -m "$1")"; else printf 'file://%s' "$1"; fi
}
look() {   # look <manifest file> [tag]: prints the script's output and sets $code
  set +e; out="$(CANON_MANIFEST_URL="$(furl "$1")" bash "$SCRIPT" "${2-v0.3.0}" 2>&1)"; code=$?; set -e
}
ok() {   # ok <label> <manifest file> <expected "sha commit">
  look "$2"; [[ "$code" == 0 ]] || fail "release-manifest: $1 was refused: $out"
  assert_eq "$3" "$out"
}
refuses() {   # refuses <label> <manifest file> <expected message part> [tag]
  look "$2" "${4-v0.3.0}"; [[ "$code" != 0 ]] || fail "release-manifest: did not refuse $1: $out"
  assert_contains "$out" "$3"
  [[ "$out" != *"$H1"* ]] || fail "release-manifest: $1 refused but still printed a hash: $out"
}
mf() { local f; f="$(mktemp "$WORK/m.XXXXXX")"; printf '%b' "$1" > "$f"; printf '%s' "$f"; }

# Accepted shapes.
ok "a plain line" "$(mf "$GOOD\n")" "$H1 $C1"
ok "a line among comments, blanks and other releases" "$(mf "# canon releases\n\nv0.2.0 $H2 $C2\n$GOOD\nv0.4.0 $H2 $C2\n")" "$H1 $C1"
ok "CRLF line endings" "$(mf "$GOOD\r\nv0.2.0 $H2 $C2\r\n")" "$H1 $C1"
ok "no trailing newline" "$(mf "$GOOD")" "$H1 $C1"
ok "two trailing CRs (install.ps1 trims them all)" "$(mf "$GOOD\r\r\n")" "$H1 $C1"
ok "the same line twice" "$(mf "$GOOD\n$GOOD\n")" "$H1 $C1"
ok "a malformed line for another tag is ignored" "$(mf "v0.9.0 NOT-A-HASH\n$GOOD\n")" "$H1 $C1"
echo "release-manifest: reads the tag's one line, through comments, other releases, CRLF and a bad line for another tag"

# Refused shapes: each says why and prints no hash.
refuses "an empty file" "$(mf "")" "not in the release manifest"
refuses "comments only" "$(mf "# nothing\n# here\n")" "not in the release manifest"
refuses "a different release only" "$(mf "v0.2.0 $H2 $C2\n")" "not in the release manifest"
refuses "an entry hidden in a comment" "$(mf "# $GOOD\n")" "not in the release manifest"
refuses "a prefix of the tag" "$(mf "v0.3.01 $H1 $C1\nv0.3 $H1 $C1\n")" "not in the release manifest"
refuses "uppercase hex" "$(mf "v0.3.0 $(printf '%s' "$H1" | tr a-f A-F) $C1\n")" "malformed"
refuses "a short sha256" "$(mf "v0.3.0 ${H1%?} $C1\n")" "malformed"
refuses "a long sha256" "$(mf "v0.3.0 ${H1}a $C1\n")" "malformed"
refuses "a short commit" "$(mf "v0.3.0 $H1 ${C1%?}\n")" "malformed"
refuses "a long commit" "$(mf "v0.3.0 $H1 ${C1}b\n")" "malformed"
refuses "a missing commit" "$(mf "v0.3.0 $H1\n")" "malformed"
refuses "a non-hex character" "$(mf "v0.3.0 ${H1%?}g $C1\n")" "malformed"
refuses "tab separators" "$(mf "v0.3.0\t$H1\t$C1\n")" "malformed"
refuses "a leading space" "$(mf " $GOOD\n")" "malformed"
refuses "a trailing space" "$(mf "$GOOD \n")" "malformed"
refuses "an extra field" "$(mf "$GOOD extra\n")" "malformed"
refuses "a CR inside the sha256 (install.ps1 refuses it, so must this)" "$(mf "v0.3.0 ${H1:0:10}\r${H1:10} $C1\n")" "malformed"
refuses "a CR inside the tag field (not that tag at all)" "$(mf "v0.3.0\r $H1 $C1\n")" "not in the release manifest"
refuses "a CR between the fields" "$(mf "v0.3.0 $H1\r $C1\n")" "malformed"
refuses "a trailing comment" "$(mf "$GOOD # ok\n")" "malformed"
refuses "two different values for the tag" "$(mf "$GOOD\nv0.3.0 $H2 $C2\n")" "twice with different values"
refuses "a good line then a bad one for the same tag" "$(mf "$GOOD\nv0.3.0 oops\n")" "malformed"
refuses "a NUL byte" "$(mf "$GOOD\n\0\n")" "NUL"
big="$WORK/big"; head -c 2000000 /dev/zero | tr '\0' 'x' > "$big"; printf '\n%s\n' "$GOOD" >> "$big"
refuses "a file over 1 MB" "$big" "cannot read"
printf '%s\n' "$GOOD" > "$WORK/dir.txt"
refuses "a missing file" "$WORK/no-such-file" "cannot read"
refuses "a folder" "$WORK" "refusing"
head -c 4096 /dev/urandom > "$WORK/bin"; refuses "random binary" "$WORK/bin" "refusing"
# Plain http is refused even when the server answers with a valid manifest (a real local server, so the refusal is the protocol rule and not a dead port).
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$WORK/www"; printf '%s\n' "$GOOD" > "$WORK/www/releases.txt"
  (cd "$WORK/www" && exec python3 -I -u -m http.server 0 --bind 127.0.0.1 > "$WORK/http.log" 2>&1) & HTTP_PID=$!
  port=""; for _ in $(seq 1 50); do port="$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$WORK/http.log" | head -1)"; [ -n "$port" ] && break; sleep 0.1; done
  [ -n "$port" ] || { kill "$HTTP_PID" 2>/dev/null; fail "release-manifest: the local test server did not start: $(cat "$WORK/http.log")"; }
  set +e; out="$(CANON_MANIFEST_URL="http://127.0.0.1:$port/releases.txt" bash "$SCRIPT" v0.3.0 2>&1)"; code=$?; set -e
  kill "$HTTP_PID" 2>/dev/null; wait "$HTTP_PID" 2>/dev/null || true
  [[ "$code" != 0 ]] || fail "release-manifest: read a manifest over plain http: $out"; assert_contains "$out" "cannot read"
else
  echo "release-manifest: SKIPPED the plain-http refusal check (no python3 for a local test server on this machine)"
fi
echo "release-manifest: refuses empty, comment-only, hex of the wrong case or length, tabs, a trailing comment, a conflict, a NUL byte, a huge file, a missing file, a folder, binary and plain http"

# The tag argument is validated before anything is read.
for t in '' v1 v1.2 1.2.3 main ../v0.3.0 'v0.3.0 x' 'v0.3.0;ls' '-x' 'v0.3.0/' 'V0.3.0'; do
  set +e; out="$(CANON_MANIFEST_URL="$(furl "$(mf "$GOOD\n")")" bash "$SCRIPT" "$t" 2>&1)"; code=$?; set -e
  [[ "$code" != 0 ]] || fail "release-manifest: accepted the tag '$t': $out"
  assert_contains "$out" "tag must look like"
done
echo "release-manifest: refuses a tag that is not vN.N.N"

# 6,000 lines (about 740 KB, under the 1 MB cap), the one we want last.
f="$WORK/long"; : > "$f"; i=0; while [ $i -lt 60 ]; do for j in 1 2 3 4 5 6 7 8 9 10; do for k in 1 2 3 4 5 6 7 8 9 10; do printf 'v1.%s.%s %s %s\n' "$i" "$((j * 10 + k))" "$H2" "$C2"; done; done; i=$((i + 1)); done >> "$f"
printf '%s\n' "$GOOD" >> "$f"; ok "six thousand lines" "$f" "$H1 $C1"

# Random loop: take the good line, damage it at random, and compare with the rule as the spec states it. Anything the rule does not accept must be
# refused, and anything it accepts must come back exactly. (RANDOM is seeded so a failure repeats.)
RANDOM=34; N="${CANON_FUZZ_N:-150}"; strict='^v[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64} [0-9a-f]{40}$'
alphabet=('a' 'F' '0' ' ' $'\t' 'v' '.' '#' 'z' '-' '/' '"' "'" '$' '`' ';')
accepted=0; refused=0
for ((n = 0; n < N; n++)); do
  line="$GOOD"; steps=$((RANDOM % 3 + 1))
  for ((s = 0; s < steps; s++)); do
    pos=$((RANDOM % ${#line})); ch="${alphabet[$((RANDOM % ${#alphabet[@]}))]}"
    case $((RANDOM % 3)) in
      0) line="${line:0:pos}$ch${line:pos+1}" ;;     # replace
      1) line="${line:0:pos}$ch${line:pos}" ;;       # insert
      2) line="${line:0:pos}${line:pos+1}" ;;        # delete
    esac
  done
  f="$(mktemp "$WORK/f.XXXXXX")"; printf '%s\n' "$line" > "$f"
  look "$f"
  first="${line%% *}"
  if [[ "$line" =~ $strict && "$first" == v0.3.0 ]]; then
    [[ "$code" == 0 ]] || fail "release-manifest: random loop refused a well-formed line [$line]: $out"
    assert_eq "$(printf '%s' "$line" | cut -d' ' -f2,3)" "$out"; accepted=$((accepted + 1))
  else
    [[ "$code" != 0 ]] || fail "release-manifest: random loop accepted a damaged line [$line]: $out"
    refused=$((refused + 1))
  fi
done
echo "release-manifest: $N damaged lines, $accepted still well-formed and accepted exactly, $refused refused"
echo "release-manifest: ok"
