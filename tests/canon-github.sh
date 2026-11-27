#!/usr/bin/env bash
# canon-github (t-393e) — `canon github on|off|status` through the real board binary and the shipped canon command. Protects the
# shipped command: on from a linked worktree records the main checkout in $CANON_HOME/settings.json, status reports it and prints
# the token line (never a token), off removes it, a wrong word exits 2 with usage, and an older board refuses instead of serving.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
use_fresh_board "$W/bin"
mkdir -p "$W/userhome"
export CANON_HOME="$W/home" HOME="$W/userhome" GIT_CONFIG_NOSYSTEM=1   # HOME too: nothing may reach the real ~/.canon or ~/.gitconfig
CANON="$ROOT/tools/canon"
git init -q "$W/proj"
git -C "$W/proj" -c user.name=t -c user.email=t@e commit -q --allow-empty -m x
git -C "$W/proj" worktree add -q "$W/wt"

out="$(cd "$W/wt" && "$CANON" github status)"
assert_contains "$out" "restricted GitHub access: off"
out="$(cd "$W/wt" && "$CANON" github on)"
assert_contains "$out" "restricted GitHub access: on for $W/proj"
grep -F "\"$W/proj\"" "$CANON_HOME/settings.json" >/dev/null || fail "canon-github: settings.json does not list the main checkout"
grep -F "$W/wt" "$CANON_HOME/settings.json" >/dev/null && fail "canon-github: the worktree path was recorded"
out="$("$CANON" github status "$W/proj")"
assert_contains "$out" "restricted GitHub access: on"
assert_contains "$out" "token: "
assert_contains "$out" "security add-generic-password -U -s canon-github -a '$W/proj' -w"
out="$("$CANON" github off "$W/proj")"
assert_contains "$out" "restricted GitHub access: off for $W/proj"
grep -F "$W/proj" "$CANON_HOME/settings.json" >/dev/null && fail "canon-github: off left the project listed"

set +e; out="$("$CANON" github enable 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "usage: canon github on | off | status"

printf '#!/bin/sh\necho "usage: old board"\n' > "$W/old-board"; chmod +x "$W/old-board"
set +e; out="$(SPRINT_CHECK_BIN="$W/old-board" "$CANON" github status 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "older than this command"
echo "canon-github: ok"
