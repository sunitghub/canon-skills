#!/usr/bin/env bash
# install-sh — install.sh _resolve_target precedence + tilde expansion (parity with install-target.sh)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# Source install.sh to load helper functions without running main
source "$ROOT/install.sh"

resolve() {
  local home_val="$1" canon_home_val="$2" arg_val="$3"
  HOME="$home_val" CANON_HOME="$canon_home_val" _resolve_target "$arg_val"
}

# default → <home>/.canon
assert_eq "/home/u/.canon" "$(resolve /home/u '' '')"

# CANON_HOME respected when no arg
assert_eq "/opt/canon" "$(resolve /home/u /opt/canon '')"

# positional arg overrides CANON_HOME
assert_eq "/tmp/c" "$(resolve /home/u /opt/canon /tmp/c)"

# leading ~/ in CANON_HOME expands to home
assert_eq "/home/u/foo" "$(resolve /home/u '~/foo' '')"

# leading ~/ in positional arg expands to home
assert_eq "/home/u/bar" "$(resolve /home/u '' '~/bar')"

# relative arg resolves to absolute (against cwd)
assert_eq "$PWD/rel" "$(resolve /home/u '' rel)"

# ── t-0d25, t-50f7: the main track is a depth-1 clone at <home>/packages/main (current points at it), and the already-installed branch keeps
# updating it. Release installs (a verified zip unpacked into packages/<vX.Y.Z>) are tests/canon-packages.sh's: they need a stub release.
# (Before t-50f7 the clone sat at <home> itself and a release install was that clone checked out at the tag; the assertions below were moved
# from <home> to packages/main, and the release ones to canon-packages.sh, for that reason.) Prod path: install.sh and bin/install.js.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CANON_REPO CANON_REF   # an ambient CANON_REPO would redirect the clones below
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
up="$W/up"; mkdir -p "$up/tools" "$W/home" "$W/tmp" "$W/xdg" "$W/cache" "$W/state" "$W/canonhome"
git init -q -b main "$up"
printf '#!/bin/sh\nexit 0\n' > "$up/tools/skills.sh"; printf '#!/bin/sh\necho "fetch-daemon-ran$*"\n[ -z "${DAEMON_FAIL-}" ]\n' > "$up/tools/fetch-daemon.sh"
# t-65c9: install.sh runs the bootstrap clone's own `canon update`, so the upstream carries the real script and what it sources
cp "$ROOT/tools/canon" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$ROOT/tools/ticket-root.sh" "$ROOT/tools/release-manifest.sh" \
  "$ROOT/tools/pkg-lib.sh" "$ROOT/tools/cockpit-stop-lib.sh" "$up/tools/"
