#!/usr/bin/env bash
# canon-packages (t-50f7): the versioned install layout — <home>/packages/<vX.Y.Z>/, <home>/current, data beside them. Protects install.sh and
# bin/install.js (a fresh install builds the layout), `canon update` (tools/canon update_packages over tools/pkg-lib.sh: download, verify,
# unpack, fetch the binaries, flip, lock, prune, the running-Cockpit refusal, --to main) and tools/fetch-daemon.sh's release-package path.
# Hermetic: HOME, CANON_HOME, TMPDIR, XDG_* and the Cockpit state dir are pinned to a temp folder for every command; the "release" is a stub
# (a file:// manifest, zips built here from a tiny tree with a VERSION and a tools/cockpit-daemon.sha256, file:// binaries). The home has a
# space and non-ASCII letters in its name throughout (criterion 11).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

case "$(uname -s)" in
  Darwin) os=darwin ;; Linux) os=linux ;;
  *) echo "canon-packages: SKIPPED on $(uname -s): the versioned layout is macOS/Linux only (Windows keeps its single-tree install)"; exit 0 ;;
esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/canon-packages.XXXXXX")" && pwd -P)"
PIDS=()
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -rf "$W"; }
trap cleanup EXIT
H="$W/h"; mkdir -p "$H" "$W/tmp" "$W/xdg" "$W/cache" "$W/state" "$W/src" "$W/rel" "$W/bin" "$W/proj"
echo canary > "$H/canary"; echo canary > "$W/tmp/canary"
HOMEDIR="$H/my canon çé"   # CANON_HOME: a space and non-ASCII letters
C="$HOMEDIR/current/tools/canon"
PIN=(HOME="$H" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/xdg" XDG_CACHE_HOME="$W/cache" XDG_DATA_HOME="$W/xdg/data" COCKPIT_STATE_DIR="$W/state"
  CANON_COCKPIT_PORT=1 CANON_MANIFEST_URL="file://$W/releases.txt" CANON_RELEASE_BASE="file://$W/rel" CANON_DAEMON_RELEASE_BASE="file://$W/bin"
  CANON_REPO="file://$W/upstream" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 REFRESH_LOG="$W/refresh.log" SHELL=/bin/bash)
run() { env -u XDG_RUNTIME_DIR -u CANON_REF -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u CANON_FETCH_NO_BUILD "${PIN[@]}" CANON_HOME="$HOMEDIR" "$@"; }

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
tree_hash() {   # every name, every file's bytes and every link's target under a folder
  ( cd "$1" && { find . | LC_ALL=C sort; find . -type f -exec sh -c 'for f; do printf "%s " "$f"; cksum < "$f"; done' _ {} + | LC_ALL=C sort
    find . -type l -exec sh -c 'for l; do printf "%s -> %s\n" "$l" "$(readlink "$l")"; done' _ {} + | LC_ALL=C sort; } | cksum )
}
data_hash() { local d; for d in cockpit events themes settings.json integrity; do printf '%s ' "$d"; if [ -d "$HOMEDIR/$d" ]; then tree_hash "$HOMEDIR/$d"; else cksum < "$HOMEDIR/$d"; fi; done; }
target() { readlink "$HOMEDIR/current" 2>/dev/null || echo none; }
leftovers() { find "$HOMEDIR" -maxdepth 2 \( -name '.tmp-*' -o -name '.boot.*' -o -name '.update.lock' -o -name '.current.tmp.*' \) | sed -n 1p; }

# ── the stub release: binaries (published once, per key), and a zip + manifest line per version ─────────────────────────────────────────────
KEY=abcdef012345; BADKEY=0123456789ab
mkbin() { printf '#!/bin/sh\n[ "$1" = --version ] && { echo "x (%s)"; exit 0; }\nsleep "${1:-0}"\n' "${KEY:0:8}" > "$1"; chmod +x "$1"; }
# t-bdb0: one program, canon-go, released as canon-go-<key>/canon-go-<target>; the manifest keeps the two older programs' lines (as canon's
# does), and the fetch must take only the canon-go line
mkdir -p "$W/bin/canon-go-$KEY" "$W/bin/cockpit-daemon-$KEY" "$W/bin/sprint-check-$KEY"
mkbin "$W/bin/canon-go-$KEY/canon-go-$os-$arch"; mkbin "$W/bin/cockpit-daemon-$KEY/cockpit-daemon-$os-$arch"; mkbin "$W/bin/sprint-check-$KEY/sprint-check-$os-$arch"
CSHA="$(sha "$W/bin/canon-go-$KEY/canon-go-$os-$arch")"; DSHA="$(sha "$W/bin/cockpit-daemon-$KEY/cockpit-daemon-$os-$arch")"; BSHA="$(sha "$W/bin/sprint-check-$KEY/sprint-check-$os-$arch")"
COMMIT="$(printf 'c%.0s' $(seq 1 40))"
: > "$W/releases.txt"
fill_tree() {   # <dir> <version> [daemon key]: canon's real update code, a stub skills.sh that logs who refreshed what
  local d="$1" k="${3:-$KEY}"
  mkdir -p "$d/tools"; echo "$2" > "$d/VERSION"
  cp "$ROOT/tools/canon" "$ROOT/tools/pkg-lib.sh" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$ROOT/tools/ticket-root.sh" \
    "$ROOT/tools/release-manifest.sh" "$ROOT/tools/fetch-daemon.sh" "$ROOT/tools/src-key.sh" "$ROOT/tools/cockpit-stop-lib.sh" "$d/tools/"
  printf '#!/usr/bin/env bash\necho "$(cd "$(dirname "$0")/.." && pwd -P) $*" >> "${REFRESH_LOG:-/dev/null}"\n' > "$d/tools/skills.sh"; chmod +x "$d/tools/skills.sh"
  printf '%s %s %s\n%s sprint-check-%s %s\n%s canon-go-%s %s\n' "$k" "$os-$arch" "$DSHA" "$k" "$os-$arch" "$BSHA" "$k" "$os-$arch" "$CSHA" > "$d/tools/cockpit-daemon.sha256"
}
release() {   # <version> [daemon key]: build canon-<version>.zip and publish its manifest line
  local v="$1" z="$W/rel/v$1/canon-$1.zip"
  fill_tree "$W/src/$v/canon-$v" "$v" "${2:-}"
  mkdir -p "$W/rel/v$v"; rm -f "$z"; ( cd "$W/src/$v" && zip -qr "$z" "canon-$v" )
  printf 'v%s %s %s\n' "$v" "$(sha "$z")" "$COMMIT" >> "$W/releases.txt"
}
# CANON_REPO for the installers' bootstrap clone and for --to main: the same code on a git main branch (its fetch-daemon is a stub: a clone's
# real one names binaries from the Go source, which this tree does not carry)
fill_tree "$W/upstream" 2.0.0-dev
printf '#!/bin/sh\necho "main fetch-daemon ran"\n' > "$W/upstream/tools/fetch-daemon.sh"
git -C "$W/upstream" init -q -b main; git -C "$W/upstream" add -A; git -C "$W/upstream" -c user.email=t@e -c user.name=t commit -qm seed

