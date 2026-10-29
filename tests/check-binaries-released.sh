#!/usr/bin/env bash
# check-binaries-released (t-9383): scripts/check-binaries-released.sh is the push guard — red whenever a binary's source changed
# without its release, green when every component's newest manifest line names the current source tree.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches a board binary spelling
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)
# t-bdb0: one program, cmd/canon-go, built from the board and the daemon parts (tools/src-key.sh names what each covers); the release key
# is `canon-go`, the hash of both. Protects the push guard (tkt push-main, the pre-push hook) for the five canon-go-<target> assets.
R="$WORK/repo"; M="$R/tools/canon-go"; mkdir -p "$R/scripts" "$M/cmd/canon-go" "$M/internal/board" "$M/internal/daemon" "$M/internal/common" "$M/internal/events" "$M/internal/term" "$M/internal/settings"
cp "$ROOT/scripts/check-binaries-released.sh" "$R/scripts/"; cp "$ROOT/tools/src-key.sh" "$R/tools/"
printf 'module canon\n' > "$M/go.mod"; : > "$M/go.sum"
for d in cmd/canon-go internal/board internal/daemon internal/common internal/events internal/term internal/settings; do echo "package x // $d" > "$M/$d/x.go"; done
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
key() { bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" "$2"' _ "$R" "$1" | cut -c1-12; }
sha() { printf 'a%.0s' {1..64}; }
TARGETS="darwin-arm64 darwin-amd64 linux-amd64 linux-arm64 windows-amd64"
# Older trees' lines (the two programs before t-bdb0) stay in the manifest; they must neither satisfy nor break the check.
OLD="$(for t in $TARGETS; do echo "0123456789ab $t $(sha)"; echo "0123456789ab sprint-check-$t $(sha)"; done)"
write_manifest() { # <canon-go key>
  { echo "$OLD"; for t in $TARGETS; do echo "$1 canon-go-$t $(sha)"; done; } > "$R/tools/cockpit-daemon.sha256"
}
run() { set +e; out="$(bash "$R/scripts/check-binaries-released.sh" "$@" 2>&1)"; rc=$?; set -e; }

write_manifest "$(key canon-go)"
run; [[ "$rc" == 0 ]] || fail "a fully released tree must pass: $out"; assert_contains "$out" "ok            canon-go-windows-amd64"
# every target is checked: with only the old programs' lines, each of the five is named (a dropped row would go unchecked)
cp "$R/tools/cockpit-daemon.sha256" "$WORK/full.sha256"; printf '# header\n%s\n' "$OLD" > "$R/tools/cockpit-daemon.sha256"; run
[[ "$rc" == 1 ]] || fail "old programs' lines must not count as a canon-go release: $out"
for t in $TARGETS; do assert_contains "$out" "NOT RELEASED  canon-go-$t"; done
assert_eq 5 "$(grep -c 'NOT RELEASED' <<<"$out")"
cp "$WORK/full.sha256" "$R/tools/cockpit-daemon.sha256"

# a change to either part without its release: red for every target (the release key covers both)
for part in board daemon; do
  write_manifest "$(key canon-go)"
  echo "// change" >> "$M/internal/$part/x.go"; git -C "$R" "${ident[@]}" commit -qam "$part changed"
  run; [[ "$rc" == 1 ]] || fail "an unreleased $part change must fail: $out"
  for t in $TARGETS; do assert_contains "$out" "NOT RELEASED  canon-go-$t"; done
done
# a newer line is the one that counts: add the new key last
for t in $TARGETS; do echo "$(key canon-go) canon-go-$t $(sha)"; done >> "$R/tools/cockpit-daemon.sha256"; run; [[ "$rc" == 0 ]] || fail "the newest line for the target must be used: $out"
# the OLD key appended after the new one makes the newest line stale again
echo "111111111111 canon-go-windows-amd64 $(sha)" >> "$R/tools/cockpit-daemon.sha256"; run; [[ "$rc" == 1 ]] || fail "a stale newest line must fail: $out"
# a CRLF manifest (still fine), an empty manifest
write_manifest "$(key canon-go)"
sed -i.bak 's/$/\r/' "$R/tools/cockpit-daemon.sha256"; rm "$R/tools/cockpit-daemon.sha256.bak"; run; [[ "$rc" == 0 ]] || fail "CRLF manifest must pass: $out"
: > "$R/tools/cockpit-daemon.sha256"; run; [[ "$rc" == 1 ]] || fail "an empty manifest must fail: $out"; assert_contains "$out" "missing"

# --download: the asset must exist at canon-go-<key>/canon-go-<target> and hash to the manifest line
STUBS="$WORK/stubs"; mkdir -p "$STUBS"; export STUB_DIR="$WORK/assets"; mkdir -p "$STUB_DIR"
cat > "$STUBS/curl" <<'EOF2'
#!/bin/sh
url=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; url="$1"; shift; done
echo "$url" >> "$STUB_DIR/urls"
f="$STUB_DIR/$(basename "$url")"; [ -f "$f" ] || exit 22; cp "$f" "$out"
EOF2
chmod +x "$STUBS/curl"
printf 'binary' > "$WORK/b"; goodsha="$(shasum -a 256 "$WORK/b" | awk '{print $1}')"
{ for t in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64; do echo "$(key canon-go) canon-go-$t $goodsha"; cp "$WORK/b" "$STUB_DIR/canon-go-$t"; done
  echo "$(key canon-go) canon-go-windows-amd64 $goodsha"; cp "$WORK/b" "$STUB_DIR/canon-go-windows-amd64.exe"; } > "$R/tools/cockpit-daemon.sha256"
set +e; out="$(PATH="$STUBS:$PATH" bash "$R/scripts/check-binaries-released.sh" --download 2>&1)"; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "good assets must pass --download: $out"; assert_contains "$out" "asset downloaded, sha256 matches"
assert_contains "$(cat "$STUB_DIR/urls")" "/canon-go-$(key canon-go)/canon-go-windows-amd64.exe"
printf 'tampered' > "$STUB_DIR/canon-go-windows-amd64.exe"
set +e; out="$(PATH="$STUBS:$PATH" bash "$R/scripts/check-binaries-released.sh" --download 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a tampered asset must fail --download: $out"; assert_contains "$out" "BAD ASSET     canon-go-windows-amd64"
rm -f "$STUB_DIR/canon-go-linux-arm64"
set +e; out="$(PATH="$STUBS:$PATH" bash "$R/scripts/check-binaries-released.sh" --download 2>&1)"; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "a missing asset must fail --download: $out"; assert_contains "$out" "BAD ASSET     canon-go-linux-arm64"
# t-b6b6: --rev judges a commit by ITS keys and ITS manifest (tkt push-main passes origin's commit), not the checkout.
write_manifest "$(key canon-go)"
git -C "$R" "${ident[@]}" add tools/cockpit-daemon.sha256; git -C "$R" "${ident[@]}" commit -qm released; REL="$(git -C "$R" rev-parse HEAD)"
echo "package x // changed" > "$M/internal/daemon/x.go"; git -C "$R" "${ident[@]}" commit -qam "daemon change, not released"; LAG="$(git -C "$R" rev-parse HEAD)"
run --rev "$REL"; [[ "$rc" == 0 ]] || fail "--rev at the released commit must pass: $out"
run --rev "$LAG"; [[ "$rc" == 1 ]] || fail "--rev at an unreleased commit must fail: $out"; assert_contains "$out" "NOT RELEASED  canon-go-linux-amd64: canon-go"
write_manifest "$(key canon-go)"   # the checkout's manifest is current now, uncommitted
run; [[ "$rc" == 0 ]] || fail "the checkout with a current (uncommitted) manifest passes: $out"
run --rev "$LAG"; [[ "$rc" == 1 ]] || fail "--rev must read the manifest at the commit, not the checkout's: $out"
run --rev; [[ "$rc" == 2 ]] || fail "--rev with no commit is a usage error: $out"
run --rev nosuchcommit; [[ "$rc" == 2 ]] || fail "an unknown commit is an error: $out"; assert_contains "$out" "no such commit"
run --bogus; [[ "$rc" == 2 ]] || fail "an unknown option is a usage error: $out"
echo "check-binaries-released: ok (green when released, red for a change to either part, old programs' lines ignored, newest line wins, CRLF ok, --download catches a missing or tampered asset, --rev judges a commit's own keys and manifest)"
