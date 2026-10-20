#!/usr/bin/env bash
# fetch-daemon (t-60f7): tools/fetch-daemon.sh puts a daemon in place only after its SHA-256 matches the committed manifest.
# Everything runs in a throwaway repo with stub curl/uname/go; the "binary" is a script that drops a marker file if it is ever
# executed, so "never run an unverified download" is an assertion, not a hope.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

# A throwaway checkout: the script under test (+ tools/src-key.sh, which names the keys), a manifest, the Go module's sources, VERSION.
# t-8020: the daemon and the board are one module (tools/canon-go) with a key each; t-15d8: the board is the second required
# macOS/Linux component, so every case below runs through both. Each gets its own stamped asset; the stub curl serves the board's
# whenever a case asks for the good daemon asset, so a case names one asset and both components follow it.
R="$WORK/repo"; M="$R/tools/canon-go"; mkdir -p "$R/tools/cockpit-daemon" "$M/cmd/cockpit-daemon" "$M/cmd/sprint-check" "$M/internal/daemon" "$M/internal/board" "$M/internal/common" "$M/internal/events"
cp "$ROOT/tools/fetch-daemon.sh" "$ROOT/tools/src-key.sh" "$R/tools/"; cp "$ROOT/tools/cockpit-daemon/.gitignore" "$R/tools/cockpit-daemon/"   # tracked, as in canon: the folder only holds the built daemon
printf 'module x\n\ngo 1.26.5\n' > "$M/go.mod"; : > "$M/go.sum"; echo 0.3.0 > "$R/VERSION"
for d in cmd/cockpit-daemon cmd/sprint-check internal/daemon internal/board internal/common internal/events; do printf 'package x // %s\n' "$d" > "$M/$d/x.go"; done
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
srckey() { bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" "$2"' _ "$1" "$2"; }
full="$(srckey "$R" cockpit-daemon)"; key="${full:0:12}"; stamp="${full:0:8}"
fullb="$(srckey "$R" sprint-check)"; keyb="${fullb:0:12}"; stampb="${fullb:0:8}"
BIN="$R/tools/cockpit-daemon/cockpit-daemon"; BBIN="$R/tools/sprint-check-bin/sprint-check"; MARK="$WORK/executed"

# The "daemon": prints a version with the commit stamp; leaves a marker when run for anything but --version.
make_asset() { # <path> <stamp>
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "0.3.0 (%s)"; exit 0; }\ntouch "%s"\n' "$2" "$MARK" > "$1"; chmod +x "$1"
}
GOOD="$WORK/good"; make_asset "$GOOD" "$stamp"; GOODSHA="$(shasum -a 256 "$GOOD" | awk '{print $1}')"
GOODB="$WORK/goodb"; make_asset "$GOODB" "$stampb"; GOODSHAB="$(shasum -a 256 "$GOODB" | awk '{print $1}')"

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo "${STUB_OS:-Darwin}" ;; -m) echo "${STUB_ARCH:-arm64}" ;; *) echo "${STUB_OS:-Darwin}" ;; esac
EOF
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "${STUB_CURL_RC:-0}" = 0 ] || exit "$STUB_CURL_RC"
url=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; url="$1"; shift; done
asset="$STUB_ASSET"; case "$url" in */sprint-check-*) [ "$STUB_ASSET" = "$STUB_GOOD" ] && asset="$STUB_GOODB" ;; esac
cp "$asset" "$out"
EOF
mkdir -p "$WORK/gostub"
cat > "$WORK/gostub/go" <<'EOF'
#!/bin/sh
[ "$1" = env ] && { echo go1.99.0; exit 0; }
[ "$1" = version ] && { echo "$3: $(sed -n 's/^# toolchain=//p' "$3")"; exit 0; }   # t-7efe: release-daemon.sh checks each binary with `go version -m`; the stub's binaries record the GOTOOLCHAIN they were built with
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; [ "$1" = -ldflags ] && ld="$2"; pkg="$1"; shift; done
[ "${STUB_GO_FAIL:-0}" = 0 ] || exit 1
# t-8020: like the real go, build only a package that exists from here (./cmd/<component> in the module), stamped with its commit
[ -d "$pkg" ] && [ -n "$out" ] || { echo "go stub: no package $pkg in $PWD" >&2; exit 1; }
case "$ld" in *"-X main.commit="?*) ;; *) echo "go stub: no commit stamp" >&2; exit 1 ;; esac
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "0.3.0 (built)"; exit 0; }\ntouch "%s"\n# toolchain=%s\n' "$STUB_MARK" "${GOTOOLCHAIN:-}" > "$out"
EOF
chmod +x "$STUBS"/* "$WORK/gostub/go"
BASEPATH="/usr/bin:/bin"   # no go on it
export STUB_LOG="$WORK/curl.log" STUB_MARK="$MARK" STUB_GOOD="$GOOD" STUB_GOODB="$GOODB"

manifest() { # <sha> [target]   (writes the manifest the clone carries)
  printf '# header\n%s %s %s\n%s sprint-check-%s %s\n' "$key" "${2:-darwin-arm64}" "$1" "$keyb" "${2:-darwin-arm64}" "$GOODSHAB" > "$R/tools/cockpit-daemon.sha256"
}
fetch() { # env vars via caller; sets out, rc
  rm -f "$MARK"; : > "$STUB_LOG"
  set +e; out="$(PATH="${FETCH_PATH:-$STUBS:$BASEPATH}" bash "$R/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
}
reset() { rm -rf "$R/tools/cockpit-daemon/cockpit-daemon" "$R"/tools/cockpit-daemon/.cockpit-daemon.* "$R/tools/sprint-check-bin"; unset STUB_ASSET STUB_CURL_RC STUB_GO_FAIL STUB_OS STUB_ARCH FETCH_PATH 2>/dev/null || true; }
no_leftovers() { [[ -z "$(ls -A "$R/tools/cockpit-daemon" "$R/tools/sprint-check-bin" 2>/dev/null | grep '^\.\(cockpit-daemon\|sprint-check\)\.' || true)" ]] || fail "temp file left behind: $(ls -A "$R/tools/cockpit-daemon" "$R/tools/sprint-check-bin" 2>/dev/null)"; }

# 1. a download that matches is installed, named by the daemon commit and target, and never executed
reset; manifest "$GOODSHA"; export STUB_ASSET="$GOOD"
fetch; [[ "$rc" == 0 ]] || fail "matching download failed ($rc): $out"
assert_contains "$out" "fetched darwin-arm64 $key, sha256 verified"
assert_contains "$(cat "$STUB_LOG")" "releases/download/cockpit-daemon-$key/cockpit-daemon-darwin-arm64"
cmp -s "$BIN" "$GOOD" || fail "installed file differs from the download"; [[ -x "$BIN" ]] || fail "installed file is not executable"
assert_contains "$out" "fetched sprint-check-darwin-arm64 $keyb, sha256 verified"   # t-15d8: the board, same release flow
assert_contains "$(cat "$STUB_LOG")" "releases/download/sprint-check-$keyb/sprint-check-darwin-arm64"
cmp -s "$BBIN" "$GOODB" || fail "the board was not installed at tools/sprint-check-bin/sprint-check"; [[ -x "$BBIN" ]] || fail "the board is not executable"
[[ ! -e "$MARK" ]] || fail "the fetch executed the binary"; no_leftovers
# 2. second run: already current, no download
fetch; [[ "$rc" == 0 ]]; assert_contains "$out" "up to date"; [[ ! -s "$STUB_LOG" ]] || fail "an up-to-date daemon was downloaded again"

# 3. downloads that must be rejected: wrong content, an HTML error page, truncated, empty. Nothing installed, nothing executed, no leftovers.
for bad in wrong html truncated empty; do
  reset; manifest "$GOODSHA"
  case "$bad" in
    wrong) make_asset "$WORK/bad" "deadbeef" ;;
    html) printf '<html><body>404 Not Found</body></html>\n' > "$WORK/bad" ;;
    truncated) head -c 20 "$GOOD" > "$WORK/bad" ;;
    empty) : > "$WORK/bad" ;;
  esac
  export STUB_ASSET="$WORK/bad"; fetch
  [[ "$rc" == 1 ]] || fail "$bad download should fail, got $rc: $out"
  assert_contains "$out" "does not match its checksum"; assert_contains "$out" "Next:"
  [[ ! -e "$BIN" && ! -e "$BBIN" ]] || fail "$bad download was installed"; [[ ! -e "$MARK" ]] || fail "$bad download was executed"; no_leftovers
done

# 4. a bad download never replaces a daemon that is already there (stale: different stamp)
reset; manifest "$GOODSHA"; make_asset "$BIN" "00000000"; before="$(cksum < "$BIN")"; export STUB_ASSET="$WORK/bad"; fetch
[[ "$rc" == 1 ]] || fail "stale daemon + bad download should exit 1"; assert_eq "$before" "$(cksum < "$BIN")"; no_leftovers
# and a good download does replace the stale one
export STUB_ASSET="$GOOD"; fetch; [[ "$rc" == 0 ]] || fail "replacing a stale daemon failed ($rc): $out"; cmp -s "$BIN" "$GOOD" || fail "a stale daemon was not replaced by the verified download"

# 5. download fails: build from source when go exists, with its own message; with no go, say what to do
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"
fetch; [[ "$rc" == 0 ]] || fail "fallback build failed ($rc): $out"; assert_contains "$out" "built from source"; [[ -x "$BIN" && -x "$BBIN" ]] || fail "fallback build not installed"
assert_contains "$out" "sprint-check: built from source"   # t-15d8: an unreleased board change runs from source on a machine with Go
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 ]] || fail "no download and no go should exit 1"; assert_contains "$out" "download failed"; assert_contains "$out" "Go is not installed"; assert_contains "$out" "Next:"; [[ ! -e "$BIN" ]]
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_GO_FAIL=1 FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"; fetch
[[ "$rc" == 1 ]] || fail "a failed source build must exit 1 ($rc): $out"; assert_contains "$out" "building from source failed"; assert_contains "$out" "needs Go 1.26.5"; no_leftovers

# 6. no manifest line for this daemon commit (not released): never download, fall through
reset; printf '# header\n' > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 ]]; assert_contains "$out" "not released yet"; [[ ! -s "$STUB_LOG" ]] || fail "downloaded without a checksum to verify against"
reset; printf '%s darwin-arm64 notahash\n' "$key" > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "a malformed checksum line must refuse: $out"

reset; printf '%s darwin-arm64 %s\n' "ffffffffffff" "$GOODSHA" > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch   # a line for another daemon commit must not be used
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "a checksum for a different daemon commit was used: $out"
reset; printf '%s darwin-arm64 %s\n' "$key" "${GOODSHA:0:63}" > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch   # all hex but too short
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "a short checksum was accepted: $out"

# 7. platform mapping, including every spelling of the CPU, and an unsupported CPU; Windows (Git Bash) is covered by tests/fetch-win-binaries.sh
for spec in "Darwin arm64 darwin-arm64" "Darwin x86_64 darwin-amd64" "Linux aarch64 linux-arm64" "Linux x86_64 linux-amd64" "Linux amd64 linux-amd64"; do
  set -- $spec; reset; manifest "$GOODSHA" "$3"; export STUB_ASSET="$GOOD" STUB_OS="$1" STUB_ARCH="$2"; fetch
  [[ "$rc" == 0 ]] || fail "$spec failed ($rc): $out"; assert_contains "$(cat "$STUB_LOG")" "cockpit-daemon-$3"; assert_contains "$(cat "$STUB_LOG")" "sprint-check-$keyb/sprint-check-$3"
done
reset; export STUB_ARCH=riscv64; fetch; [[ "$rc" == 1 ]] || fail "an unknown CPU must exit 1 ($rc): $out"; assert_contains "$out" "no prebuilt binaries for CPU 'riscv64'"
reset; export STUB_OS=MINGW64_NT-10.0; fetch; [[ "$rc" == 1 && ! -s "$STUB_LOG" ]] || fail "Windows with no released binaries must fail without downloading (t-9383; the real cases are in tests/fetch-win-binaries.sh): $out"
reset

# 7b. the key is the daemon folder's tree hash, so it survives a shallow clone and later unrelated commits (a last-commit key would not)
echo later > "$R/README.md"; git -C "$R" add -A; git -C "$R" "${ident[@]}" commit -qm later
git clone -q --depth 1 "file://$R" "$WORK/shallow"; cp "$R/tools/cockpit-daemon.sha256" "$WORK/shallow/tools/" 2>/dev/null || true
manifest "$GOODSHA"; cp "$R/tools/cockpit-daemon.sha256" "$WORK/shallow/tools/"
reset; export STUB_ASSET="$GOOD"; rm -f "$MARK"; : > "$STUB_LOG"
set +e; out="$(PATH="$STUBS:$BASEPATH" bash "$WORK/shallow/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "a shallow clone could not find its manifest line ($rc): $out"; assert_contains "$out" "fetched darwin-arm64 $key, sha256 verified"
# 7c. timeouts, the no-build switch, a rejected download is said out loud even when the fallback build works, and mv/chmod failures are not reported as success
reset; manifest "$GOODSHA"; export STUB_ASSET="$GOOD"; fetch; assert_contains "$(cat "$STUB_LOG")" "--connect-timeout 10"
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"
set +e; out="$(CANON_FETCH_NO_BUILD=1 PATH="$FETCH_PATH" bash "$R/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 && ! -e "$BIN" ]] || fail "CANON_FETCH_NO_BUILD must not build ($rc): $out"; assert_contains "$out" "not building from source at start"
reset; manifest "$GOODSHA"; make_asset "$WORK/bad" deadbeef; export STUB_ASSET="$WORK/bad" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"; fetch
[[ "$rc" == 0 ]] || fail "fallback build failed: $out"; assert_contains "$out" "does not match its checksum"; assert_contains "$out" "built from source"
reset; manifest "$GOODSHA"; export STUB_ASSET="$GOOD"; mkdir -p "$BIN"; fetch   # the destination is a directory: the verified file cannot be installed
[[ "$rc" == 1 ]] || fail "an install that failed must not exit 0: $out"; refute_contains "$out" "fetched darwin"; rmdir "$BIN" 2>/dev/null || rm -rf "$BIN"; no_leftovers
# a leftover temp file (a fetch killed mid-way) must not make the clone look dirty: it is ignored, or canon update would refuse
touch "$R/tools/cockpit-daemon/.cockpit-daemon.AbC123"
[[ -z "$(git -C "$R" status --porcelain -- tools/cockpit-daemon)" ]] || fail "a leftover fetch temp file shows in git status: $(git -C "$R" status --porcelain)"
rm -f "$R/tools/cockpit-daemon/.cockpit-daemon.AbC123"; reset

# 8. not a git checkout: say so, do not guess a name
cp -R "$R" "$WORK/nogit"; rm -rf "$WORK/nogit/.git"
set +e; out="$(PATH="$STUBS:$BASEPATH" bash "$WORK/nogit/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a copy with no .git must exit 1 ($rc): $out"; assert_contains "$out" "is not a git checkout"

# 9. who calls it, and the resolvers say the same thing
assert_eq 1 "$(grep -c 'fetch-daemon.sh' "$ROOT/install.sh")"
assert_eq 2 "$(grep -c 'fetch-daemon.sh' "$ROOT/tools/canon")"   # canon update; canon at start for a missing Windows exe (t-9383)
grep -qF 'CANON_FETCH_NO_BUILD=1 bash "$SCRIPT_DIR/fetch-daemon.sh" --quiet' "$ROOT/tools/canon" || fail "canon at start on Windows must call the fetch with CANON_FETCH_NO_BUILD=1 (no Go there to build with)"
# t-15d8: start_cockpit_server owns the start-time fetch for canon and sprint-check: on Windows a missing exe, never built; on
# macOS/Linux every start, building an unreleased change (tests/cockpit-launch-lib.sh runs both)
assert_eq 2 "$(grep -c 'fetch-daemon.sh' "$ROOT/tools/cockpit-launch-lib.sh")"
msg='cockpit daemon binary not found; run `canon update` to fetch it'
grep -qF "$msg" "$ROOT/tools/canon-go/internal/board/main.go" || fail "the board must say how to fetch a missing daemon"

# 10. every module in tools/canon-go/go.mod has a section in THIRD-PARTY-NOTICES.md (the notice travels with the binary)
mods=0
while read -r path ver; do
  mods=$((mods + 1)); grep -qF "## $path $ver" "$ROOT/THIRD-PARTY-NOTICES.md" || fail "THIRD-PARTY-NOTICES.md has no section for $path $ver"
done < <(sed 's|// indirect||; s|^require ||' "$ROOT/tools/canon-go/go.mod" | awk 'NF==2 && $1 ~ /^[a-z0-9.-]+\.[a-z]+\// && $2 ~ /^v[0-9]/ {print $1, $2}')
[[ "$mods" -ge 5 ]] || fail "expected the daemon's five modules, saw $mods"
# 10b. every third-party .js/.css file the daemon embeds under web/vendor/ is named, by path, in THIRD-PARTY-NOTICES.md (t-70e4: xterm shipped without a notice)
vend=0
for f in "$ROOT"/tools/canon-go/internal/daemon/web/vendor/*.js "$ROOT"/tools/canon-go/internal/daemon/web/vendor/*.css; do
  [[ -e "$f" ]] || continue
  vend=$((vend + 1)); grep -qF "web/vendor/$(basename "$f")\`" "$ROOT/THIRD-PARTY-NOTICES.md" || fail "THIRD-PARTY-NOTICES.md does not name vendored file web/vendor/$(basename "$f")"
done
[[ "$vend" -ge 3 ]] || fail "expected the three vendored xterm files, saw $vend"

# 11. release-daemon.sh --dry-run: builds four targets, prints the manifest lines, publishes and writes nothing; refuses a dirty daemon dir
RR="$WORK/rel"; RM="$RR/tools/canon-go"; mkdir -p "$RR/scripts" "$RM/cmd/cockpit-daemon" "$RM/cmd/sprint-check" "$RM/internal/daemon" "$RM/internal/board" "$RM/internal/common" "$RM/internal/events"
cp "$R/VERSION" "$RR/"; cp "$ROOT/scripts/release-daemon.sh" "$RR/scripts/"; cp "$ROOT/tools/src-key.sh" "$RR/tools/"; cp "$ROOT/THIRD-PARTY-NOTICES.md" "$RR/"
printf 'module x\n\ngo 1.26.5\n\ntoolchain %s\n' "$(go env GOVERSION)" > "$RM/go.mod"; : > "$RM/go.sum"   # t-7efe: the release script builds with the go.mod toolchain line and refuses without one
for d in "$RM/cmd/cockpit-daemon" "$RM/cmd/sprint-check"; do printf 'package main\n\nvar version, commit string\n\nfunc main() {}\n' > "$d/main.go"; done
for d in internal/daemon internal/board internal/common internal/events; do printf 'package x\n' > "$RM/$d/x.go"; done
printf '# header\n' > "$RR/tools/cockpit-daemon.sha256"
git -C "$RR" init -q -b main; git -C "$RR" "${ident[@]}" add -A; git -C "$RR" "${ident[@]}" commit -qm seed
rkey="$(srckey "$RR" cockpit-daemon | cut -c1-12)"
cat > "$WORK/gostub/gh" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
EOF
chmod +x "$WORK/gostub/gh"; : > "$STUB_LOG"
out="$(PATH="$WORK/gostub:$STUBS:$BASEPATH" bash "$RR/scripts/release-daemon.sh" --dry-run 2>&1)" || fail "release dry run failed: $out"
for t in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64; do assert_contains "$out" "$rkey $t "; done
for t in windows-amd64 sprint-check-windows-amd64; do assert_contains "$out" " $t "; done   # t-9383
[[ "$out" != *sprint-headless-json* ]] || fail "the retired headless helper is still released: $out"   # t-b62a
for t in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64; do assert_contains "$out" " sprint-check-$t "; done   # t-15d8
assert_contains "$out" "dry run"; [[ ! -s "$STUB_LOG" ]] || fail "dry run called gh"; assert_eq "# header" "$(cat "$RR/tools/cockpit-daemon.sha256")"
echo dirty >> "$RM/internal/daemon/x.go"
set +e; out="$(PATH="$WORK/gostub:$STUBS:$BASEPATH" bash "$RR/scripts/release-daemon.sh" --dry-run 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a dirty source must stop the release dry run ($rc): $out"; assert_contains "$out" "uncommitted changes"

echo "fetch-daemon: ok (verify before run, no leftovers, existing daemon kept, fallback build, platform map, callers, notices, release dry run)"