# ── C1, C11: a fresh install.sh into an empty home builds packages/<v>/ and current (prod path: install.sh) ─────────────────────────────────
release 1.0.0
out="$(run bash "$ROOT/install.sh" 2>&1)" || fail "install.sh failed: $out"
assert_eq "packages/v1.0.0" "$(target)"
[ -L "$HOMEDIR/current" ] || fail "current is not a symlink"
[ ! -e "$HOMEDIR/packages/v1.0.0/.git" ] || fail "a release package carries .git"
[ -x "$HOMEDIR/packages/v1.0.0/tools/canon-go-bin/canon-go" ] || fail "the package's binary is not inside it: $out"
[ ! -e "$HOMEDIR/packages/v1.0.0/tools/cockpit-daemon" ] && [ ! -e "$HOMEDIR/packages/v1.0.0/tools/sprint-check-bin" ] || fail "a package holds a program canon-go replaced"
assert_eq "canon 1.0.0" "$(run "$C" version)"
assert_eq "current/tools" "$(readlink "$HOMEDIR/tools")"; assert_eq "canon 1.0.0" "$(run "$HOMEDIR/tools/canon" version)"   # ~/.canon/tools/... as the docs name it
assert_contains "$out" "canon is now on v1.0.0, verified against the published manifest."; assert_contains "$out" "Installed the verified release v1.0.0"
[ -z "$(leftovers)" ] || fail "install left $(leftovers) behind"
[ ! -e "$HOMEDIR/.canon-track" ] || fail "a release install wrote a track marker"
echo "canon-packages: fresh install.sh builds packages/v1.0.0 and current (home with a space and non-ASCII)"

# install.js takes the same steps into its own home (prod path: bin/install.js)
out="$(env -u XDG_RUNTIME_DIR "${PIN[@]}" CANON_HOME="$H/js home" node "$ROOT/bin/install.js" 2>&1)" || fail "install.js failed: $out"
assert_eq "packages/v1.0.0" "$(readlink "$H/js home/current")"; [ -z "$(find "$H/js home/packages" -name '.boot.*')" ] || fail "install.js left its bootstrap clone"
echo "canon-packages: fresh install.js builds the same layout"
# re-running an installer over a release install updates it through canon update (moved here from install-sh.sh: it needs a release zip)
out="$(run bash "$ROOT/install.sh" 2>&1)" || fail "install.sh over a release install failed: $out"
assert_contains "$out" "canon is up to date (v1.0.0)."; refute_contains "$out" "up to date (v1.0.0, verified"; [[ "$out" != *"development version"* ]] || fail "a release install printed the main-track note: $out"
out="$(env -u XDG_RUNTIME_DIR "${PIN[@]}" CANON_HOME="$H/js home" CANON_REF=v9.9.9 node "$ROOT/bin/install.js" 2>&1)" || fail "install.js failed on a failed update: $out"
assert_contains "$out" "Skipping update."; assert_eq "packages/v1.0.0" "$(readlink "$H/js home/current")"
echo "canon-packages: an installer re-run updates through canon update; a failed one keeps the install"

# a release that cannot be verified installs nothing into a home that did not exist; in one that did, only what the run made goes
set +e; out="$(env -u XDG_RUNTIME_DIR "${PIN[@]}" CANON_HOME="$H/norel" CANON_REF=v9.9.9 bash "$ROOT/install.sh" 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; [ ! -e "$H/norel" ] || fail "a failed install left $H/norel"; assert_contains "$out" "nothing was installed"
mkdir -p "$H/kept/cockpit"; echo keep > "$H/kept/cockpit/projects.json"
set +e; out="$(env -u XDG_RUNTIME_DIR "${PIN[@]}" CANON_HOME="$H/kept" CANON_REF=v9.9.9 bash "$ROOT/install.sh" 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_eq "cockpit" "$(ls -A "$H/kept")"; assert_eq keep "$(cat "$H/kept/cockpit/projects.json")"
echo "canon-packages: a failed fresh install removes only what it made"

# ── C2, C6: an update writes a new package and flips current; the old package and the data are byte-identical (prod path: canon update) ──────
mkdir -p "$HOMEDIR/cockpit" "$HOMEDIR/events" "$HOMEDIR/themes" "$HOMEDIR/integrity"
printf '[{"id": "a", "path": "%s", "name": "p"}]\n' "$W/proj" > "$HOMEDIR/cockpit/projects.json"
echo '{"t":1}' > "$HOMEDIR/events/2026-10-28.jsonl"; echo dark > "$HOMEDIR/themes/t.css"; echo '{}' > "$HOMEDIR/settings.json"; echo x > "$HOMEDIR/integrity/list"
DATA="$(data_hash)"; OLD="$(tree_hash "$HOMEDIR/packages/v1.0.0")"
release 1.1.0
: > "$W/refresh.log"
out="$(run "$C" update 2>&1)" || fail "update to v1.1.0 failed: $out"
assert_eq "packages/v1.1.0" "$(target)"; assert_contains "$out" "canon is now on v1.1.0, verified against the published manifest."
assert_eq "$OLD" "$(tree_hash "$HOMEDIR/packages/v1.0.0")"; assert_eq "$DATA" "$(data_hash)"
assert_eq "$HOMEDIR/packages/v1.1.0 refresh $W/proj" "$(cat "$W/refresh.log")"   # the refresh ran the NEW package's skills.sh
for d in cockpit events themes settings.json integrity .canon-track; do
  [ -z "$(find "$HOMEDIR/packages" -name "$d" -maxdepth 2)" ] || fail "$d is inside a package"
