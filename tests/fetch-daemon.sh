#!/usr/bin/env bash
# fetch-daemon (t-60f7, t-bdb0): tools/fetch-daemon.sh puts canon-go in place only after its SHA-256 matches the committed manifest.
# Everything runs in a throwaway repo with stub curl/uname/go; the "binary" is a script that drops a marker file if it is ever
# executed, so "never run an unverified download" is an assertion, not a hope.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

# A throwaway checkout: the script under test (+ tools/src-key.sh, which names the key), a manifest, the Go module's sources, VERSION.
# t-bdb0: one program, canon-go (cmd/canon-go), holds the board and the daemon: one asset, one hash, one destination per platform.
R="$WORK/repo"; M="$R/tools/canon-go"; mkdir -p "$M/cmd/canon-go" "$M/internal/daemon" "$M/internal/board" "$M/internal/common" "$M/internal/events" "$M/internal/term" "$M/internal/settings"
cp "$ROOT/tools/fetch-daemon.sh" "$ROOT/tools/src-key.sh" "$R/tools/"; cp "$ROOT/.gitignore" "$R/"   # canon's ignore rules: the binary and its temp files never show in git status
printf 'module x\n\ngo 1.26.5\n' > "$M/go.mod"; : > "$M/go.sum"; echo 0.3.0 > "$R/VERSION"
for d in cmd/canon-go internal/daemon internal/board internal/common internal/events internal/term internal/settings; do printf 'package x // %s\n' "$d" > "$M/$d/x.go"; done
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
srckey() { bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" "$2"' _ "$1" "$2"; }
full="$(srckey "$R" canon-go)"; key="${full:0:12}"; stamp="${full:0:8}"; dkey="$(srckey "$R" daemon)"
BIN="$R/tools/canon-go-bin/canon-go"; MARK="$WORK/executed"

# The program: prints a version with the commit stamp; leaves a marker when run for anything but --version.
make_asset() { # <path> <stamp>
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "0.3.0 (%s)"; exit 0; }\ntouch "%s"\n' "$2" "$MARK" > "$1"; chmod +x "$1"
}
GOOD="$WORK/good"; make_asset "$GOOD" "$stamp"; GOODSHA="$(shasum -a 256 "$GOOD" | awk '{print $1}')"

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
cp "$STUB_ASSET" "$out"
EOF
mkdir -p "$WORK/gostub"
cat > "$WORK/gostub/go" <<'EOF'
#!/bin/sh
[ "$1" = env ] && { echo go1.99.0; exit 0; }
[ "$1" = version ] && { echo "$3: $(sed -n 's/^# toolchain=//p' "$3")"; exit 0; }   # t-7efe: release-daemon.sh checks each binary with `go version -m`; the stub's binaries record the GOTOOLCHAIN they were built with
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; [ "$1" = -ldflags ] && ld="$2"; pkg="$1"; shift; done
[ "${STUB_GO_FAIL:-0}" = 0 ] || exit 1
# like the real go, build only a package that exists from here (./cmd/canon-go in the module), stamped with its commit and daemon key
[ -d "$pkg" ] && [ -n "$out" ] || { echo "go stub: no package $pkg in $PWD" >&2; exit 1; }
case "$ld" in *"-X main.commit="?*) ;; *) echo "go stub: no commit stamp" >&2; exit 1 ;; esac
[ -z "${STUB_LDLOG:-}" ] || echo "$pkg $ld" >> "$STUB_LDLOG"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "0.3.0 (built)"; exit 0; }\ntouch "%s"\n# toolchain=%s\n' "$STUB_MARK" "${GOTOOLCHAIN:-}" > "$out"
EOF
chmod +x "$STUBS"/* "$WORK/gostub/go"
BASEPATH="/usr/bin:/bin"   # no go on it
export STUB_LOG="$WORK/curl.log" STUB_MARK="$MARK"

manifest() { # <sha> [target]   (writes the manifest the clone carries; the two older programs' lines stay in it, as in canon)
  printf '# header\n%s %s %s\n%s sprint-check-%s %s\n%s canon-go-%s %s\n' "$key" "${2:-darwin-arm64}" "$GOODSHA" "$key" "${2:-darwin-arm64}" "$GOODSHA" "$key" "${2:-darwin-arm64}" "$1" > "$R/tools/cockpit-daemon.sha256"
}
fetch() { # env vars via caller; sets out, rc
  rm -f "$MARK"; : > "$STUB_LOG"
  set +e; out="$(PATH="${FETCH_PATH:-$STUBS:$BASEPATH}" bash "$R/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
}
reset() { rm -rf "$R/tools/canon-go-bin" "$R/tools/cockpit-daemon" "$R/tools/sprint-check-bin"; unset STUB_ASSET STUB_CURL_RC STUB_GO_FAIL STUB_OS STUB_ARCH FETCH_PATH STUB_LDLOG 2>/dev/null || true; }
no_leftovers() { [[ -z "$(ls -A "$R/tools/canon-go-bin" 2>/dev/null | grep '^\.canon-go\.' || true)" ]] || fail "temp file left behind: $(ls -A "$R/tools/canon-go-bin" 2>/dev/null)"; }

# 1. a download that matches is installed, named by the canon-go key and target, and never executed. Protects install, canon update
#    and canon start on macOS/Linux (t-bdb0: one file, tools/canon-go-bin/canon-go, from release canon-go-<key>).
reset; manifest "$GOODSHA"; export STUB_ASSET="$GOOD"
fetch; [[ "$rc" == 0 ]] || fail "matching download failed ($rc): $out"
assert_contains "$out" "fetched canon-go-darwin-arm64 $key, sha256 verified"
assert_eq "1" "$(grep -c . "$STUB_LOG")"   # one program, one download
assert_contains "$(cat "$STUB_LOG")" "releases/download/canon-go-$key/canon-go-darwin-arm64"
cmp -s "$BIN" "$GOOD" || fail "installed file differs from the download"; [[ -x "$BIN" ]] || fail "installed file is not executable"
[[ ! -e "$R/tools/cockpit-daemon" && ! -e "$R/tools/sprint-check-bin" ]] || fail "the retired programs' folders were created"
[[ ! -e "$MARK" ]] || fail "the fetch executed the binary"; no_leftovers
# 2. second run: already current, no download
fetch; [[ "$rc" == 0 ]]; assert_contains "$out" "up to date"; [[ ! -s "$STUB_LOG" ]] || fail "an up-to-date program was downloaded again"

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
  [[ ! -e "$BIN" ]] || fail "$bad download was installed"; [[ ! -e "$MARK" ]] || fail "$bad download was executed"; no_leftovers
done
# 3b. t-bdb0: the hash is the canon-go-<target> line's, never an older program's line for the same key and platform: with only those
#     lines (whose hash the download matches), nothing is downloaded or installed.
reset; printf '# header\n%s darwin-arm64 %s\n%s sprint-check-darwin-arm64 %s\n' "$key" "$GOODSHA" "$key" "$GOODSHA" > "$R/tools/cockpit-daemon.sha256"
export STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "an older program's manifest line was used for canon-go ($rc): $out"; assert_contains "$out" "no checksum for canon-go-darwin-arm64"

# 4. a bad download never replaces a program that is already there (stale: different stamp)
reset; manifest "$GOODSHA"; mkdir -p "$(dirname "$BIN")"; make_asset "$BIN" "00000000"; before="$(cksum < "$BIN")"; export STUB_ASSET="$WORK/bad"; fetch
[[ "$rc" == 1 ]] || fail "stale program + bad download should exit 1"; assert_eq "$before" "$(cksum < "$BIN")"; no_leftovers
# and a good download does replace the stale one
export STUB_ASSET="$GOOD"; fetch; [[ "$rc" == 0 ]] || fail "replacing a stale program failed ($rc): $out"; cmp -s "$BIN" "$GOOD" || fail "a stale program was not replaced by the verified download"

# 5. download fails: build from source when go exists, with its own message; with no go, say what to do
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH" STUB_LDLOG="$WORK/ld.log"; : > "$STUB_LDLOG"
fetch; [[ "$rc" == 0 ]] || fail "fallback build failed ($rc): $out"; assert_contains "$out" "canon-go: built from source"; [[ -x "$BIN" ]] || fail "fallback build not installed"
# t-bdb0: a source build carries the same stamps as a release (tools/src-key.sh canon_ldflags), so its board can flag a stale daemon
assert_contains "$(cat "$STUB_LDLOG")" "./cmd/canon-go "; assert_contains "$(cat "$STUB_LDLOG")" "-X main.commit=$stamp -X main.daemonKey=$dkey"
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 ]] || fail "no download and no go should exit 1"; assert_contains "$out" "download failed"; assert_contains "$out" "Go is not installed"; assert_contains "$out" "Next:"; [[ ! -e "$BIN" ]]
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_GO_FAIL=1 FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"; fetch
[[ "$rc" == 1 ]] || fail "a failed source build must exit 1 ($rc): $out"; assert_contains "$out" "building from source failed"; assert_contains "$out" "needs Go 1.26.5"; no_leftovers

# 5b. t-3954: an install from the slim zip carries no Go source: a failed download names that and points to the fix, never a bare go error
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"
mv "$R/tools/canon-go/cmd" "$R/tools/canon-go/cmd.away"; fetch; mv "$R/tools/canon-go/cmd.away" "$R/tools/canon-go/cmd"
[[ "$rc" == 1 ]] || fail "no download and no source must exit 1 ($rc): $out"; assert_contains "$out" "does not carry the source"; assert_contains "$out" "canon update"; [[ ! -e "$BIN" ]]
no_leftovers

# 6. no manifest line for this commit (not released): never download, fall through
reset; printf '# header\n' > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 ]]; assert_contains "$out" "not released yet"; [[ ! -s "$STUB_LOG" ]] || fail "downloaded without a checksum to verify against"
reset; printf '%s canon-go-darwin-arm64 notahash\n' "$key" > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "a malformed checksum line must refuse: $out"

reset; printf '%s canon-go-darwin-arm64 %s\n' "ffffffffffff" "$GOODSHA" > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch   # a line for another commit must not be used
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "a checksum for a different commit was used: $out"
reset; printf '%s canon-go-darwin-arm64 %s\n' "$key" "${GOODSHA:0:63}" > "$R/tools/cockpit-daemon.sha256"; export STUB_ASSET="$GOOD"; fetch   # all hex but too short
[[ "$rc" == 1 && ! -s "$STUB_LOG" && ! -e "$BIN" ]] || fail "a short checksum was accepted: $out"

# 7. platform mapping, including every spelling of the CPU, and an unsupported CPU; Windows (Git Bash) is covered by tests/fetch-win-binaries.sh
for spec in "Darwin arm64 darwin-arm64" "Darwin x86_64 darwin-amd64" "Linux aarch64 linux-arm64" "Linux x86_64 linux-amd64" "Linux amd64 linux-amd64"; do
  set -- $spec; reset; manifest "$GOODSHA" "$3"; export STUB_ASSET="$GOOD" STUB_OS="$1" STUB_ARCH="$2"; fetch
  [[ "$rc" == 0 ]] || fail "$spec failed ($rc): $out"; assert_contains "$(cat "$STUB_LOG")" "canon-go-$key/canon-go-$3"
done
reset; export STUB_ARCH=riscv64; fetch; [[ "$rc" == 1 ]] || fail "an unknown CPU must exit 1 ($rc): $out"; assert_contains "$out" "no prebuilt binaries for CPU 'riscv64'"
assert_contains "$out" "go build -o ../canon-go-bin/canon-go ./cmd/canon-go"
reset; export STUB_OS=MINGW64_NT-10.0; fetch; [[ "$rc" == 1 && ! -s "$STUB_LOG" ]] || fail "Windows with no released binaries must fail without downloading (t-9383; the real cases are in tests/fetch-win-binaries.sh): $out"
reset

# 7a. t-bdb0: an update from a tree that had the two older programs: once canon-go is in place they are removed (each and its own
#     folder), and a fetch that fails leaves them alone. Never through a symlink. Protects canon update from v0.29.0 (one program on disk).
reset; manifest "$GOODSHA"; mkdir -p "$R/tools/cockpit-daemon" "$R/tools/sprint-check-bin"
make_asset "$R/tools/cockpit-daemon/cockpit-daemon" old; make_asset "$R/tools/sprint-check-bin/sprint-check" old
export STUB_ASSET="$WORK/bad"; make_asset "$WORK/bad" deadbeef; fetch
[[ "$rc" == 1 && -f "$R/tools/cockpit-daemon/cockpit-daemon" && -f "$R/tools/sprint-check-bin/sprint-check" ]] || fail "a failed fetch removed the older programs: $out"
export STUB_ASSET="$GOOD"; fetch
[[ "$rc" == 0 ]] || fail "the update fetch failed ($rc): $out"
[[ ! -e "$R/tools/cockpit-daemon" && ! -e "$R/tools/sprint-check-bin" ]] || fail "the older programs (or their folders) are still there: $(ls -A "$R/tools/cockpit-daemon" "$R/tools/sprint-check-bin" 2>&1)"
assert_contains "$out" "removed tools/cockpit-daemon/cockpit-daemon (replaced by canon-go)"; assert_contains "$out" "removed tools/sprint-check-bin/sprint-check"
[[ ! -e "$MARK" ]] || fail "removing an older program ran it"
# a folder that holds something else stays (only the program is removed); a symlinked program is not followed
reset; manifest "$GOODSHA"; mkdir -p "$R/tools/cockpit-daemon"; make_asset "$R/tools/cockpit-daemon/cockpit-daemon" old; echo keep > "$R/tools/cockpit-daemon/notes.txt"
echo target > "$WORK/linked-target"; mkdir -p "$R/tools/sprint-check-bin"; ln -s "$WORK/linked-target" "$R/tools/sprint-check-bin/sprint-check"
export STUB_ASSET="$GOOD"; fetch; [[ "$rc" == 0 ]] || fail "fetch failed ($rc): $out"
[[ ! -e "$R/tools/cockpit-daemon/cockpit-daemon" && -f "$R/tools/cockpit-daemon/notes.txt" ]] || fail "the program was kept or the user's file removed"
[[ -L "$R/tools/sprint-check-bin/sprint-check" && "$(cat "$WORK/linked-target")" == target ]] || fail "a symlinked older program was removed or followed"
reset

# 7b. the key is the source trees' hash, so it survives a shallow clone and later unrelated commits (a last-commit key would not)
echo later > "$R/README.md"; git -C "$R" add -A; git -C "$R" "${ident[@]}" commit -qm later
git clone -q --depth 1 "file://$R" "$WORK/shallow"
manifest "$GOODSHA"; cp "$R/tools/cockpit-daemon.sha256" "$WORK/shallow/tools/"
reset; export STUB_ASSET="$GOOD"; rm -f "$MARK"; : > "$STUB_LOG"
set +e; out="$(PATH="$STUBS:$BASEPATH" bash "$WORK/shallow/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "a shallow clone could not find its manifest line ($rc): $out"; assert_contains "$out" "fetched canon-go-darwin-arm64 $key, sha256 verified"
# 7c. timeouts, the no-build switch, a rejected download is said out loud even when the fallback build works, and mv/chmod failures are not reported as success
reset; manifest "$GOODSHA"; export STUB_ASSET="$GOOD"; fetch; assert_contains "$(cat "$STUB_LOG")" "--connect-timeout 10"
reset; manifest "$GOODSHA"; export STUB_CURL_RC=22 STUB_ASSET="$GOOD" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"
set +e; out="$(CANON_FETCH_NO_BUILD=1 PATH="$FETCH_PATH" bash "$R/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 && ! -e "$BIN" ]] || fail "CANON_FETCH_NO_BUILD must not build ($rc): $out"; assert_contains "$out" "not building from source at start"
reset; manifest "$GOODSHA"; make_asset "$WORK/bad" deadbeef; export STUB_ASSET="$WORK/bad" FETCH_PATH="$WORK/gostub:$STUBS:$BASEPATH"; fetch
[[ "$rc" == 0 ]] || fail "fallback build failed: $out"; assert_contains "$out" "does not match its checksum"; assert_contains "$out" "built from source"
reset; manifest "$GOODSHA"; export STUB_ASSET="$GOOD"; mkdir -p "$BIN"; fetch   # the destination is a directory: the verified file cannot be installed
[[ "$rc" == 1 ]] || fail "an install that failed must not exit 0: $out"; refute_contains "$out" "fetched canon-go"; rmdir "$BIN" 2>/dev/null || rm -rf "$BIN"; no_leftovers
# a leftover temp file (a fetch killed mid-way) or the binary itself must not make the clone look dirty: both are ignored, or canon update would refuse
mkdir -p "$R/tools/canon-go-bin"; touch "$R/tools/canon-go-bin/.canon-go.AbC123"; cp "$GOOD" "$BIN"
[[ -z "$(git -C "$R" status --porcelain --ignored=no -- tools)" ]] || fail "the program or a leftover fetch temp file shows in git status: $(git -C "$R" status --porcelain)"
reset

# 8. not a git checkout. t-50f7: a release package (macOS/Linux) takes the NEWEST manifest line for its target, as a Windows zip install does
#    (prod path: pkg_install in tools/pkg-lib.sh, which runs the package's own fetch-daemon.sh); with no line for its target there is no name
#    to guess, and it says so. (Before t-50f7 a non-git copy always refused here: that was the git-only behaviour this replaces.)
cp -R "$R" "$WORK/nogit"; rm -rf "$WORK/nogit/.git" "$WORK/nogit/tools/canon-go-bin"
printf '# header
000000000000 canon-go-darwin-arm64 %s
%s darwin-arm64 %s
%s canon-go-darwin-arm64 %s
%s sprint-check-darwin-arm64 %s
' "$GOODSHA" "$key" "$GOODSHA" "$key" "$GOODSHA" "ffffffffffff" "$GOODSHA" > "$WORK/nogit/tools/cockpit-daemon.sha256"
: > "$STUB_LOG"; set +e; out="$(STUB_ASSET="$GOOD" PATH="$STUBS:$BASEPATH" bash "$WORK/nogit/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "a release package must fetch by its newest manifest line ($rc): $out"
assert_eq "/canon-go-$key/canon-go-darwin-arm64" "$(grep -o '/canon-go-[0-9a-f]*/canon-go-darwin-arm64' "$STUB_LOG")"
assert_eq "$GOODSHA" "$(shasum -a 256 "$WORK/nogit/tools/canon-go-bin/canon-go" | awk '{print $1}')"
rm -rf "$WORK/nogit/tools/canon-go-bin"; printf '# header
%s darwin-arm64 %s
' "$key" "$GOODSHA" > "$WORK/nogit/tools/cockpit-daemon.sha256"
set +e; out="$(PATH="$STUBS:$BASEPATH" bash "$WORK/nogit/tools/fetch-daemon.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a copy with no .git and no canon-go line must exit 1 (an older program's line is no name for it) ($rc): $out"; assert_contains "$out" "is not a git checkout"

# 9. who calls it, and the resolvers say the same thing
# t-50f7: install.sh no longer fetches on its own: a release package arrives with its binaries (pkg_install) and canon update fetches for a clone
assert_eq 0 "$(grep -c 'fetch-daemon.sh' "$ROOT/install.sh")"
assert_eq 3 "$(grep -c 'fetch-daemon.sh' "$ROOT/tools/canon")"   # canon update (a clone; packages/main, t-50f7); canon at start for a missing Windows exe (t-9383)
assert_eq 1 "$(grep -c 'bash "$top/tools/fetch-daemon.sh"' "$ROOT/tools/pkg-lib.sh")"   # t-50f7: a new release package, inside its temp folder
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

# 11. release-daemon.sh --dry-run: builds canon-go for five targets, prints the manifest lines, publishes and writes nothing; refuses a dirty source
RR="$WORK/rel"; RM="$RR/tools/canon-go"; mkdir -p "$RR/scripts" "$RM/cmd/canon-go" "$RM/internal/daemon" "$RM/internal/board" "$RM/internal/common" "$RM/internal/events" "$RM/internal/term" "$RM/internal/settings"
cp "$R/VERSION" "$RR/"; cp "$ROOT/scripts/release-daemon.sh" "$RR/scripts/"; cp "$ROOT/tools/src-key.sh" "$RR/tools/"; cp "$ROOT/THIRD-PARTY-NOTICES.md" "$RR/"
printf 'module x\n\ngo 1.26.5\n\ntoolchain %s\n' "$(go env GOVERSION)" > "$RM/go.mod"; : > "$RM/go.sum"   # t-7efe: the release script builds with the go.mod toolchain line and refuses without one
printf 'package main\n\nvar version, commit, daemonKey string\n\nfunc main() {}\n' > "$RM/cmd/canon-go/main.go"
for d in internal/daemon internal/board internal/common internal/events internal/term internal/settings; do printf 'package x\n' > "$RM/$d/x.go"; done
printf '# header\n' > "$RR/tools/cockpit-daemon.sha256"
git -C "$RR" init -q -b main; git -C "$RR" "${ident[@]}" add -A; git -C "$RR" "${ident[@]}" commit -qm seed
rkey="$(srckey "$RR" canon-go | cut -c1-12)"
cat > "$WORK/gostub/gh" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
EOF
chmod +x "$WORK/gostub/gh"; : > "$STUB_LOG"
out="$(PATH="$WORK/gostub:$STUBS:$BASEPATH" bash "$RR/scripts/release-daemon.sh" --dry-run 2>&1)" || fail "release dry run failed: $out"
for t in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64 windows-amd64; do assert_contains "$out" "$rkey canon-go-$t "; done   # t-bdb0
assert_eq 5 "$(grep -c "^$rkey canon-go-" <<<"$out")"
[[ "$out" != *sprint-headless-json* && "$out" != *" sprint-check-"* && "$out" != *" darwin-arm64 "* ]] || fail "a retired program is still released: $out"   # t-b62a, t-bdb0
assert_contains "$out" "dry run for canon-go-$rkey"; [[ ! -s "$STUB_LOG" ]] || fail "dry run called gh"; assert_eq "# header" "$(cat "$RR/tools/cockpit-daemon.sha256")"
echo dirty >> "$RM/internal/daemon/x.go"
set +e; out="$(PATH="$WORK/gostub:$STUBS:$BASEPATH" bash "$RR/scripts/release-daemon.sh" --dry-run 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a dirty source must stop the release dry run ($rc): $out"; assert_contains "$out" "uncommitted changes"

echo "fetch-daemon: ok (one program, verify before run, older programs removed after, no leftovers, existing daemon kept, fallback build, platform map, callers, notices, release dry run)"
