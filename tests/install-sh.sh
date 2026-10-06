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
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
up="$W/up"; mkdir -p "$up/tools" "$W/home"
git init -q -b main "$up"
printf '#!/bin/sh\nexit 0\n' > "$up/tools/skills.sh"; cp "$up/tools/skills.sh" "$up/tools/fetch-daemon.sh"
for i in 1 2 3; do echo "$i" > "$up/f"; git -C "$up" add -A; git -C "$up" -c user.email=t@e -c user.name=t commit -qm "c$i"; done
HOME="$W/home" CANON_REPO="file://$up" bash "$ROOT/install.sh" "$W/home/.canon" >/dev/null 2>&1 || fail "install.sh against a local remote failed"
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
assert_contains "$(cat "$W/git.log")" "clone --depth 1 https://github.com/sunitghub/canon-skills.git $W/fresh-sh"
: > "$W/git.log"; PATH="$W/stubs:$PATH" HOME="$W/home" node "$ROOT/bin/install.js" "$W/fresh-js" >/dev/null 2>&1 && fail "a refused clone must fail install.js" || true
assert_contains "$(cat "$W/git.log")" "clone --depth 1 https://github.com/sunitghub/canon-skills.git $W/fresh-js"

printf 'install-sh: ok\n'