done
[ -z "$(leftovers)" ] || fail "update left $(leftovers) behind"
echo "canon-packages: update writes packages/v1.1.0, flips current, the old package and the data are unchanged, the new package refreshes"

# the flip is a rename: a reader polling the link never finds it missing or pointing elsewhere across repeated repoints. It reads the link
# itself (lstat/readlink): on macOS a lookup THROUGH a link that is being renamed over can fail now and then (EINVAL) even for a bare rename(2),
# so a read through current/ cannot tell atomic from not; an unlink-then-create flip (ln -sfn) fails this check hundreds of times.
rm -f "$W/miss" "$W/stop"
( while [ ! -e "$W/stop" ]; do case "$(readlink "$HOMEDIR/current")" in packages/v1.0.0|packages/v1.1.0) ;; *) echo miss >> "$W/miss" ;; esac; done ) & RP=$!; PIDS+=("$RP")
for i in 1 2 3 4 5; do run "$C" update --to v1.0.0 >/dev/null 2>&1 || fail "repoint to v1.0.0 failed"; run "$C" update --to v1.1.0 >/dev/null 2>&1 || fail "repoint to v1.1.0 failed"; done
touch "$W/stop"; wait "$RP" 2>/dev/null || true
[ ! -s "$W/miss" ] || fail "a reader found current missing $(wc -l < "$W/miss") time(s) during flips"
echo "canon-packages: 10 flips, current never missing for a concurrent reader"

# ── C3: each fault leaves current and the old package unchanged and exits non-zero with the reason (prod path: canon update) ─────────────────
OLD="$(tree_hash "$HOMEDIR/packages/v1.1.0")"
faulted() {   # <label> <expected reason>
  set +e; out="$(run "$C" update --to v1.2.0 2>&1)"; code=$?; set -e
  [ "$code" != 0 ] || fail "$1: update exited 0: $out"
  assert_contains "$out" "$2"; assert_contains "$out" "Nothing was changed."
  assert_eq "packages/v1.1.0" "$(target)"; assert_eq "$OLD" "$(tree_hash "$HOMEDIR/packages/v1.1.0")"; assert_eq "$DATA" "$(data_hash)"
  [ ! -e "$HOMEDIR/packages/v1.2.0" ] || fail "$1: a partial packages/v1.2.0 was left"
  [ -z "$(leftovers)" ] || fail "$1: left $(leftovers) behind"
  echo "canon-packages: refused, changing nothing, when $1"
}
release 1.2.0; mv "$W/rel/v1.2.0/canon-1.2.0.zip" "$W/rel/v1.2.0/hidden.zip"
faulted "the download fails" "the download of v1.2.0 failed"
mv "$W/rel/v1.2.0/hidden.zip" "$W/rel/v1.2.0/canon-1.2.0.zip"; cp "$W/rel/v1.2.0/canon-1.2.0.zip" "$W/good-1.2.0.zip"
echo tamper >> "$W/rel/v1.2.0/canon-1.2.0.zip"
faulted "the zip does not match the manifest's SHA-256" "does not match the published checksum"
head -c 200 "$W/good-1.2.0.zip" > "$W/rel/v1.2.0/canon-1.2.0.zip"   # a truncated zip the manifest vouches for: only the unpack can catch it
grep -v '^v1.2.0 ' "$W/releases.txt" > "$W/r.tmp"; printf 'v1.2.0 %s %s\n' "$(sha "$W/rel/v1.2.0/canon-1.2.0.zip")" "$COMMIT" >> "$W/r.tmp"; mv "$W/r.tmp" "$W/releases.txt"
faulted "the zip cannot be unpacked" "could not unpack the v1.2.0 zip"
grep -v '^v1.2.0 ' "$W/releases.txt" > "$W/r.tmp"; mv "$W/r.tmp" "$W/releases.txt"; rm -rf "$W/src/1.2.0"
release 1.2.0 "$BADKEY"   # its binaries were never published
faulted "the binaries cannot be fetched" "the board and daemon for v1.2.0 could not be fetched"
grep -v '^v1.2.0 ' "$W/releases.txt" > "$W/r.tmp"; mv "$W/r.tmp" "$W/releases.txt"; rm -rf "$W/src/1.2.0"
release 1.2.0

