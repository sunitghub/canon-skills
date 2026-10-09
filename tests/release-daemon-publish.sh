#!/usr/bin/env bash
# release-daemon-publish (t-9383): scripts/release-daemon.sh publishes the unix daemon, the Windows daemon, the board and the
# headless helper against a fake `gh` that models GitHub releases in a directory. It must create what is missing, add only the
# assets a release lacks, never overwrite one, verify every asset by downloading it back, and write the manifest last, newest
# line last. Real Go cross-builds of tiny stub packages, so the build flags and paths are exercised for real.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches the tools/sprint-check-go source path
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
command -v go >/dev/null 2>&1 || { echo "release-daemon-publish: go absent: skipped"; exit 0; }
WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)

R="$WORK/repo"; mkdir -p "$R/scripts" "$R/tools/cockpit-daemon" "$R/tools/sprint-check-go" "$R/tools/sprint-headless-json-go"
cp "$ROOT/scripts/release-daemon.sh" "$R/scripts/"; cp "$ROOT/THIRD-PARTY-NOTICES.md" "$R/"; echo 0.3.0 > "$R/VERSION"
LV="$(go env GOVERSION)"   # the local Go: pins equal to it need no download in a hermetic test
printf 'module x/d\n\ngo 1.21\n\ntoolchain %s\n' "$LV" > "$R/tools/cockpit-daemon/go.mod"
for d in cockpit-daemon sprint-check-go sprint-headless-json-go; do printf 'package main\n\nvar version, commit string\n\nfunc main() { println(version, commit) }\n' > "$R/tools/$d/main.go"; done
for d in sprint-check-go sprint-headless-json-go; do echo "$LV" > "$R/tools/$d/GO_TOOLCHAIN"; done
printf '# header\n' > "$R/tools/cockpit-daemon.sha256"
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
kd="$(git -C "$R" rev-parse HEAD:tools/cockpit-daemon | cut -c1-12)"; kb="$(git -C "$R" rev-parse HEAD:tools/sprint-check-go | cut -c1-12)"; kh="$(git -C "$R" rev-parse HEAD:tools/sprint-headless-json-go | cut -c1-12)"