for i in 1 2 3; do echo "$i" > "$up/f"; git -C "$up" add -A; git -C "$up" -c user.email=t@e -c user.name=t commit -qm "c$i"; done
mf="$W/releases.txt"
# every run pins HOME, TMPDIR, XDG_*, CANON_HOME and the Cockpit's state dir and port, so nothing reads or writes the real ones
env_i() { env -u XDG_RUNTIME_DIR HOME="$W/home" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/xdg" XDG_CACHE_HOME="$W/cache" CANON_HOME="$W/canonhome" \
  COCKPIT_STATE_DIR="$W/state" CANON_COCKPIT_PORT=1 CANON_REPO="file://$up" CANON_MANIFEST_URL="file://$mf" "$@"; }
notices() { { grep -cF "You're on the development version (main):" <<<"$1" || true; } | tr -d ' '; }   # t-bb84: how often an install printed the notice
M="$W/home/.canon/packages/main"
out="$(env_i CANON_REF=main bash "$ROOT/install.sh" "$W/home/.canon" 2>&1)" || fail "install.sh against a local remote failed: $out"
assert_eq "packages/main" "$(readlink "$W/home/.canon/current")"
assert_eq true "$(git -C "$M" rev-parse --is-shallow-repository)"
assert_eq 1 "$(git -C "$M" rev-list --count HEAD)"
assert_eq 1 "$(notices "$out")"; assert_contains "$out" "Installed the development version (main)."   # t-bb84: a fresh main install shows the notice once
assert_contains "$out" "You're on the development version (main): the newest changes, before they're released and without a release's verification."$'\n'"For the latest release instead, run: canon update --to latest"
assert_eq "main" "$(tr -d '[:space:]' < "$W/home/.canon/.canon-track")"   # the marker is data: in the home, not in the package
[[ -z "$(find "$W/home/.canon/packages" -maxdepth 1 -name '.boot.*')" ]] || fail "install-sh: the bootstrap clone was left behind"
echo 4 > "$up/f"; git -C "$up" add -A; git -C "$up" -c user.email=t@e -c user.name=t commit -qm c4
out="$(env_i bash "$ROOT/install.sh" "$W/home/.canon" 2>&1)" || fail "install.sh over an existing install failed: $out"   # a plain re-run keeps following main
assert_eq true "$(git -C "$M" rev-parse --is-shallow-repository)"
assert_eq 2 "$(git -C "$M" rev-list --count HEAD)"
assert_eq 4 "$(cat "$W/home/.canon/current/f")"
assert_eq 1 "$(notices "$out")"; assert_contains "$out" "Installed the development version (main)."

# the command each installer runs, and the default remote: a stub git records its arguments and refuses; nothing is left behind
mkdir -p "$W/stubs"; printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$W/git.log" > "$W/stubs/git"; chmod +x "$W/stubs/git"
: > "$W/git.log"; env_i CANON_REPO= PATH="$W/stubs:$PATH" bash "$ROOT/install.sh" "$W/fresh-sh" >/dev/null 2>&1 && fail "a refused clone must fail the installer" || true
assert_contains "$(cat "$W/git.log")" "clone --depth 1 -- https://github.com/sunitghub/canon-skills.git $W/fresh-sh/packages/.boot."; [[ ! -e "$W/fresh-sh" ]] || fail "install-sh: a refused clone left $W/fresh-sh"
: > "$W/git.log"; env_i CANON_REPO= PATH="$W/stubs:$PATH" node "$ROOT/bin/install.js" "$W/fresh-js" >/dev/null 2>&1 && fail "a refused clone must fail install.js" || true
assert_contains "$(cat "$W/git.log")" "clone --depth 1 -- https://github.com/sunitghub/canon-skills.git $W/fresh-js/packages/.boot."; [[ ! -e "$W/fresh-js" ]] || fail "install-js: a refused clone left $W/fresh-js"

printf 'install-sh: ok\n'

# ── t-65c9: a release that cannot be verified installs nothing: no folder is left behind, and the way to the development version is named
rm -f "$mf"
set +e; out="$(env_i bash "$ROOT/install.sh" "$W/norel" 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; [[ ! -e "$W/norel" ]] || fail "install-sh: a failed verification left $W/norel behind"; assert_contains "$out" "nothing was installed"; assert_contains "$out" "CANON_REF=main"
# a failed verification into a folder that already existed (empty, or the current folder) empties it and keeps the folder, and says so; nothing unverified is left
mkdir "$W/emptyA" "$W/emptyB"
set +e; out="$(env_i bash "$ROOT/install.sh" "$W/emptyA" 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; [[ -d "$W/emptyA" && -z "$(ls -A "$W/emptyA")" ]] || fail "install-sh: a failed install into an existing empty folder left something in it: $(ls -A "$W/emptyA")"; assert_contains "$out" "nothing was installed"
set +e; out="$(cd "$W/emptyB" && env_i bash "$ROOT/install.sh" . 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; [[ -z "$(ls -A "$W/emptyB")" ]] || fail "install-sh: a failed install into '.' left something behind: $(ls -A "$W/emptyB")"; assert_contains "$out" "nothing was installed"
# ── t-2ea4: bin/install.js (the npx installer) takes the same steps: main opt-in, nothing left on failure, update over an install
out="$(env_i CANON_REF=main node "$ROOT/bin/install.js" "$W/jsmain" 2>&1)" || fail "install.js CANON_REF=main failed: $out"
assert_eq "$(git -C "$up" rev-parse HEAD)" "$(git -C "$W/jsmain/packages/main" rev-parse HEAD)"; assert_eq "main" "$(tr -d '[:space:]' < "$W/jsmain/.canon-track")"
assert_contains "$out" "fetch-daemon-ran"   # canon update fetched the clone's binaries
out="$(env_i node "$ROOT/bin/install.js" "$W/jsmain" 2>&1)" || fail "install.js over a main install failed: $out"
assert_contains "$out" "canon is up to date"; [[ "$out" != *"Installing canon"* ]] || fail "install-js: re-run installed over the install: $out"
mkdir "$W/jsempty"
set +e; out="$(env_i node "$ROOT/bin/install.js" "$W/jsnorel" 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; [[ ! -e "$W/jsnorel" ]] || fail "install-js: a failed verification left $W/jsnorel behind"; assert_contains "$out" "nothing was installed"; assert_contains "$out" "CANON_REF=main"
set +e; out="$(env_i node "$ROOT/bin/install.js" "$W/jsempty" 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; [[ -d "$W/jsempty" && -z "$(ls -A "$W/jsempty")" ]] || fail "install-js: a failed install into an existing empty folder left something in it: $(ls -A "$W/jsempty")"
echo "install-sh: ok (target resolution; the main track is a depth-1 clone in packages/main that updates in place; a failed verification installs nothing and leaves an existing folder empty; install.js takes the same steps)"
