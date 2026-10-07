#!/usr/bin/env bash
# fetch-win-binaries (t-9383): on Windows (Git Bash) tools/fetch-daemon.sh puts the three exes at tools/*-win.exe, each only after
# its SHA-256 equals the committed manifest line, and never touches an exe that is already there when something fails.
# Everything runs in a throwaway repo with stub curl/uname; each "exe" is a script that leaves a marker if it is ever executed.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches the tools/sprint-check-go source path
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

R="$WORK/repo"; mkdir -p "$R/tools/cockpit-daemon" "$R/tools/sprint-check-go" "$R/tools/sprint-headless-json-go"
cp "$ROOT/tools/fetch-daemon.sh" "$R/tools/"
for d in cockpit-daemon sprint-check-go sprint-headless-json-go; do printf 'package main\n// %s\n' "$d" > "$R/tools/$d/main.go"; done
printf 'module x\n\ngo 1.26.5\n' > "$R/tools/cockpit-daemon/go.mod"; echo 0.3.0 > "$R/VERSION"
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
printf '/tools/*-win.exe\n' >> "$R/.git/info/exclude"   # as the repo's own .gitignore does: a fetched exe is not a dirty tree
k_d="$(git -C "$R" rev-parse HEAD:tools/cockpit-daemon | cut -c1-12)"
k_b="$(git -C "$R" rev-parse HEAD:tools/sprint-check-go | cut -c1-12)"
k_h="$(git -C "$R" rev-parse HEAD:tools/sprint-headless-json-go | cut -c1-12)"
MARK="$WORK/executed"
D="$R/tools/cockpit-daemon-win.exe"; B="$R/tools/sprint-check-win.exe"; H="$R/tools/sprint-headless-json-win.exe"

