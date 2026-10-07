#!/usr/bin/env bash
# check-binaries-released (t-9383): scripts/check-binaries-released.sh is the push guard — red whenever a binary's source changed
# without its release, green when every component's newest manifest line names the current source tree.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches the tools/sprint-check-go source path
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
R="$WORK/repo"; mkdir -p "$R/scripts" "$R/tools/cockpit-daemon" "$R/tools/sprint-check-go" "$R/tools/sprint-headless-json-go"
cp "$ROOT/scripts/check-binaries-released.sh" "$R/scripts/"
for d in cockpit-daemon sprint-check-go sprint-headless-json-go; do echo "package main // $d" > "$R/tools/$d/main.go"; done
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
key() { git -C "$R" rev-parse "HEAD:$1" | cut -c1-12; }
sha() { printf 'a%.0s' {1..64}; }
write_manifest() { # <daemon key> <board key> <headless key>
  { for t in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64 windows-amd64; do echo "$1 $t $(sha)"; done
    echo "$2 sprint-check-windows-amd64 $(sha)"; echo "$3 sprint-headless-json-windows-amd64 $(sha)"; } > "$R/tools/cockpit-daemon.sha256"
}
run() { set +e; out="$(bash "$R/scripts/check-binaries-released.sh" "$@" 2>&1)"; rc=$?; set -e; }

write_manifest "$(key tools/cockpit-daemon)" "$(key tools/sprint-check-go)" "$(key tools/sprint-headless-json-go)"
run; [[ "$rc" == 0 ]] || fail "a fully released tree must pass: $out"; assert_contains "$out" "ok            windows-amd64"

# a source change without its release: red, and it names the component
echo "// change" >> "$R/tools/sprint-check-go/main.go"; git -C "$R" "${ident[@]}" commit -qam "board changed"
run; [[ "$rc" == 1 ]] || fail "an unreleased board change must fail: $out"
assert_contains "$out" "NOT RELEASED  sprint-check-windows-amd64"; [[ "$out" != *"NOT RELEASED  windows-amd64"* ]] || fail "the daemon was named though it did not change: $out"
# a newer line is the one that counts: add the board's new key last
echo "$(key tools/sprint-check-go) sprint-check-windows-amd64 $(sha)" >> "$R/tools/cockpit-daemon.sha256"; run; [[ "$rc" == 0 ]] || fail "the newest line for the target must be used: $out"
# the OLD key appended after the new one makes the newest line stale again
echo "111111111111 sprint-check-windows-amd64 $(sha)" >> "$R/tools/cockpit-daemon.sha256"; run; [[ "$rc" == 1 ]] || fail "a stale newest line must fail: $out"
# a missing line, a CRLF manifest (still fine), an empty manifest
write_manifest "$(key tools/cockpit-daemon)" "$(key tools/sprint-check-go)" "$(key tools/sprint-headless-json-go)"
sed -i.bak 's/$/\r/' "$R/tools/cockpit-daemon.sha256"; rm "$R/tools/cockpit-daemon.sha256.bak"; run; [[ "$rc" == 0 ]] || fail "CRLF manifest must pass: $out"
: > "$R/tools/cockpit-daemon.sha256"; run; [[ "$rc" == 1 ]] || fail "an empty manifest must fail: $out"; assert_contains "$out" "missing"

# --download: the asset must exist and hash to the manifest line
STUBS="$WORK/stubs"; mkdir -p "$STUBS"; export STUB_DIR="$WORK/assets"; mkdir -p "$STUB_DIR"
cat > "$STUBS/curl" <<'EOF2'
#!/bin/sh
url=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; url="$1"; shift; done
f="$STUB_DIR/$(basename "$url")"; [ -f "$f" ] || exit 22; cp "$f" "$out"
EOF2
chmod +x "$STUBS/curl"
printf 'binary' > "$WORK/b"; goodsha="$(shasum -a 256 "$WORK/b" | awk '{print $1}')"
{ for t in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64; do echo "$(key tools/cockpit-daemon) $t $goodsha"; cp "$WORK/b" "$STUB_DIR/cockpit-daemon-$t"; done
  echo "$(key tools/cockpit-daemon) windows-amd64 $goodsha"; cp "$WORK/b" "$STUB_DIR/cockpit-daemon-windows-amd64.exe"
  echo "$(key tools/sprint-check-go) sprint-check-windows-amd64 $goodsha"; cp "$WORK/b" "$STUB_DIR/sprint-check-windows-amd64.exe"
  echo "$(key tools/sprint-headless-json-go) sprint-headless-json-windows-amd64 $goodsha"; cp "$WORK/b" "$STUB_DIR/sprint-headless-json-windows-amd64.exe"; } > "$R/tools/cockpit-daemon.sha256"
set +e; out="$(PATH="$STUBS:$PATH" bash "$R/scripts/check-binaries-released.sh" --download 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "good assets must pass --download: $out"; assert_contains "$out" "asset downloaded, sha256 matches"
printf 'tampered' > "$STUB_DIR/sprint-check-windows-amd64.exe"
set +e; out="$(PATH="$STUBS:$PATH" bash "$R/scripts/check-binaries-released.sh" --download 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a tampered asset must fail --download: $out"; assert_contains "$out" "BAD ASSET     sprint-check-windows-amd64"
rm -f "$STUB_DIR/cockpit-daemon-linux-arm64"
set +e; out="$(PATH="$STUBS:$PATH" bash "$R/scripts/check-binaries-released.sh" --download 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]]; assert_contains "$out" "BAD ASSET     linux-arm64"
echo "check-binaries-released: ok (green when released, red naming the component, newest line wins, CRLF ok, --download catches a missing or tampered asset)"
