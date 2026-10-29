#!/usr/bin/env bash
# fetch-win-binaries (t-9383, t-bdb0): on Windows (Git Bash) tools/fetch-daemon.sh puts the one program, canon-go (board and daemon), at
# tools/canon-go-win.exe only after its SHA-256 equals the committed canon-go-windows-amd64 manifest line, never touches an exe that is
# already there when something fails, and once it is in place removes the two exes it replaced (an install holds one exe, ~7 MB less).
# Protects install.ps1's Install-CanonBinaries, canon update and canon's start-time fetch on Windows.
# Everything runs in a throwaway repo with stub curl/uname; each "exe" is a script that leaves a marker if it is ever executed.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches a board binary spelling
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

# t-bdb0: one program (tools/canon-go/cmd/canon-go); tools/src-key.sh names its key
R="$WORK/repo"; M="$R/tools/canon-go"; mkdir -p "$M/cmd/canon-go" "$M/internal/daemon" "$M/internal/board" "$M/internal/common" "$M/internal/events" "$M/internal/term" "$M/internal/settings"
cp "$ROOT/tools/fetch-daemon.sh" "$ROOT/tools/src-key.sh" "$R/tools/"
for d in cmd/canon-go internal/daemon internal/board internal/common internal/events internal/term internal/settings; do printf 'package x\n// %s\n' "$d" > "$M/$d/x.go"; done
printf 'module x\n\ngo 1.26.5\n' > "$M/go.mod"; : > "$M/go.sum"; echo 0.3.0 > "$R/VERSION"
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
printf '/tools/*-win.exe\n' >> "$R/.git/info/exclude"   # as the repo's own .gitignore does: a fetched exe is not a dirty tree
srckey() { bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" "$2"' _ "$R" "$1" | cut -c1-12; }
k="$(srckey canon-go)"
k_h=381471fa46a0   # t-b62a: the retired headless helper's last key; real manifests keep its lines, and the fetch must ignore them
MARK="$WORK/executed"
E="$R/tools/canon-go-win.exe"; D="$R/tools/cockpit-daemon-win.exe"; B="$R/tools/sprint-check-win.exe"; H="$R/tools/sprint-headless-json-win.exe"

# Release assets served by the stub, by file name (the older programs' too: a manifest still names them, and they must never be fetched).
A="$WORK/assets"; mkdir -p "$A"
mk() { printf '#!/bin/sh\ntouch "%s"\n# %s\n' "$MARK" "$2" > "$1"; chmod +x "$1"; }
mk "$A/canon-go-windows-amd64.exe" canon-go; mk "$A/cockpit-daemon-windows-amd64.exe" daemon; mk "$A/sprint-check-windows-amd64.exe" board; mk "$A/sprint-headless-json-windows-amd64.exe" headless
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
se="$(sha "$A/canon-go-windows-amd64.exe")"; sd="$(sha "$A/cockpit-daemon-windows-amd64.exe")"; sb="$(sha "$A/sprint-check-windows-amd64.exe")"; sh_="$(sha "$A/sprint-headless-json-windows-amd64.exe")"

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

manifest() { # [canon-go sha]: the manifest the install carries: the older programs' lines (same key: they must not be used) and canon-go's
  printf '# header\n%s windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n%s sprint-headless-json-windows-amd64 %s\n%s canon-go-windows-amd64 %s\n' \
    "$k" "$sd" "$k" "$sb" "$k_h" "$sh_" "$k" "${1:-$se}" > "$R/tools/cockpit-daemon.sha256"
}
run_fetch() { # [script-dir]; sets out, rc
  rm -f "$MARK"; : > "$STUB_LOG"
  set +e; out="$(PATH="$STUBS:/usr/bin:/bin" bash "${1:-$R}/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
}
clean() { rm -rf "$E" "$D" "$B" "$H" "$R"/tools/.*-win.exe.*; unset STUB_CURL_RC || true; }
no_leftovers() { [[ -z "$(ls -A "$R/tools" | grep -E '^\..*-win\.exe\.' || true)" ]] || fail "temp file left behind: $(ls -A "$R/tools")"; }

# 1. the one exe arrives at its fixed path, verified, named by key and target, never executed; no other program is fetched
clean; manifest; run_fetch
[[ "$rc" == 0 ]] || fail "good fetch failed ($rc): $out"
cmp -s "$E" "$A/canon-go-windows-amd64.exe" || fail "the installed file differs from the asset"
[[ ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "a retired program was fetched"
assert_eq 1 "$(ls "$R"/tools/*.exe | wc -l | tr -d ' ')"   # one exe per install (t-bdb0)
assert_contains "$out" "fetched canon-go-windows-amd64 $k, sha256 verified"
log="$(cat "$STUB_LOG")"
assert_eq "1" "$(grep -c . <<<"$log")"
assert_contains "$log" "releases/download/canon-go-$k/canon-go-windows-amd64.exe"
[[ ! -e "$MARK" ]] || fail "the fetch executed a binary"; no_leftovers
# 2. second run: current by hash, nothing downloaded
run_fetch; [[ "$rc" == 0 ]]; [[ ! -s "$STUB_LOG" ]] || fail "a current exe was downloaded again"; assert_contains "$out" "up to date"

# 2b. an update from a v0.29.0 install: the two older exes go once canon-go is in place, and stay when it could not be fetched
clean; manifest; printf OLD-D > "$D"; printf OLD-B > "$B"; export STUB_CURL_RC=22; run_fetch; unset STUB_CURL_RC
[[ "$rc" == 1 && "$(cat "$D")" == OLD-D && "$(cat "$B")" == OLD-B ]] || fail "a failed fetch must keep the older exes ($rc): $out"
run_fetch; [[ "$rc" == 0 && -f "$E" && ! -e "$D" && ! -e "$B" ]] || fail "the older exes were not removed after canon-go arrived ($rc): $out"
assert_contains "$out" "removed tools/cockpit-daemon-win.exe (replaced by canon-go)"; assert_contains "$out" "removed tools/sprint-check-win.exe"
[[ -d "$R/tools" ]] || fail "tools/ itself was removed"

# 3. bad downloads: existing exe byte-identical, no leftovers, exit 1. Also an older program's asset served in its place (the hash of an
#    older program's line would match it: only the canon-go line counts)
printf '<html>404</html>' > "$WORK/html"; head -c 20 "$A/canon-go-windows-amd64.exe" > "$WORK/trunc"; : > "$WORK/empty"
mk "$WORK/wrong" other; cp "$A/sprint-check-windows-amd64.exe" "$WORK/older"
for bad in html trunc empty wrong older; do
  clean; manifest
  cp "$A/canon-go-windows-amd64.exe" "$WORK/keep"; cp "$WORK/$bad" "$A/canon-go-windows-amd64.exe"   # the release now serves a bad file
  printf 'OLD' > "$E"; before="$(cksum < "$E")"                                                         # an exe is already in place
  run_fetch
  cp "$WORK/keep" "$A/canon-go-windows-amd64.exe"
  assert_eq "$before" "$(cksum < "$E")"                                                                  # kept byte for byte
  [[ "$rc" == 1 ]] || fail "$bad: want exit 1 got $rc: $out"
  assert_contains "$out" "does not match its checksum"; no_leftovers; [[ ! -e "$MARK" ]] || fail "$bad was executed"
done

# 4. no download possible (offline): an existing exe stays, a missing one stays missing, exit 1
clean; manifest; printf 'OLD' > "$E"; export STUB_CURL_RC=22; run_fetch
[[ "$rc" == 1 ]] || fail "offline fetch should exit 1 (got $rc): $out"; assert_eq OLD "$(cat "$E")"; [[ ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "something was created while offline"; no_leftovers
assert_contains "$out" "download failed"; assert_contains "$out" "run canon update"
unset STUB_CURL_RC

# 5. manifest shapes that must refuse: missing, other key, non-hex, short, wrong target, only the older programs' lines; nothing downloaded or installed
check_refused() { clean; run_fetch; [[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$E" && ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "$1: expected refusal, got rc=$rc log=$(cat "$STUB_LOG") out=$out"; no_leftovers; }
printf '# header\n' > "$R/tools/cockpit-daemon.sha256"; check_refused "empty manifest"
manifest "${se:0:63}"; check_refused "short checksum"
manifest "notahash"; check_refused "non-hex"
printf '%s canon-go-windows-amd64 %s\n' "ffffffffffff" "$se" > "$R/tools/cockpit-daemon.sha256"; check_refused "other source key"
printf '%s canon-go-darwin-arm64 %s\n%s canon-go-windows-arm64 %s\n%s windows-amd64 %s\n' "$k" "$se" "$k" "$se" "$k" "$se" > "$R/tools/cockpit-daemon.sha256"; check_refused "other targets"
printf '%s windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n' "$k" "$sd" "$k" "$sb" > "$R/tools/cockpit-daemon.sha256"; check_refused "only the older programs' lines"
# CRLF line ends (a Windows checkout with core.autocrlf) are tolerated, not refused
printf '%s windows-amd64 %s\r\n%s canon-go-windows-amd64 %s\r\n' "$k" "$sd" "$k" "$se" > "$R/tools/cockpit-daemon.sha256"
clean; run_fetch; [[ "$rc" == 0 ]] || fail "a CRLF manifest must still work (rc=$rc): $out"; cmp -s "$E" "$A/canon-go-windows-amd64.exe" || fail "CRLF manifest: exe not installed"

# 6. a zip install has no .git: the NEWEST canon-go-windows-amd64 line names what to fetch
Z="$WORK/zip"; rm -rf "$Z"; cp -R "$R" "$Z"; rm -rf "$Z/.git"
aa="$(printf 'x%.0s' {1..64} | tr x a)"
printf '%s canon-go-windows-amd64 %s\n%s windows-amd64 %s\n%s canon-go-windows-amd64 %s\n%s sprint-check-windows-amd64 %s\n' \
  "111111111111" "$aa" "$k" "$sd" "$k" "$se" "222222222222" "$sb" > "$Z/tools/cockpit-daemon.sha256"
rm -f "$Z"/tools/*-win.exe; rm -f "$MARK"; : > "$STUB_LOG"
set +e; out="$(PATH="$STUBS:/usr/bin:/bin" bash "$Z/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "a zip install (no .git) could not fetch ($rc): $out"
assert_contains "$(cat "$STUB_LOG")" "canon-go-$k/canon-go-windows-amd64.exe"; refute_contains "$(cat "$STUB_LOG")" "111111111111"; refute_contains "$(cat "$STUB_LOG")" "222222222222"
cmp -s "$Z/tools/canon-go-win.exe" "$A/canon-go-windows-amd64.exe" || fail "zip install did not get the exe"
# 6b. a git checkout whose source tree differs from every manifest line is "not released yet": it never fetches an exe for different source
echo "// changed" >> "$M/internal/board/x.go"; git -C "$R" "${ident[@]}" commit -qam "board source changed"
manifest; clean; run_fetch
[[ "$rc" == 1 ]] || fail "a changed source with an old manifest must refuse (rc=$rc): $out"
assert_contains "$out" "not released yet"; [[ ! -e "$E" ]] || fail "an exe for different source was installed"
git -C "$R" reset -q --hard HEAD~1

# 7. the destination is a directory: refuse, exit 1, no leftovers
clean; manifest; mkdir -p "$E"; run_fetch; [[ "$rc" == 1 ]] || fail "directory destination must fail: $out"; refute_contains "$out" "fetched canon-go"; no_leftovers; rm -rf "$E"

# 7b. the source-build fallback (Go present, download unavailable): a failing build leaves no temp file in tools/ (git would call the clone
# dirty and canon update would refuse) and keeps an existing exe; a working build installs it. Stub go: -o <file> gets a marker script.
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
clean; manifest; printf 'OLD' > "$E"; export STUB_CURL_RC=22 STUB_GO_FAIL=1; run_fetch_go
[[ "$rc" == 1 ]] || fail "a failing source build must exit 1 (got $rc): $out"; assert_eq OLD "$(cat "$E")"; no_leftovers
assert_contains "$out" "building from source failed"
dirty="$(git -C "$R" status --porcelain tools | grep -v 'tools/cockpit-daemon.sha256$' || true)"
[[ -z "$dirty" ]] || fail "a failed build left files that git sees: $dirty"
unset STUB_GO_FAIL; clean; manifest; export STUB_CURL_RC=22; run_fetch_go
[[ "$rc" == 0 ]] || fail "a working source build must provide the exe (got $rc): $out"
[[ -f "$E" && ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "a working build did not install the one exe (and only it)"; assert_contains "$out" "built from source"; no_leftovers
unset STUB_CURL_RC STUB_GO_FAIL; clean

# 8. malformed manifests, a few hundred random lines: never an install, never a crash
for i in $(seq 1 200); do
  python3 - "$i" "$R/tools/cockpit-daemon.sha256" "$k" <<'PY'
import random, sys
random.seed(int(sys.argv[1])); out, k = sys.argv[2], sys.argv[3]
junk = [b"", b"\r\n", b"\x00\xff\xfe", b"a" * 4096, b"../" * 40, b" ", b"nan", b"-1", b"0x" + b"f" * 62, b"\t", b"windows-amd64", b"canon-go-windows-amd64"]
lines = []
for _ in range(random.randint(1, 8)):
    pick = random.random()
    if pick < 0.4:
        lines.append(k.encode() + b" " + random.choice([b"windows-amd64", b"canon-go-windows-amd64"]) + b" " + random.choice(junk)[:80])
    else:
        lines.append(b" ".join(random.choice(junk) for _ in range(random.randint(0, 4))))
open(out, "wb").write(b"\n".join(lines) + b"\n")
PY
  clean; run_fetch
  [[ ! -e "$E" && ! -e "$D" && ! -e "$B" && ! -e "$H" ]] || fail "fuzz case $i installed something from a malformed manifest: $out"
  [[ "$rc" == 1 ]] || fail "fuzz case $i: want exit 1, got $rc"
  [[ "$out" != *Traceback* && "$out" != *"syntax error"* && "$out" != *"unbound variable"* ]] || fail "fuzz case $i crashed: $out"
  [[ ! -s "$STUB_LOG" ]] || fail "fuzz case $i downloaded without a valid checksum"
  no_leftovers
done

echo "fetch-win-binaries: ok (one exe verified into place, older programs never fetched and removed after, kept on every failure, zip install by newest line, unreleased source refused, 200 malformed manifests)"
