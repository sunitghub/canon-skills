#!/usr/bin/env bash
# build-zip-go-package (t-b9a7, t-9383, t-8020, t-bdb0) — the released program must be built from its whole package: building main.go alone
# once silently left skilleval.go (Skill Eval) out of the Windows board. Since t-bdb0 the board and the daemon are one program,
# cmd/canon-go in the tools/canon-go module, which imports all of internal/board and internal/daemon; scripts/release-daemon.sh builds
# it with build_module. The release build must keep its stamps (t-5c20 commit, t-bdb0 daemon key, both from tools/src-key.sh
# canon_ldflags) and the reproducibility flags, and must not stamp VERSION (t-0859: a release's bytes may not depend on it).
# Prod paths: the release build, `canon-go --version` (fetch-daemon's up-to-date check), the board starting `canon-go daemon`, and the
# daemon's /version daemon_key the board reads for its stale check.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches a board binary spelling
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
f="$ROOT/scripts/release-daemon.sh"
fn="$(sed -n '/^build_module()/,/^}/p' "$f" | grep -v '^[[:space:]]*#')"
[[ -n "$fn" ]] || fail "build-zip-go-package: no build_module in $f"
grep -q -- '-trimpath' <<<"$fn" && grep -q -- '-buildvcs=false' <<<"$fn" || fail "build-zip-go-package: build_module dropped -trimpath/-buildvcs=false (the bytes would depend on the checkout path)"
grep -q -- '\$stamps' <<<"$fn" || fail "build-zip-go-package: build_module dropped the canon_ldflags stamps (commit, t-5c20; daemon key, t-bdb0)"
grep -q 'stamps="$(canon_ldflags "$REPO_ROOT")"' "$f" || fail "build-zip-go-package: release-daemon.sh does not take its stamps from tools/src-key.sh canon_ldflags"
grep -q -- './cmd/canon-go' <<<"$fn" || fail "build-zip-go-package: build_module does not build ./cmd/canon-go"
[ "$(grep -c -- 'main.version' "$f")" -eq 0 ] || fail "build-zip-go-package: release-daemon.sh stamps main.version again (t-0859: VERSION must stay out of the release bytes)"
# the program compiles the whole board and daemon packages, Skill Eval included
grep -q '"canon/internal/board"' "$ROOT/tools/canon-go/cmd/canon-go/main.go" && grep -q '"canon/internal/daemon"' "$ROOT/tools/canon-go/cmd/canon-go/main.go" \
  || fail "build-zip-go-package: cmd/canon-go does not import internal/board and internal/daemon"
[[ -f "$ROOT/tools/canon-go/internal/board/skilleval.go" ]] || fail "build-zip-go-package: skilleval.go is not in internal/board"
[[ ! -e "$ROOT/tools/canon-go/cmd/sprint-check" && ! -e "$ROOT/tools/canon-go/cmd/cockpit-daemon" ]] || fail "build-zip-go-package: the two retired commands are back"
# The -X stamps land in package main, so it must hand them to each mode's Run, or every release reads "dev" (fetch-daemon's version check
# then re-downloads at every start) and no board can tell a stale daemon. Built for real with the stamps release-daemon.sh uses; every
# run under a 20 s limit, since a mode that ignored its arguments would start serving instead (SIGKILL: Go ignores SIGALRM; port 0).
command -v go >/dev/null 2>&1 || fail "build-zip-go-package: go is required (canon-go is built here)"
B="$(mktemp -d)"; DPID=""; trap '[ -z "$DPID" ] || kill "$DPID" 2>/dev/null || true; rm -rf "$B"' EXIT
export HOME="$B/home" CANON_HOME="$B/canon" TMPDIR="$B/tmp" XDG_CONFIG_HOME="$B/xdg" COCKPIT_STATE_DIR="$B/state" CANON_COCKPIT_PORT=1 COCKPIT_ADDR=127.0.0.1:0
mkdir -p "$HOME" "$CANON_HOME" "$TMPDIR" "$XDG_CONFIG_HOME"; mkdir -m 700 "$COCKPIT_STATE_DIR"
within20() { perl -e '$p = fork; exec @ARGV unless $p; $SIG{ALRM} = sub { kill 9, $p; exit 124 }; alarm 20; waitpid $p, 0; exit($? >> 8)' "$@"; }
dkey="0123456789abcdef0123456789abcdef01234567"
for stamp in abcd1234 dev; do
  ld="-X main.version=9.9.9 -X main.commit=$stamp"; [ "$stamp" = dev ] || ld="$ld -X main.daemonKey=$dkey"
  (cd "$ROOT/tools/canon-go" && HOME="$_BUILD_BOARD_HOME" GOTOOLCHAIN=local go build -ldflags "$ld" -o "$B/canon-go-$stamp" ./cmd/canon-go) || fail "build-zip-go-package: cannot build canon-go"
done
for mode in "" board daemon; do
  out="$(within20 "$B/canon-go-abcd1234" $mode --version 2>&1)" || fail "build-zip-go-package: canon-go $mode --version failed: $out"
  [[ "$out" == *"(abcd1234)"* ]] || fail "build-zip-go-package: canon-go $mode --version lost its commit stamp: $out"
  out="$(within20 "$B/canon-go-dev" $mode --version 2>&1)" || fail "build-zip-go-package: canon-go $mode --version failed: $out"
  [[ "$out" != *"("* ]] || fail "build-zip-go-package: an unstamped canon-go $mode must not print a commit: $out"
done
rc=0; within20 "$B/canon-go-dev" daemon -no-such-flag >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "build-zip-go-package: the daemon must exit 2 on a bad flag, got $rc"
# t-bdb0: the file's name never picks the mode. Named like the old daemon, `--help` is still the board's help (the helper words canon's
# shell tools look for), and `daemon --help` is still the daemon's flags.
cp "$B/canon-go-dev" "$B/cockpit-daemon"
out="$(within20 "$B/cockpit-daemon" --help 2>&1)" || fail "build-zip-go-package: a canon-go named cockpit-daemon did not answer --help as the board: $out"
[[ "$out" == *headless-json* && "$out" == *"canon-go daemon"* ]] || fail "build-zip-go-package: --help of a canon-go named cockpit-daemon is not the board's: $out"
rc=0; out="$(within20 "$B/cockpit-daemon" daemon --help 2>&1)" || rc=$?
[[ "$out" == *"-addr"* && "$out" != *headless-json* ]] || fail "build-zip-go-package: daemon --help is not the daemon's flags: $out"
# t-bdb0: the stamped daemon key reaches the running daemon's /version (what the board compares with its own); an unstamped one reports "".
for stamp in abcd1234 dev; do
  rm -f "$COCKPIT_STATE_DIR/daemon.json"
  "$B/canon-go-$stamp" daemon -addr 127.0.0.1:0 >/dev/null 2>&1 & DPID=$!
  addr=""; for _ in $(seq 1 100); do addr="$(sed -n 's/.*"addr": *"\([^"]*\)".*/\1/p' "$COCKPIT_STATE_DIR/daemon.json" 2>/dev/null)" || addr=""; [ -n "$addr" ] && break; sleep 0.1; done
  [[ -n "$addr" ]] || fail "build-zip-go-package: canon-go daemon ($stamp) never wrote its address"
  v="$(curl -s --max-time 5 "http://$addr/version")"
  want="$dkey"; if [ "$stamp" = dev ]; then want=""; fi
  [[ "$v" == *"\"daemon_key\":\"$want\""* ]] || fail "build-zip-go-package: /version of the $stamp daemon does not carry daemon_key '$want': $v"
  kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; DPID=""
done
echo "build-zip-go-package: ok"
