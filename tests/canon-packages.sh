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
mkdir -p "$W/bin/cockpit-daemon-$KEY" "$W/bin/sprint-check-$KEY"
mkbin "$W/bin/cockpit-daemon-$KEY/cockpit-daemon-$os-$arch"; mkbin "$W/bin/sprint-check-$KEY/sprint-check-$os-$arch"
DSHA="$(sha "$W/bin/cockpit-daemon-$KEY/cockpit-daemon-$os-$arch")"; BSHA="$(sha "$W/bin/sprint-check-$KEY/sprint-check-$os-$arch")"
COMMIT="$(printf 'c%.0s' $(seq 1 40))"
: > "$W/releases.txt"
fill_tree() {   # <dir> <version> [daemon key]: canon's real update code, a stub skills.sh that logs who refreshed what
  local d="$1" k="${3:-$KEY}"
  mkdir -p "$d/tools"; echo "$2" > "$d/VERSION"
  cp "$ROOT/tools/canon" "$ROOT/tools/pkg-lib.sh" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$ROOT/tools/ticket-root.sh" \
    "$ROOT/tools/release-manifest.sh" "$ROOT/tools/fetch-daemon.sh" "$ROOT/tools/src-key.sh" "$ROOT/tools/cockpit-stop-lib.sh" "$d/tools/"
  printf '#!/usr/bin/env bash\necho "$(cd "$(dirname "$0")/.." && pwd -P) $*" >> "${REFRESH_LOG:-/dev/null}"\n' > "$d/tools/skills.sh"; chmod +x "$d/tools/skills.sh"
  printf '%s %s %s\n%s sprint-check-%s %s\n' "$k" "$os-$arch" "$DSHA" "$k" "$os-$arch" "$BSHA" > "$d/tools/cockpit-daemon.sha256"
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
[ -x "$HOMEDIR/packages/v1.0.0/tools/cockpit-daemon/cockpit-daemon" ] && [ -x "$HOMEDIR/packages/v1.0.0/tools/sprint-check-bin/sprint-check" ] \
  || fail "the package's binaries are not inside it: $out"
assert_eq "canon 1.0.0" "$(run "$C" version)"
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
assert_contains "$out" "canon is up to date (v1.0.0, verified"; [[ "$out" != *"development version"* ]] || fail "a release install printed the main-track note: $out"
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

# ── C5: prune keeps the 2 newest old packages and never one a live process runs from (prod path: canon update) ──────────────────────────────────
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/packages/v1.0.0/tools/cockpit-daemon/cockpit-daemon" & SP=$!; PIDS+=("$SP")
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
OLD="$(tree_hash "$HOMEDIR/packages/v1.3.0")"
bash -c 'exec -a "$0" sleep 300' "$HOMEDIR/packages/v1.3.0/tools/cockpit-daemon/cockpit-daemon" & DP=$!; PIDS+=("$DP")
printf '{"pid": %s}\n' "$DP" > "$W/state/daemon.json"
sleep 0.3
set +e; out="$(run "$C" update --to v1.2.0 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "the Cockpit daemon (pid $DP)"; assert_contains "$out" "Run 'canon stop', then run canon update again."; assert_contains "$out" "Nothing was changed."
assert_eq "packages/v1.3.0" "$(target)"; assert_eq "$OLD" "$(tree_hash "$HOMEDIR/packages/v1.3.0")"; [ -z "$(leftovers)" ] || fail "a refused update left $(leftovers)"
pid_alive "$DP" || fail "update stopped the daemon"
# another install's daemon (a path outside this home) does not block
kill "$DP"; wait "$DP" 2>/dev/null || true
mkdir -p "$W/other/tools/cockpit-daemon"; bash -c 'exec -a "$0" sleep 300' "$W/other/tools/cockpit-daemon/cockpit-daemon" & DP=$!; PIDS+=("$DP")
printf '{"pid": %s}\n' "$DP" > "$W/state/daemon.json"; sleep 0.3
out="$(run "$C" update --to v1.3.0 2>&1)" || fail "another install's daemon blocked the update: $out"
kill "$DP"; wait "$DP" 2>/dev/null || true; rm -f "$W/state/daemon.json"
echo "canon-packages: update refuses while this install's daemon runs (names it, says canon stop, stops nothing); another install's does not block"

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

assert_eq canary "$(cat "$H/canary")"; assert_eq canary "$(cat "$W/tmp/canary")"
echo "canon-packages: ok"