# The fake gh: releases are directories under $FAKE_GH.
STUBS="$WORK/stubs"; mkdir -p "$STUBS" "$WORK/gh"; export FAKE_GH="$WORK/gh" STUB_LOG="$WORK/gh.log"
cat > "$STUBS/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
[ "$1" = release ] || exit 2; sub="$2"; shift 2
case "$sub" in
  view) tag="$1"; [ -d "$FAKE_GH/$tag" ] || exit 1
        if printf '%s ' "$@" | grep -q -- '--json'; then ls "$FAKE_GH/$tag"; fi ;;
  create) tag="$1"; shift; mkdir -p "$FAKE_GH/$tag"
          while [ $# -gt 0 ]; do case "$1" in --repo|--target|--title|--notes) shift 2 ;; *) cp "$1" "$FAKE_GH/$tag/"; shift ;; esac; done ;;
  upload) tag="$1"; f="$2"; [ ! -e "$FAKE_GH/$tag/$(basename "$f")" ] || { echo "asset exists" >&2; exit 1; }; cp "$f" "$FAKE_GH/$tag/" ;;
  download) tag="$1"; shift; dir=""; pat=""; while [ $# -gt 0 ]; do case "$1" in --dir) dir="$2"; shift 2 ;; --pattern) pat="$2"; shift 2 ;; *) shift ;; esac; done
            [ -z "${FAKE_GH_SERVE_BAD:-}" ] || { printf 'tampered' > "$dir/$pat"; exit 0; }
            [ -f "$FAKE_GH/$tag/$pat" ] && cp "$FAKE_GH/$tag/$pat" "$dir/" ;;
esac
GH
chmod +x "$STUBS/gh"
# A go shim: records the toolchain and go.mod of each build the script makes. It passes GOTOOLCHAIN through, except with SHIM_FORCE_LOCAL=1, where it
# builds with the local Go whatever was asked (a script that ignored its pin, or an exported GOTOOLCHAIN=local).
export REAL_GO="$(command -v go)" GO_LOG="$WORK/go.log"
cat > "$STUBS/go" <<'GO'
#!/usr/bin/env bash
if [ "${1:-}" = build ] && [ -f go.mod ] && grep -qE '^module (canon/sprint|x/d)' go.mod; then echo "GOTOOLCHAIN=${GOTOOLCHAIN:-} $(tr '\n' ' ' < go.mod)" >> "$GO_LOG"; fi
[ -z "${SHIM_FORCE_LOCAL:-}" ] || export GOTOOLCHAIN=local
exec "$REAL_GO" "$@"
GO
chmod +x "$STUBS/go"
run() { : > "$STUB_LOG"; : > "$GO_LOG"; set +e; out="$(cd "$R" && PATH="$STUBS:$PATH" bash scripts/release-daemon.sh 2>&1)"; rc=$?; set -e; }
assets() { ls "$FAKE_GH/$1" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }

# 1. a first release creates three releases with the right assets, verifies them, and writes the manifest
run; [[ "$rc" == 0 ]] || fail "first publish failed ($rc): $out"
assert_eq "THIRD-PARTY-NOTICES.md cockpit-daemon-darwin-amd64 cockpit-daemon-darwin-arm64 cockpit-daemon-linux-amd64 cockpit-daemon-linux-arm64 cockpit-daemon-windows-amd64.exe " "$(assets "cockpit-daemon-$kd")"
assert_eq "THIRD-PARTY-NOTICES.md sprint-check-windows-amd64.exe " "$(assets "sprint-check-$kb")"
assert_eq "THIRD-PARTY-NOTICES.md sprint-headless-json-windows-amd64.exe " "$(assets "sprint-headless-json-$kh")"
m="$R/tools/cockpit-daemon.sha256"
assert_eq 7 "$(grep -vc '^#' "$m")"
for want in "$kd windows-amd64 " "$kb sprint-check-windows-amd64 " "$kh sprint-headless-json-windows-amd64 " "$kd darwin-arm64 "; do grep -q "^$want" "$m" || fail "manifest lacks a line for $want"; done
want="$(shasum -a 256 "$FAKE_GH/sprint-check-$kb/sprint-check-windows-amd64.exe" | awk '{print $1}')"; grep -q "^$kb sprint-check-windows-amd64 $want\$" "$m" || fail "the manifest hash is not the published asset's hash"
# the legacy builds ask for the pinned toolchain and write the pin into the staged go.mod (not the installed Go: t-7efe)
for mod in sprint-check sprint-headless-json; do grep -q "^GOTOOLCHAIN=$LV module canon/$mod  go ${LV#go} \$" "$GO_LOG" || fail "the $mod build did not use the pinned toolchain: $(cat "$GO_LOG")"; done
[[ "$(grep -c "^GOTOOLCHAIN=$LV module x/d " "$GO_LOG")" == 5 ]] || fail "the five daemon builds must each set GOTOOLCHAIN to go.mod's toolchain line: $(cat "$GO_LOG")"
# 2. the same source again: nothing is uploaded or created, the manifest is the same set of lines
before="$(sort "$m")"; run; [[ "$rc" == 0 ]] || fail "second publish failed: $out"
! grep -qE ' (create|upload) ' "$STUB_LOG" || fail "a second run created or uploaded something: $(cat "$STUB_LOG")"
assert_eq "$before" "$(sort "$m")"
# 3. an older release that lacks the Windows daemon asset (the real case: 0e2fd866 shipped without it) gets only that asset
rm "$FAKE_GH/cockpit-daemon-$kd/cockpit-daemon-windows-amd64.exe"; : > "$m"; printf '# header\n' > "$m"
run; [[ "$rc" == 0 ]] || fail "adding a missing asset failed: $out"
assert_eq 1 "$(grep -c 'release upload' "$STUB_LOG")"; grep -q "release upload cockpit-daemon-$kd .*cockpit-daemon-windows-amd64.exe" "$STUB_LOG" || fail "the wrong asset was uploaded: $(cat "$STUB_LOG")"
# 4. a published asset is never overwritten: the build must equal it (a different Go version would not), or the run stops and writes nothing
printf 'someone else built this' > "$FAKE_GH/sprint-check-$kb/sprint-check-windows-amd64.exe"; printf '# header\n' > "$m"
run; [[ "$rc" == 1 ]] || fail "a differing published asset must stop the run (rc=$rc): $out"
assert_contains "$out" "differs from this build"; assert_eq "# header" "$(cat "$m")"
! grep -q 'release upload .*sprint-check-windows-amd64.exe' "$STUB_LOG" || fail "an existing asset was overwritten"
# 5. a download that does not match what was built stops the run before the manifest is touched
rm -rf "$FAKE_GH"/*; export FAKE_GH_SERVE_BAD=1; run; unset FAKE_GH_SERVE_BAD
[[ "$rc" == 1 ]] || fail "a tampered download must stop the run: $out"; assert_eq "# header" "$(cat "$m")"
# 6. the newest line is last: a re-release with new source replaces the old line for that target and appends the new one at the end
rm -rf "$FAKE_GH"/*; run; [[ "$rc" == 0 ]]
echo "// v2" >> "$R/tools/sprint-check-go/main.go"; git -C "$R" "${ident[@]}" commit -qam "board v2"
kb2="$(git -C "$R" rev-parse HEAD:tools/sprint-check-go | cut -c1-12)"; run; [[ "$rc" == 0 ]] || fail "re-release failed: $out"
assert_eq "$kb2 sprint-check-windows-amd64" "$(grep ' sprint-check-windows-amd64 ' "$m" | tail -1 | awk '{print $1" "$2}')"
assert_eq 2 "$(grep -c ' sprint-check-windows-amd64 ' "$m")"   # the old key's line stays (older installs still resolve it), the new one is last
# 7. dirty source is refused, as before
echo "// dirty" >> "$R/tools/sprint-headless-json-go/main.go"; run; [[ "$rc" == 1 ]]; assert_contains "$out" "uncommitted changes"
# 8. every go build in the release script carries -trimpath (without it the bytes depend on the checkout path; tests/build-zip-go-package.sh guards the stamping, this guards the flag)
builds="$(grep -c 'go build' "$ROOT/scripts/release-daemon.sh")"; trim="$(grep 'go build' "$ROOT/scripts/release-daemon.sh" | grep -c -- '-trimpath')"
[[ "$builds" -ge 3 && "$builds" == "$trim" ]] || fail "release-daemon.sh: $builds go build lines, $trim with -trimpath"
# 9. a missing, malformed or unbuildable GO_TOOLCHAIN stops the run before anything is published or written
git -C "$R" "${ident[@]}" checkout -q -- tools/sprint-headless-json-go; rm -rf "$FAKE_GH"/*; printf '# header\n' > "$m"
for bad in "" "1.27.2" "go1.27"; do
  printf '%s\n' "$bad" > "$R/tools/sprint-check-go/GO_TOOLCHAIN"; git -C "$R" "${ident[@]}" commit -qam "pin: '$bad'"
  run; [[ "$rc" == 1 ]] || fail "GO_TOOLCHAIN '$bad' must stop the run (rc=$rc): $out"
  assert_eq "# header" "$(cat "$m")"; ! grep -qE ' (create|upload) ' "$STUB_LOG" || fail "GO_TOOLCHAIN '$bad': something was published"
  assert_contains "$out" "must name the Go toolchain"
done
# 9b. every built binary is checked against its pin: a script that ignored the pin, or an exported GOTOOLCHAIN=local, publishes nothing
echo go1.21.5 > "$R/tools/sprint-check-go/GO_TOOLCHAIN"; git -C "$R" "${ident[@]}" commit -qam "board pin 1.21.5"
rm -rf "$FAKE_GH"/*; printf '# header\n' > "$m"
k1="$(git -C "$R" rev-parse HEAD:tools/sprint-check-go)"; echo go1.21.6 > "$R/tools/sprint-check-go/GO_TOOLCHAIN"; git -C "$R" "${ident[@]}" commit -qam "board pin 1.21.6"
[[ "$k1" != "$(git -C "$R" rev-parse HEAD:tools/sprint-check-go)" ]] || fail "raising a pin must change the source folder's tree hash (a new release key)"
SHIM_FORCE_LOCAL=1 run; [[ "$rc" == 1 ]] || fail "a binary not built with its pin must stop the run (rc=$rc): $out"
assert_contains "$out" "was built with '$LV', not the pinned go1.21.6"; assert_eq "# header" "$(cat "$m")"; ! grep -qE ' (create|upload) ' "$STUB_LOG" || fail "something was published"
grep -q "^GOTOOLCHAIN=go1.21.6 module canon/sprint-check  go 1.21.6 \$" "$GO_LOG" || fail "the board build must be asked for its pin, with a go.mod of that version: $(cat "$GO_LOG")"
echo "$LV" > "$R/tools/sprint-check-go/GO_TOOLCHAIN"; git -C "$R" "${ident[@]}" commit -qam "board pin back"
# 9c. the daemon: a go.mod without a toolchain line is refused, and so is a daemon built with other than that toolchain
cp "$R/tools/cockpit-daemon/go.mod" "$WORK/d.go.mod"; printf 'module x/d\n\ngo 1.21\n' > "$R/tools/cockpit-daemon/go.mod"; git -C "$R" "${ident[@]}" commit -qam "daemon without toolchain"
run; [[ "$rc" == 1 ]] || fail "a daemon go.mod with no toolchain line must stop the run (rc=$rc): $out"; assert_contains "$out" "toolchain goX.Y.Z"
printf 'module x/d\n\ngo 1.21\n\ntoolchain go1.21.5\n' > "$R/tools/cockpit-daemon/go.mod"; git -C "$R" "${ident[@]}" commit -qam "daemon toolchain 1.21.5"
SHIM_FORCE_LOCAL=1 run; [[ "$rc" == 1 ]] || fail "a daemon not built with its toolchain must stop the run (rc=$rc): $out"; assert_contains "$out" "not the pinned go1.21.5"; assert_eq "# header" "$(cat "$m")"
cp "$WORK/d.go.mod" "$R/tools/cockpit-daemon/go.mod"; git -C "$R" "${ident[@]}" commit -qam "daemon toolchain back"
# 10. the pins agree: the daemon's go.mod toolchain line and both GO_TOOLCHAIN files in the real tree name one version (one owner would be better, but go.mod cannot read a file)
dv="$(awk '/^toolchain /{print $2}' "$ROOT/tools/cockpit-daemon/go.mod")"; [[ "$dv" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "tools/cockpit-daemon/go.mod has no toolchain line ('$dv')"
for d in sprint-check-go sprint-headless-json-go; do assert_eq "$dv" "$(tr -d ' \t\n\r' < "$ROOT/tools/$d/GO_TOOLCHAIN")"; done
echo "release-daemon-publish: ok (creates, adds only missing assets, never overwrites, verifies by download, manifest last and newest-last)"