# ── C4: a live update's lock refuses a second one; a dead one's lock is taken over (prod path: canon update) ──────────────────────────────────
sleep 300 & LP=$!; PIDS+=("$LP")
mkdir "$HOMEDIR/.update.lock"; echo "$LP" > "$HOMEDIR/.update.lock/pid"
set +e; out="$(run "$C" update --to v1.2.0 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "another canon update is running (pid $LP"; assert_contains "$out" "Nothing was changed."
assert_eq "packages/v1.1.0" "$(target)"; [ ! -e "$HOMEDIR/packages/v1.2.0" ] || fail "a locked-out update built a package"
assert_eq "$LP" "$(cat "$HOMEDIR/.update.lock/pid")"   # the live lock is left as it was
kill "$LP"; wait "$LP" 2>/dev/null || true
out="$(run "$C" update --to v1.2.0 2>&1)" || fail "an update did not take over a dead update's lock: $out"
assert_contains "$out" "took over the update lock of an update that is no longer running (pid $LP)"; assert_eq "packages/v1.2.0" "$(target)"
[ ! -e "$HOMEDIR/.update.lock" ] || fail "the lock was not released"
echo "canon-packages: a live lock refuses, a dead one is taken over and released"

# ── C5, C6: rollback is a repoint with nothing downloaded; data unchanged (prod path: canon update --to <installed>) ─────────────────────────────
OLD="$(tree_hash "$HOMEDIR/packages/v1.2.0")"
out="$(run env CANON_MANIFEST_URL="file://$W/nowhere" CANON_RELEASE_BASE="file://$W/nowhere" CANON_DAEMON_RELEASE_BASE="file://$W/nowhere" "$C" update --to v1.1.0 2>&1)" \
  || fail "rollback with no network failed: $out"
assert_eq "packages/v1.1.0" "$(target)"; assert_contains "$out" "canon is now on v1.1.0 (already installed; nothing was downloaded)."
assert_eq "$OLD" "$(tree_hash "$HOMEDIR/packages/v1.2.0")"; assert_eq "$DATA" "$(data_hash)"
out="$(run "$C" update --to v1.1.0 2>&1)"; assert_contains "$out" "canon is up to date (v1.1.0"
echo "canon-packages: rollback --to v1.1.0 repoints without a download; data unchanged"

# leftovers of an interrupted update or install (a temp package, a bootstrap clone) go on the next update; one a live installer uses stays
mkdir -p "$HOMEDIR/packages/.tmp-v9.9.9.AbC" "$HOMEDIR/packages/.boot.Old" "$HOMEDIR/packages/.boot.Live/tools"
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/packages/.boot.Live/tools/canon" & BL=$!; PIDS+=("$BL"); sleep 0.3
out="$(run "$C" update --to v1.1.0 2>&1)" || fail "update with leftovers failed: $out"
[ ! -e "$HOMEDIR/packages/.tmp-v9.9.9.AbC" ] && [ ! -e "$HOMEDIR/packages/.boot.Old" ] || fail "an update did not sweep the leftovers"
[ -d "$HOMEDIR/packages/.boot.Live" ] || fail "an update swept the bootstrap clone of a running installer"
kill "$BL"; wait "$BL" 2>/dev/null || true; rm -rf "$HOMEDIR/packages/.boot.Live"
echo "canon-packages: leftovers of an interrupted update are swept under the lock; a live installer's clone is kept"

# ── C5: prune keeps the 2 newest old packages and never one a live process runs from (prod path: canon update) ──────────────────────────────────
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/packages/v1.0.0/tools/canon-go-bin/canon-go daemon" & SP=$!; PIDS+=("$SP")
release 1.3.0
out="$(run "$C" update 2>&1)" || fail "update to v1.3.0 failed: $out"
assert_eq "packages/v1.3.0" "$(target)"; assert_contains "$out" "kept old package v1.0.0 (a running program uses it)"
[ -d "$HOMEDIR/packages/v1.0.0" ] && [ -d "$HOMEDIR/packages/v1.1.0" ] && [ -d "$HOMEDIR/packages/v1.2.0" ] || fail "prune removed a package it must keep"
kill "$SP"; wait "$SP" 2>/dev/null || true
out="$(run "$C" update 2>&1)" || fail "re-run update failed: $out"
assert_contains "$out" "removed old package v1.0.0"; [ ! -e "$HOMEDIR/packages/v1.0.0" ] || fail "an idle old package was not pruned"
assert_eq "v1.1.0 v1.2.0 v1.3.0" "$(cd "$HOMEDIR/packages" && echo v*)"
echo "canon-packages: prune keeps current + 2 old, skips a package a process runs from, removes it once idle"

# ── C9: update refuses while this install's daemon runs, names it and canon stop, and changes nothing; it stops nothing (prod path: canon update)
# (t-bdb0: the stub daemon's argv0 carries the mode word, so ps shows what `canon-go daemon -addr ...` shows)
OLD="$(tree_hash "$HOMEDIR/packages/v1.3.0")"
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/packages/v1.3.0/tools/canon-go-bin/canon-go daemon" & DP=$!; PIDS+=("$DP")
printf '{"pid": %s}\n' "$DP" > "$W/state/daemon.json"
sleep 0.3
set +e; out="$(run "$C" update --to v1.2.0 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "the Cockpit daemon (pid $DP)"; assert_contains "$out" "Run 'canon stop', then run canon update again."; assert_contains "$out" "Nothing was changed."
assert_eq "packages/v1.3.0" "$(target)"; assert_eq "$OLD" "$(tree_hash "$HOMEDIR/packages/v1.3.0")"; [ -z "$(leftovers)" ] || fail "a refused update left $(leftovers)"
pid_alive "$DP" || fail "update stopped the daemon"
# another install's daemon (a path outside this home) does not block
kill "$DP"; wait "$DP" 2>/dev/null || true
mkdir -p "$W/other/tools/canon-go-bin"; bash -c 'exec -a "$0" sleep 300' "$W/other/tools/canon-go-bin/canon-go daemon" & DP=$!; PIDS+=("$DP")
printf '{"pid": %s}\n' "$DP" > "$W/state/daemon.json"; sleep 0.3
out="$(run "$C" update --to v1.3.0 2>&1)" || fail "another install's daemon blocked the update: $out"
kill "$DP"; wait "$DP" 2>/dev/null || true; rm -f "$W/state/daemon.json"
# the board: a listener on the Cockpit port whose command line is a package's canon-go in board mode, started through current (t-50f7 phase 2;
# t-bdb0: the stub's argv0 carries the mode word, so ps shows what `canon-go board <port>` shows)
BP_PORT=$(( 20000 + $$ % 20000 ))
bash -c 'exec -a "$0" perl -MIO::Socket::INET -e "my \$s = IO::Socket::INET->new(LocalAddr => q(127.0.0.1), LocalPort => \$ARGV[0], Listen => 5, ReuseAddr => 1) or die; sleep 300" "$1"' \
  "$HOMEDIR/current/tools/canon-go-bin/canon-go board" "$BP_PORT" & BP=$!; PIDS+=("$BP")
listening() { if command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; else [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]; fi; }
for i in 1 2 3 4 5 6 7 8 9 10; do listening "$BP_PORT" && break; sleep 0.3; done
listening "$BP_PORT" || fail "the stub board never listened on $BP_PORT"
set +e; out="$(run env CANON_COCKPIT_PORT="$BP_PORT" "$C" update --to v1.2.0 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "the board (pid $BP)"; assert_contains "$out" "Run 'canon stop'"; assert_eq "packages/v1.3.0" "$(target)"
pid_alive "$BP" || fail "update stopped the board"
kill "$BP"; wait "$BP" 2>/dev/null || true
echo "canon-packages: update refuses while this install's daemon or board runs (names it, says canon stop, stops nothing); another install's daemon does not block"

# ── C10: --to main keeps a clone in packages/main, updated in place, and current can point at it (prod path: canon update --to main) ─────────────
out="$(run "$C" update --to main 2>&1)" || fail "--to main failed: $out"
assert_eq "packages/main" "$(target)"; assert_eq "$(git -C "$W/upstream" rev-parse HEAD)" "$(git -C "$HOMEDIR/packages/main" rev-parse HEAD)"
assert_eq main "$(tr -d '[:space:]' < "$HOMEDIR/.canon-track")"; assert_contains "$out" "canon now follows main"; assert_contains "$out" "main fetch-daemon ran"
assert_eq "canon 2.0.0-dev (development version, following main)" "$(run "$C" version | sed -n 1p)"
echo next > "$W/upstream/NEWS"; git -C "$W/upstream" add NEWS; git -C "$W/upstream" -c user.email=t@e -c user.name=t commit -qm news
out="$(run "$C" update 2>&1)" || fail "a plain update on main failed: $out"   # the marker keeps it on main
assert_eq "$(git -C "$W/upstream" rev-parse HEAD)" "$(git -C "$HOMEDIR/packages/main" rev-parse HEAD)"; assert_contains "$out" "canon updated "
echo wip > "$HOMEDIR/packages/main/scratch.txt"
set +e; out="$(run "$C" update 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "has uncommitted changes"; assert_eq "packages/main" "$(target)"
rm "$HOMEDIR/packages/main/scratch.txt"
out="$(run "$C" update --to latest 2>&1)" || fail "--to latest from main failed: $out"
assert_eq "packages/v1.3.0" "$(target)"; [ ! -e "$HOMEDIR/.canon-track" ] || fail "the main marker survived --to latest"; [ -d "$HOMEDIR/packages/main/.git" ] || fail "the main clone was removed"
assert_eq "$DATA" "$(data_hash)"
echo "canon-packages: --to main clones packages/main and pulls it in place; --to latest goes back; data unchanged"

# ── t-9df0: canon update --reinstall puts a release package back as published (prod path: canon update --reinstall, integrity's restore hint) ──
PK="$HOMEDIR/packages/v1.3.0"; GATE="tools/pkg-lib.sh"; PUB="$W/src/1.3.0/canon-1.3.0/$GATE"
echo '# tampered' >> "$PK/$GATE"
out="$(run "$C" update 2>&1)" || fail "a plain update on the current release failed: $out"   # a plain update repoints: no download, no repair
assert_contains "$out" "canon is up to date (v1.3.0)."; refute_contains "$out" "verified"; refute_contains "$out" "Downloading"
cmp -s "$PUB" "$PK/$GATE" && fail "a plain update repaired a changed file (it must not download)"
mv "$W/rel/v1.3.0/canon-1.3.0.zip" "$W/zip.bak"
CUR="$(tree_hash "$PK")"; DATA="$(data_hash)"
set +e; out="$(run "$C" update --reinstall 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "Nothing was changed"
assert_eq "$CUR" "$(tree_hash "$PK")"; assert_eq "$DATA" "$(data_hash)"; assert_eq "packages/v1.3.0" "$(target)"; [ -z "$(leftovers)" ] || fail "a failed reinstall left $(leftovers)"
{ cat "$W/zip.bak"; echo junk; } > "$W/rel/v1.3.0/canon-1.3.0.zip"   # downloads, but hashes differently from the manifest
set +e; out="$(run "$C" update --reinstall 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "does not match the published checksum"
assert_eq "$CUR" "$(tree_hash "$PK")"; assert_eq "$DATA" "$(data_hash)"; assert_eq "packages/v1.3.0" "$(target)"; [ -z "$(leftovers)" ] || fail "a mismatched reinstall left $(leftovers)"
cp "$W/zip.bak" "$W/rel/v1.3.0/canon-1.3.0.zip"
echo "canon-packages: a failed or mismatched reinstall download changes nothing; a plain update on the current release downloads nothing and does not claim verification"

# refusals change nothing: the Cockpit running (the board stub, as above), packages/main, a tag that is not installed
bash -c 'exec -a "$0" perl -MIO::Socket::INET -e "my \$s = IO::Socket::INET->new(LocalAddr => q(127.0.0.1), LocalPort => \$ARGV[0], Listen => 5, ReuseAddr => 1) or die; sleep 300" "$1"' \
  "$HOMEDIR/current/tools/canon-go-bin/canon-go board" "$BP_PORT" & BP=$!; PIDS+=("$BP")
for i in 1 2 3 4 5 6 7 8 9 10; do listening "$BP_PORT" && break; sleep 0.3; done
listening "$BP_PORT" || fail "the stub board never listened on $BP_PORT"
set +e; out="$(run env CANON_COCKPIT_PORT="$BP_PORT" "$C" update --reinstall 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "Run 'canon stop'"; assert_eq "$CUR" "$(tree_hash "$PK")"
kill "$BP"; wait "$BP" 2>/dev/null || true
set +e; out="$(run "$C" update --reinstall --to main 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "git -C $HOMEDIR/packages/main checkout --"; assert_eq "$CUR" "$(tree_hash "$PK")"
set +e; out="$(run "$C" update --reinstall --to v9.9.9 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "is not installed"; assert_eq "$CUR" "$(tree_hash "$PK")"
run "$C" update --to main >/dev/null 2>&1 || fail "--to main failed"
MAINH="$(git -C "$HOMEDIR/packages/main" rev-parse HEAD)"
set +e; out="$(run "$C" update --reinstall 2>&1)"; code=$?; set -e   # current is main
assert_eq 1 "$code"; assert_contains "$out" "git -C $HOMEDIR/packages/main checkout --"; assert_eq packages/main "$(target)"; assert_eq "$MAINH" "$(git -C "$HOMEDIR/packages/main" rev-parse HEAD)"
run "$C" update --to v1.3.0 >/dev/null 2>&1 || fail "back to v1.3.0 failed"; rm -f "$HOMEDIR/.canon-track"
echo "canon-packages: --reinstall refuses while the Cockpit runs, on main, and for a tag that is not installed, changing nothing"

# the repair: the changed gate file is byte-identical to the release again; current, the data and the other packages are untouched
ODIR="$(find "$HOMEDIR/packages" -maxdepth 1 -name 'v*' ! -name v1.3.0 | sort | sed -n 1p)"; OTHER="$(tree_hash "$ODIR")"
out="$(run "$C" update --reinstall 2>&1)" || fail "reinstall failed: $out"
cmp -s "$PUB" "$PK/$GATE" || fail "reinstall did not restore $GATE byte-identical"
assert_contains "$out" "reinstalled"; assert_eq "packages/v1.3.0" "$(target)"; assert_eq "$DATA" "$(data_hash)"; assert_eq "$OTHER" "$(tree_hash "$ODIR")"
[ -z "$(leftovers)" ] || fail "reinstall left $(leftovers)"; [ -f "$PK/tools/canon-go-bin/canon-go" ] || fail "the reinstalled package lost its binary"
echo "canon-packages: --reinstall restores a changed file in the current release package byte-identical, data and other packages unchanged"

# guards: --reinstall wants a tag (not latest); a git checkout is repaired with git; a program still running from the replaced copy keeps it, named
CUR="$(tree_hash "$PK")"
set +e; out="$(run "$C" update --reinstall --to latest 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "--reinstall takes a release tag"; assert_eq "$CUR" "$(tree_hash "$PK")"
set +e; out="$(run "$ROOT/tools/canon" update --reinstall 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "this install is a git checkout"; assert_contains "$out" "checkout -- <file>"
bash -c 'exec -a "$0" sleep 120' "$PK/tools/stub-running" & KP=$!; PIDS+=("$KP")
sleep 0.5
out="$(run "$C" update --reinstall 2>&1)" || fail "reinstall with a running program failed: $out"
assert_contains "$out" "kept the replaced v1.3.0 package"; [ -d "$(find "$HOMEDIR/packages" -maxdepth 1 -name '.tmp-v1.3.0.old.*' | sed -n 1p)" ] || fail "the replaced package was not kept"
kill "$KP"; wait "$KP" 2>/dev/null || true; rm -rf "$HOMEDIR"/packages/.tmp-v1.3.0.old.*
echo "canon-packages: --reinstall refuses --to latest and a git checkout, and keeps the replaced package while a program runs from it"

# pkg_install turns its tag into a folder name and a download path: a traversal or a non-release tag is refused before anything is made.
for bad in "../../etc" "v1.0" "main" "v1.0.0/../x"; do
  set +e; ( source "$ROOT/tools/pkg-lib.sh"; pkg_install "$W/guard-home" "$bad" abc ) >/dev/null 2>&1; code=$?; set -e
  assert_eq 1 "$code"; [ ! -e "$W/guard-home" ] || fail "pkg_install made $W/guard-home for tag '$bad'"
done
echo "canon-packages: a non-release tag is refused before anything is written"

# ── review fixes (t-50f7 phase 3) ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
# A developer clone under any folder named packages (a monorepo) stays a clone: canon update writes nothing outside it (prod path: tools/canon
# install_home), and pkg_flip/pkg_sweep/pkg_prune refuse a folder with no current link and no install in progress (pkg_home_ok).
mkdir -p "$W/mono/packages"; git clone -q "$W/upstream" "$W/mono/packages/canon"
out="$(run env CANON_HOME="$H/not-this-one" "$W/mono/packages/canon/tools/canon" update --to main 2>&1)" || fail "a clone under packages/ failed its clone-mode update: $out"
assert_contains "$out" "canon is up to date"; assert_eq "packages" "$(ls -A "$W/mono")"; assert_eq "canon" "$(ls -A "$W/mono/packages")"
mkdir -p "$W/mono/packages/.tmp-v1.0.0.x" "$W/mono/packages/.boot-no" "$W/mono/packages/v1.0.0" "$W/mono/packages/v1.1.0" "$W/mono/packages/v1.2.0" "$W/mono/packages/v1.3.0"
before="$(ls -A "$W/mono/packages" | tr '\n' ' ')"
set +e; ( source "$ROOT/tools/pkg-lib.sh"; pkg_sweep "$W/mono"; pkg_prune "$W/mono"; pkg_flip "$W/mono" canon ) >/dev/null 2>&1; code=$?; set -e
assert_eq 1 "$code"; assert_eq "$before" "$(ls -A "$W/mono/packages" | tr '\n' ' ')"; [ ! -e "$W/mono/current" ] && [ ! -L "$W/mono/current" ] || fail "pkg_flip made $W/mono/current"
echo "canon-packages: a clone under a folder named packages stays a clone; the layout helpers refuse a folder that is not a canon home"

# prune also counts a program started through <home>/current/ or <home>/tools/ while current named the package (prod path: pkg_prune, pkg_in_use)
out="$(run "$C" update --to v1.1.0 2>&1)" || fail "repoint to v1.1.0 failed: $out"
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/current/tools/canon-go-bin/canon-go daemon" & CP=$!; PIDS+=("$CP"); sleep 0.3
release 1.4.0
out="$(run "$C" update 2>&1)" || fail "update to v1.4.0 failed: $out"
assert_eq "packages/v1.4.0" "$(target)"; assert_contains "$out" "kept old package v1.1.0 (a running program uses it)"; [ -d "$HOMEDIR/packages/v1.1.0" ] || fail "pruned a package a program runs from through current"
kill "$CP"; wait "$CP" 2>/dev/null || true
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/tools/tkt" & TP=$!; PIDS+=("$TP"); sleep 0.3
( source "$ROOT/tools/pkg-lib.sh"; pkg_in_use "$HOMEDIR/packages/v1.1.0" 1 ) || fail "pkg_in_use does not count a program started through <home>/tools/"
( source "$ROOT/tools/pkg-lib.sh"; pkg_in_use "$HOMEDIR/packages/v1.1.0" 0 ) && fail "pkg_in_use counts <home>/tools/ for a package current did not name"
kill "$TP"; wait "$TP" 2>/dev/null || true
echo "canon-packages: prune keeps the package current named when a program was started through current/ or tools/"

# Under a C locale, ps prints a non-ASCII path escaped; ps runs under a UTF-8 locale, and with none on the machine nothing in a non-ASCII home
# is deleted (fail closed), and it says so once (prod path: pkg_in_use, pkg_sweep, platform-lib ps_utf8)
mkdir -p "$W/nolocale"; printf '#!/bin/sh\nprintf "C\\nPOSIX\\n"\n' > "$W/nolocale/locale"; chmod +x "$W/nolocale/locale"
mkdir -p "$HOMEDIR/packages/.tmp-v9.9.9.Blind"
out="$(run env -u LANG -u LC_ALL -u LC_CTYPE PATH="$W/nolocale:$PATH" "$C" update --to v1.4.0 2>&1)" || fail "update without a UTF-8 locale failed: $out"
[ -d "$HOMEDIR/packages/.tmp-v9.9.9.Blind" ] || fail "with no UTF-8 locale, a leftover in a non-ASCII home was deleted"
assert_eq 1 "$(grep -c 'has non-ASCII letters and this machine has no UTF-8 locale' <<<"$out")"
out="$(run env -u LANG -u LC_ALL -u LC_CTYPE "$C" update --to v1.4.0 2>&1)" || fail "update under the C locale failed: $out"
[ ! -e "$HOMEDIR/packages/.tmp-v9.9.9.Blind" ] || fail "under the C locale (a UTF-8 locale on the machine), the leftover was not swept"
echo "canon-packages: no UTF-8 locale on the machine keeps everything in a non-ASCII home and says so once; the C locale alone does not"

# A planted .tmp-migrate.* (an interrupted move into the layout: the user's files) survives an update's sweep (prod path: pkg_sweep)
mkdir -p "$HOMEDIR/packages/.tmp-migrate.Keep"; echo mine > "$HOMEDIR/packages/.tmp-migrate.Keep/notes.txt"
out="$(run "$C" update --to v1.4.0 2>&1)" || fail "update failed: $out"
assert_eq mine "$(cat "$HOMEDIR/packages/.tmp-migrate.Keep/notes.txt")"
echo "canon-packages: an update's sweep never deletes a .tmp-migrate.* folder"

# file:// downloads only through the test seam: the same file:// base without CANON_RELEASE_BASE is refused (prod path: pkg_install's curl)
mkdir -p "$W/proto-home/packages"
( unset CANON_RELEASE_BASE; export CANON_DAEMON_RELEASE_BASE="file://$W/bin" CANON_FETCH_NO_BUILD=1   # a regression must not reach the network
  source "$ROOT/tools/pkg-lib.sh"; PKG_RELEASE_BASE="file://$W/rel"
  if pkg_install "$W/proto-home" v1.0.0 "$(sha "$W/rel/v1.0.0/canon-1.0.0.zip")"; then exit 3; fi; echo "$PKG_ERR" ) > "$W/proto.out" 2>&1 \
  || fail "a file:// download without the seam was allowed: $(cat "$W/proto.out")"
assert_contains "$(cat "$W/proto.out")" "the download of v1.0.0 failed"; [ ! -e "$W/proto-home/packages/v1.0.0" ] || fail "a refused download left a package"
echo "canon-packages: a file:// release base is refused unless it is the CANON_RELEASE_BASE test seam"

# a dead lock taken over by two updates at once: exactly one wins (prod path: pkg_lock). A stub rm on PATH holds each contender's removal under
# the lock path for its own time (1 s, 2 s): the interleaving where a check-then-remove takeover lets both win (both see the dead pid; the
# first removes it and makes its lock; the second then removes THAT lock and makes its own).
mkdir -p "$W/slowrm"; printf '#!/bin/sh\ncase "$*" in *.update.lock*) sleep "${RM_SLEEP:-0}" ;; esac\nexec "%s" "$@"\n' "$(command -v rm)" > "$W/slowrm/rm"; chmod +x "$W/slowrm/rm"
wins=0
for i in 1 2 3; do
  rm -rf "$W/lockhome"; mkdir -p "$W/lockhome/.update.lock"; echo 999999 > "$W/lockhome/.update.lock/pid"
  for j in 1 2; do ( PATH="$W/slowrm:$PATH"; export RM_SLEEP="$j"; source "$ROOT/tools/pkg-lib.sh"; pkg_lock "$W/lockhome" && { echo won >> "$W/lockhome/wins"; sleep 3; } ) >/dev/null 2>&1 & done
  wait
  n="$(wc -l < "$W/lockhome/wins" 2>/dev/null | tr -d ' ')" || n=0
  [ "${n:-0}" = 1 ] || fail "trial $i: ${n:-0} updates took over the same dead lock"
  wins=$((wins + 1))
done
echo "canon-packages: $wins trials, one dead lock taken over by exactly one of two updates"

# ── t-bdb0: an update from the v0.29.0 layout (a package holding the two programs cockpit-daemon and sprint-check, updated by v0.29.0's own
# canon and pkg-lib) to a package holding canon-go works; the new package then starts the board and the daemon (`canon-go board <port>`, which
# starts `canon-go daemon`), and canon stop ends both by path and mode word. Prod path: canon update from an older install, the new package's
# fetch-daemon.sh, start_cockpit_server, ensureCockpit, canon stop. The new release's binary is the real canon-go built from this checkout and
# stamped as a release is (tools/src-key.sh canon_ldflags); v0.29.0's tools come from its tag.
if git -C "$ROOT" cat-file -e "v0.29.0^{commit}" 2>/dev/null; then
  K2FULL="$(bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" canon-go' _ "$ROOT")"; K2="${K2FULL:0:12}"
  export SPRINT_CHECK_NO_BROWSER=1   # the board started below must never open a browser (tests/no-browser-in-tests.sh)
  REAL="$(build_board "$W/realbin" "$(bash -c 'source "$1/tools/src-key.sh"; canon_ldflags "$1"' _ "$ROOT")")"
  mkdir -p "$W/bin/canon-go-$K2"; cp "$REAL" "$W/bin/canon-go-$K2/canon-go-$os-$arch"; RSHA="$(sha "$REAL")"
  # v0.29.0: its own tools, a manifest naming only the two older programs (published above under $KEY)
  d="$W/src/0.29.0/canon-0.29.0"; mkdir -p "$d/tools"; echo 0.29.0 > "$d/VERSION"
  for f in canon pkg-lib.sh cockpit-launch-lib.sh platform-lib.sh ticket-root.sh release-manifest.sh fetch-daemon.sh src-key.sh cockpit-stop-lib.sh; do
    git -C "$ROOT" show "v0.29.0:tools/$f" > "$d/tools/$f"
  done
  chmod +x "$d/tools/canon"; cp "$W/src/1.0.0/canon-1.0.0/tools/skills.sh" "$d/tools/"
  printf '%s %s %s\n%s sprint-check-%s %s\n' "$KEY" "$os-$arch" "$DSHA" "$KEY" "$os-$arch" "$BSHA" > "$d/tools/cockpit-daemon.sha256"
  mkdir -p "$W/rel/v0.29.0"; ( cd "$W/src/0.29.0" && zip -qr "$W/rel/v0.29.0/canon-0.29.0.zip" canon-0.29.0 )
  printf 'v0.29.0 %s %s\n' "$(sha "$W/rel/v0.29.0/canon-0.29.0.zip")" "$COMMIT" >> "$W/releases.txt"
  # v0.30.0: this checkout's tools and board files; its manifest keeps the older lines and adds canon-go's
  fill_tree "$W/src/0.30.0/canon-0.30.0" 0.30.0; d="$W/src/0.30.0/canon-0.30.0"; cp -R "$ROOT/tools/sprint-check-app" "$d/tools/"
  printf '%s %s %s\n%s sprint-check-%s %s\n%s canon-go-%s %s\n' "$KEY" "$os-$arch" "$DSHA" "$KEY" "$os-$arch" "$BSHA" "$K2" "$os-$arch" "$RSHA" > "$d/tools/cockpit-daemon.sha256"
  mkdir -p "$W/rel/v0.30.0"; ( cd "$W/src/0.30.0" && zip -qr "$W/rel/v0.30.0/canon-0.30.0.zip" canon-0.30.0 )
  printf 'v0.30.0 %s %s\n' "$(sha "$W/rel/v0.30.0/canon-0.30.0.zip")" "$COMMIT" >> "$W/releases.txt"

  H2="$H/old home"; C2="$H2/current/tools/canon"; S2="$W/state2"; mkdir -m 700 "$S2"
  run2() { run env CANON_HOME="$H2" COCKPIT_STATE_DIR="$S2" "$@"; }
  out="$(run2 env CANON_REF=v0.29.0 bash "$ROOT/install.sh" 2>&1)" || fail "installing the v0.29.0 fixture failed: $out"
  assert_eq "packages/v0.29.0" "$(readlink "$H2/current")"
  [ -x "$H2/packages/v0.29.0/tools/cockpit-daemon/cockpit-daemon" ] && [ -x "$H2/packages/v0.29.0/tools/sprint-check-bin/sprint-check" ] \
    || fail "fixture: the v0.29.0 package does not hold the two older programs: $out"
  OLD2="$(tree_hash "$H2/packages/v0.29.0")"
  out="$(run2 "$C2" update --to v0.30.0 2>&1)" || fail "update from the v0.29.0 layout failed: $out"
  assert_eq "packages/v0.30.0" "$(readlink "$H2/current")"; assert_eq "$OLD2" "$(tree_hash "$H2/packages/v0.29.0")"
  cmp -s "$REAL" "$H2/packages/v0.30.0/tools/canon-go-bin/canon-go" || fail "the new package does not hold the verified canon-go: $out"
  [ ! -e "$H2/packages/v0.30.0/tools/cockpit-daemon" ] && [ ! -e "$H2/packages/v0.30.0/tools/sprint-check-bin" ] || fail "the new package holds a program canon-go replaced"
  # start it as a user does (`canon <port>` in a project), launch the daemon as the Cockpit does, then canon stop
  mkdir -p "$W/nobrowser"; printf '#!/bin/sh\nexit 0\n' > "$W/nobrowser/open"; cp "$W/nobrowser/open" "$W/nobrowser/xdg-open"; chmod +x "$W/nobrowser/"*
  P2="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  ( cd "$W/proj" && run2 env SPRINT_CHECK_NO_BROWSER=1 PATH="$W/nobrowser:$PATH" "$C2" "$P2" ) > "$W/launch2.out" 2>&1 & L2=$!; PIDS+=("$L2")
  for i in $(seq 1 100); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$P2/api/version" && break; sleep 0.1; done
  B2="$(lsof -nP -iTCP:"$P2" -sTCP:LISTEN -t 2>/dev/null | sed -n 1p)" || B2=""; [ -n "$B2" ] || fail "the new package's board never listened: $(cat "$W/launch2.out")"; PIDS+=("$B2")
  assert_contains "$(ps -ww -o command= -p "$B2")" "tools/canon-go-bin/canon-go board $P2"
  ck="$(curl -s --max-time 10 -X POST -H "Origin: http://127.0.0.1:$P2" -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$P2/api/cockpit")"
  assert_contains "$ck" '"running":true'; assert_contains "$ck" '"stale":false'
  D2="$(sed -n 's/.*"pid"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$S2/daemon.json")"; [ -n "$D2" ] || fail "the daemon wrote no pid: $ck"; PIDS+=("$D2")
  assert_contains "$(ps -ww -o command= -p "$D2")" "tools/canon-go-bin/canon-go daemon -addr 127.0.0.1:0"
  out="$(run2 env CANON_COCKPIT_PORT="$P2" "$C2" stop 2>&1)" || fail "canon stop failed: $out"
  assert_contains "$out" "Canon stopped: the Cockpit daemon and the board."
  for i in $(seq 1 50); do pid_alive "$D2" || pid_alive "$B2" || break; sleep 0.1; done
  ! pid_alive "$D2" && ! pid_alive "$B2" || fail "canon stop left the daemon ($D2) or the board ($B2) running"
  wait "$L2" 2>/dev/null || true
  echo "canon-packages: an update from the v0.29.0 layout installs canon-go, starts the board and its daemon, and canon stop ends both"
else
  echo "canon-packages: SKIPPED the v0.29.0 update case: this clone has no v0.29.0 tag (a shallow clone); run it in a full clone"
fi

assert_eq canary "$(cat "$H/canary")"; assert_eq canary "$(cat "$W/tmp/canary")"
echo "canon-packages: ok"
