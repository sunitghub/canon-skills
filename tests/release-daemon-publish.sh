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
printf 'module x/d\n\ngo 1.21\n' > "$R/tools/cockpit-daemon/go.mod"
for d in cockpit-daemon sprint-check-go sprint-headless-json-go; do printf 'package main\n\nvar version, commit string\n\nfunc main() { println(version, commit) }\n' > "$R/tools/$d/main.go"; done
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
run() { : > "$STUB_LOG"; set +e; out="$(cd "$R" && PATH="$STUBS:$PATH" bash scripts/release-daemon.sh 2>&1)"; rc=$?; set -e; }
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
echo "release-daemon-publish: ok (creates, adds only missing assets, never overwrites, verifies by download, manifest last and newest-last)"
