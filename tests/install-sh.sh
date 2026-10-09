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

# ── t-0d25: a fresh install is a depth-1 clone, and the already-installed branch keeps updating it ───────────────────────────────────────────
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CANON_REPO   # an ambient CANON_REPO would redirect the clones below
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
up="$W/up"; mkdir -p "$up/tools" "$W/home"
git init -q -b main "$up"
printf '#!/bin/sh\nexit 0\n' > "$up/tools/skills.sh"; cp "$up/tools/skills.sh" "$up/tools/fetch-daemon.sh"
# t-65c9: install.sh now runs the install's own `canon update`, so the upstream carries the real script and what it sources
cp "$ROOT/tools/canon" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$ROOT/tools/release-manifest.sh" "$up/tools/"; printf '/.canon-track\n' > "$up/.gitignore"
for i in 1 2 3; do echo "$i" > "$up/f"; git -C "$up" add -A; git -C "$up" -c user.email=t@e -c user.name=t commit -qm "c$i"; done
HOME="$W/home" CANON_REPO="file://$up" CANON_REF=main bash "$ROOT/install.sh" "$W/home/.canon" >/dev/null 2>&1 || fail "install.sh against a local remote failed"
assert_eq true "$(git -C "$W/home/.canon" rev-parse --is-shallow-repository)"
assert_eq 1 "$(git -C "$W/home/.canon" rev-list --count HEAD)"
echo 4 > "$up/f"; git -C "$up" add -A; git -C "$up" -c user.email=t@e -c user.name=t commit -qm c4
HOME="$W/home" CANON_REPO="file://$up" bash "$ROOT/install.sh" "$W/home/.canon" >/dev/null 2>&1 || fail "install.sh over an existing install failed"
assert_eq true "$(git -C "$W/home/.canon" rev-parse --is-shallow-repository)"
assert_eq 2 "$(git -C "$W/home/.canon" rev-list --count HEAD)"
assert_eq 4 "$(cat "$W/home/.canon/f")"

# the command each installer runs, and the default remote: a stub git records its arguments and refuses
mkdir -p "$W/stubs"; printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$W/git.log" > "$W/stubs/git"; chmod +x "$W/stubs/git"
: > "$W/git.log"; PATH="$W/stubs:$PATH" HOME="$W/home" bash "$ROOT/install.sh" "$W/fresh-sh" >/dev/null 2>&1 && fail "a refused clone must fail the installer" || true
assert_contains "$(cat "$W/git.log")" "clone --depth 1 -- https://github.com/sunitghub/canon-skills.git $W/fresh-sh"
: > "$W/git.log"; PATH="$W/stubs:$PATH" HOME="$W/home" node "$ROOT/bin/install.js" "$W/fresh-js" >/dev/null 2>&1 && fail "a refused clone must fail install.js" || true
assert_contains "$(cat "$W/git.log")" "clone --depth 1 -- https://github.com/sunitghub/canon-skills.git $W/fresh-js"

printf 'install-sh: ok\n'

# ── t-65c9: a new install is the latest VERIFIED release, not main. The upstream gets tags and a manifest (a file: CANON_MANIFEST_URL only moves the read).
Z="$(printf 'e%.0s' $(seq 1 64))"; ig=(-c user.email=t@e -c user.name=t)
git -C "$up" "${ig[@]}" tag -a v0.3.0 -m v0.3.0; echo 5 > "$up/f"; git -C "$up" add -A; git -C "$up" "${ig[@]}" commit -qm "after the release"
tip="$(git -C "$up" rev-parse HEAD)"; rel="$(git -C "$up" rev-list -n1 v0.3.0)"
mf="$W/releases.txt"; printf '# canon releases\nv0.3.0 %s %s\n' "$Z" "$rel" > "$mf"
env_i() { env HOME="$W/home" CANON_REPO="file://$up" CANON_MANIFEST_URL="file://$mf" "$@"; }
out="$(env_i bash "$ROOT/install.sh" "$W/rel" 2>&1)" || fail "install.sh could not install the verified release: $out"
assert_eq "$rel" "$(git -C "$W/rel" rev-parse HEAD)"; [[ -z "$(git -C "$W/rel" symbolic-ref -q HEAD || true)" ]] || fail "install-sh: the release install is on a branch"
assert_contains "$out" "canon is now on v0.3.0"; assert_contains "$out" "Installed the verified release v0.3.0"; [[ "$out" != *"not checksum-verified"* ]] || fail "install-sh: the release install printed the unverified note: $out"
[[ ! -e "$W/rel/.canon-track" ]] || fail "install-sh: the release install wrote a track marker"
# an existing release install updates through `canon update` (no marker: the latest release again), and says so when it is already there
out="$(env_i bash "$ROOT/install.sh" "$W/rel" 2>&1)" || fail "install.sh over a release install failed: $out"; assert_contains "$out" "canon is up to date (v0.3.0, verified"
# a manifest that cannot verify installs nothing: no folder is left behind, and the way to the development version is named
rm -f "$mf"
set +e; out="$(env_i bash "$ROOT/install.sh" "$W/norel" 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; [[ ! -e "$W/norel" ]] || fail "install-sh: a failed verification left $W/norel behind"; assert_contains "$out" "nothing was installed"; assert_contains "$out" "CANON_REF=main"
# the opt-in: CANON_REF=main installs main, remembers it, and says it is not verified
out="$(env_i CANON_REF=main bash "$ROOT/install.sh" "$W/devmain" 2>&1)" || fail "install.sh CANON_REF=main failed: $out"
assert_eq "$tip" "$(git -C "$W/devmain" rev-parse HEAD)"; assert_eq "main" "$(tr -d '[:space:]' < "$W/devmain/.canon-track")"; assert_contains "$out" "not checksum-verified"
echo "install-sh: ok (target resolution; depth-1 clone and update; a new install is the latest verified release, installs nothing when it cannot verify, CANON_REF=main opts in)"