# Release assets served by the stub, by file name.
A="$WORK/assets"; mkdir -p "$A"
mk() { printf '#!/bin/sh\ntouch "%s"\n# %s\n' "$MARK" "$2" > "$1"; chmod +x "$1"; }
mk "$A/cockpit-daemon-windows-amd64.exe" daemon; mk "$A/sprint-check-windows-amd64.exe" board; mk "$A/sprint-headless-json-windows-amd64.exe" headless
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
sd="$(sha "$A/cockpit-daemon-windows-amd64.exe")"; sb="$(sha "$A/sprint-check-windows-amd64.exe")"; sh_="$(sha "$A/sprint-headless-json-windows-amd64.exe")"

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/uname" <<'EOF2'
#!/bin/sh
case "$1" in -s) echo MINGW64_NT-10.0 ;; -m) echo x86_64 ;; *) echo MINGW64_NT-10.0 ;; esac
EOF2
cat > "$STUBS/curl" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "${STUB_CURL_RC:-0}" = 0 ] || exit "$STUB_CURL_RC"
url=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; url="$1"; shift; done
f="$STUB_ASSETS/$(basename "$url")"
[ -f "$f" ] || exit 22
cp "$f" "$out"
EOF2
chmod +x "$STUBS"/*
export STUB_LOG="$WORK/curl.log" STUB_ASSETS="$A"

manifest() { # writes the manifest the install carries (all three good lines unless overridden by args)
  printf '# header\n%s windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n%s sprint-headless-json-windows-amd64 %s\n' \
    "$k_d" "${1:-$sd}" "$k_b" "${2:-$sb}" "$k_h" "${3:-$sh_}" > "$R/tools/cockpit-daemon.sha256"
}
run_fetch() { # [script-dir]; sets out, rc
  rm -f "$MARK"; : > "$STUB_LOG"
  set +e; out="$(PATH="$STUBS:/usr/bin:/bin" bash "${1:-$R}/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
}
clean() { rm -f "$D" "$B" "$H" "$R"/tools/.*-win.exe.*; rm -rf "$D" "$B" "$H"; unset STUB_CURL_RC || true; }
no_leftovers() { [[ -z "$(ls -A "$R/tools" | grep -E '^\..*-win\.exe\.' || true)" ]] || fail "temp file left behind: $(ls -A "$R/tools")"; }

# 1. all three arrive at their fixed paths, verified, named by key and target, never executed
clean; manifest; run_fetch
[[ "$rc" == 0 ]] || fail "good fetch failed ($rc): $out"
cmp -s "$D" "$A/cockpit-daemon-windows-amd64.exe" && cmp -s "$B" "$A/sprint-check-windows-amd64.exe" && cmp -s "$H" "$A/sprint-headless-json-windows-amd64.exe" || fail "installed files differ from the assets"
assert_contains "$out" "fetched windows-amd64 $k_d, sha256 verified"
assert_contains "$out" "fetched sprint-check-windows-amd64 $k_b, sha256 verified"
assert_contains "$out" "fetched sprint-headless-json-windows-amd64 $k_h, sha256 verified"
log="$(cat "$STUB_LOG")"
assert_contains "$log" "releases/download/cockpit-daemon-$k_d/cockpit-daemon-windows-amd64.exe"
assert_contains "$log" "releases/download/sprint-check-$k_b/sprint-check-windows-amd64.exe"
assert_contains "$log" "releases/download/sprint-headless-json-$k_h/sprint-headless-json-windows-amd64.exe"
[[ ! -e "$MARK" ]] || fail "the fetch executed a binary"; no_leftovers
# 2. second run: current by hash, nothing downloaded
run_fetch; [[ "$rc" == 0 ]]; [[ ! -s "$STUB_LOG" ]] || fail "current binaries were downloaded again"; assert_contains "$out" "up to date"

# 3. bad downloads for each component: existing exe byte-identical, no leftovers; the board and daemon are required (exit 1), the helper only warns (exit 0)
printf '<html>404</html>' > "$WORK/html"; head -c 20 "$A/sprint-check-windows-amd64.exe" > "$WORK/trunc"; : > "$WORK/empty"
mk "$WORK/wrong" other
for comp in daemon board headless; do
  for bad in html trunc empty wrong; do
    clean; manifest
    case "$comp" in
      daemon) f="$A/cockpit-daemon-windows-amd64.exe"; dest="$D"; want=1 ;;
      board) f="$A/sprint-check-windows-amd64.exe"; dest="$B"; want=1 ;;
      headless) f="$A/sprint-headless-json-windows-amd64.exe"; dest="$H"; want=0 ;;
    esac
    cp "$f" "$WORK/keep"; cp "$WORK/$bad" "$f"                       # the release now serves a bad file
    printf 'OLD-%s' "$comp" > "$dest"; before="$(cksum < "$dest")"      # an exe is already in place
    run_fetch
    cp "$WORK/keep" "$f"
    assert_eq "$before" "$(cksum < "$dest")"                           # kept byte for byte
    [[ "$rc" == "$want" ]] || fail "$comp/$bad: want exit $want got $rc: $out"
    assert_contains "$out" "does not match its checksum"; no_leftovers; [[ ! -e "$MARK" ]] || fail "$comp/$bad was executed"
  done
done

# 4. no download possible (offline): an existing exe stays, a missing one stays missing, required ones exit 1
clean; manifest; printf 'OLD' > "$B"; export STUB_CURL_RC=22; run_fetch
[[ "$rc" == 1 ]] || fail "offline fetch of required binaries should exit 1 (got $rc): $out"; assert_eq OLD "$(cat "$B")"; [[ ! -e "$D" && ! -e "$H" ]] || fail "something was created while offline"; no_leftovers
assert_contains "$out" "download failed"; assert_contains "$out" "run canon update"
unset STUB_CURL_RC

# 5. manifest shapes that must refuse: missing, other key, non-hex, short, wrong target; nothing downloaded, nothing installed
check_refused() { clean; run_fetch; [[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "$1: expected refusal, got rc=$rc log=$(cat "$STUB_LOG") out=$out"; no_leftovers; }
printf '# header\n' > "$R/tools/cockpit-daemon.sha256"; check_refused "empty manifest"
manifest "${sd:0:63}" "${sb:0:63}" "${sh_:0:63}"; check_refused "short checksums"
manifest "notahash" "notahash" "notahash"; check_refused "non-hex"
printf '%s windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n%s sprint-headless-json-windows-amd64 %s\n' "ffffffffffff" "$sd" "ffffffffffff" "$sb" "ffffffffffff" "$sh_" > "$R/tools/cockpit-daemon.sha256"; check_refused "other source key"
printf '%s darwin-arm64 %s\n%s windows-arm64 %s\n%s windows-arm64 %s\n' "$k_d" "$sd" "$k_b" "$sb" "$k_h" "$sh_" > "$R/tools/cockpit-daemon.sha256"; check_refused "other targets"
# CRLF line ends (a Windows checkout with core.autocrlf) are tolerated, not refused
printf '%s windows-amd64 %s\r\n%s sprint-check-windows-amd64 %s\r\n%s sprint-headless-json-windows-amd64 %s\r\n' "$k_d" "$sd" "$k_b" "$sb" "$k_h" "$sh_" > "$R/tools/cockpit-daemon.sha256"
clean; run_fetch; [[ "$rc" == 0 ]] || fail "a CRLF manifest must still work (rc=$rc): $out"; cmp -s "$B" "$A/sprint-check-windows-amd64.exe" || fail "CRLF manifest: board exe not installed"

# 6. a zip install has no .git: the NEWEST manifest line for the target names what to fetch
Z="$WORK/zip"; rm -rf "$Z"; cp -R "$R" "$Z"; rm -rf "$Z/.git"
printf '%s windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n%s sprint-headless-json-windows-amd64 %s\n%s windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n%s sprint-headless-json-windows-amd64 %s\n' \
  "111111111111" "$(printf 'x%.0s' {1..64} | tr x a)" "111111111111" "$(printf 'x%.0s' {1..64} | tr x a)" "111111111111" "$(printf 'x%.0s' {1..64} | tr x a)" \
  "$k_d" "$sd" "$k_b" "$sb" "$k_h" "$sh_" > "$Z/tools/cockpit-daemon.sha256"
rm -f "$Z"/tools/*-win.exe; rm -f "$MARK"; : > "$STUB_LOG"
set +e; out="$(PATH="$STUBS:/usr/bin:/bin" bash "$Z/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "a zip install (no .git) could not fetch ($rc): $out"
assert_contains "$(cat "$STUB_LOG")" "cockpit-daemon-$k_d/cockpit-daemon-windows-amd64.exe"; refute_contains "$(cat "$STUB_LOG")" "111111111111"
cmp -s "$Z/tools/sprint-check-win.exe" "$A/sprint-check-windows-amd64.exe" || fail "zip install did not get the board exe"
# 6b. a git checkout whose source tree differs from every manifest line is "not released yet": it never fetches an exe for different source
echo "// changed" >> "$R/tools/sprint-check-go/main.go"; git -C "$R" "${ident[@]}" commit -qam "board source changed"
manifest; clean; run_fetch
[[ "$rc" == 1 ]] || fail "a changed board source with an old manifest must refuse (rc=$rc): $out"
assert_contains "$out" "not released yet"; [[ ! -e "$B" ]] || fail "an exe for different source was installed"; assert_contains "$out" "fetched windows-amd64 $k_d"
git -C "$R" reset -q --hard HEAD~1

# 7. the destination is a directory: refuse, exit 1, no leftovers
clean; manifest; mkdir -p "$B"; run_fetch; [[ "$rc" == 1 ]] || fail "directory destination must fail: $out"; refute_contains "$out" "fetched sprint-check-windows-amd64"; no_leftovers; rm -rf "$B"

# 7b. the source-build fallback (Go present, download unavailable): a failing build leaves no temp file in tools/ (git would call the clone
# dirty and canon update would refuse) and keeps an existing exe; a working build installs all three. Stub go: -o <file> gets a marker script.
mkdir -p "$WORK/gostub"
cat > "$WORK/gostub/go" <<'EOF2'
#!/bin/sh
[ "$1" = env ] && { echo go1.99.0; exit 0; }
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
[ "${STUB_GO_FAIL:-0}" = 0 ] || exit 1
printf '#!/bin/sh\n# built\n' > "$out"
EOF2
chmod +x "$WORK/gostub/go"
run_fetch_go() { rm -f "$MARK"; : > "$STUB_LOG"; set +e; out="$(PATH="$WORK/gostub:$STUBS:/usr/bin:/bin" bash "$R/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e; }
clean; manifest; printf 'OLD' > "$B"; export STUB_CURL_RC=22 STUB_GO_FAIL=1; run_fetch_go
[[ "$rc" == 1 ]] || fail "failing source builds must exit 1 (got $rc): $out"; assert_eq OLD "$(cat "$B")"; no_leftovers
assert_contains "$out" "building from source failed"
dirty="$(git -C "$R" status --porcelain tools | grep -v 'tools/cockpit-daemon.sha256$' || true)"
[[ -z "$dirty" ]] || fail "a failed build left files that git sees: $dirty"
unset STUB_GO_FAIL; clean; manifest; export STUB_CURL_RC=22; run_fetch_go
[[ "$rc" == 0 ]] || fail "working source builds must provide the exes (got $rc): $out"
[[ -f "$D" && -f "$B" && -f "$H" ]] || fail "a working build did not install all three exes"; assert_contains "$out" "built from source"; no_leftovers
unset STUB_CURL_RC STUB_GO_FAIL; clean

# 8. malformed manifests, a few hundred random lines: never an install, never a crash
for i in $(seq 1 200); do
  python3 - "$i" "$R/tools/cockpit-daemon.sha256" "$k_d" "$k_b" <<'PY'
import random, sys
random.seed(int(sys.argv[1])); out, kd, kb = sys.argv[2], sys.argv[3], sys.argv[4]
junk = [b"", b"\r\n", b"\x00\xff\xfe", b"a" * 4096, b"../" * 40, b" ", b"nan", b"-1", b"0x" + b"f" * 62, b"\t", b"windows-amd64", b"sprint-check-windows-amd64"]
lines = []
for _ in range(random.randint(1, 8)):
    pick = random.random()
    if pick < 0.4:
        lines.append(random.choice([kd, kb]).encode() + b" " + random.choice([b"windows-amd64", b"sprint-check-windows-amd64"]) + b" " + random.choice(junk)[:80])
    else:
        lines.append(b" ".join(random.choice(junk) for _ in range(random.randint(0, 4))))
open(out, "wb").write(b"\n".join(lines) + b"\n")
PY
  clean; run_fetch
  [[ ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "fuzz case $i installed something from a malformed manifest: $out"
  [[ "$rc" == 1 ]] || fail "fuzz case $i: want exit 1, got $rc"
  [[ "$out" != *Traceback* && "$out" != *"syntax error"* && "$out" != *"unbound variable"* ]] || fail "fuzz case $i crashed: $out"
  [[ ! -s "$STUB_LOG" ]] || fail "fuzz case $i downloaded without a valid checksum"
  no_leftovers
done

echo "fetch-win-binaries: ok (three exes verified into place, kept on every failure, zip install by newest line, unreleased source refused, 200 malformed manifests)"
