#!/usr/bin/env bash
# gate-scope (t-b7df): a close gate's scratch scope is made by gate-snapshot.sh pre, and while it is live the commands that act on
# registered projects (canon update, skills.sh add/refresh/..., canon uninstall) refuse a real HOME/CANON_HOME. Live trigger: a reviewer's
# `canon update` once re-linked the user's registered projects (2026-10-09). Also protects: a crashed gate (no post) must not block the
# user's own update forever (staleness), and `post` must end the scope.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

TOOL="$ROOT/tools/gate-snapshot.sh"
proj="$(make_project)"; scratch="$(mktemp -d)"
trap 'rm -rf "$proj" "$scratch"' EXIT
export TMPDIR="$scratch"   # the scope registry lives under TMPDIR: this test never registers a scope the rest of the suite could see
cd "$proj"; git config user.email t@example.com; git config user.name test
echo a > a.txt; git add -A >/dev/null; git commit -qm base
snap="$scratch/snap"
realhome="$scratch/realhome"; mkdir -p "$realhome/.canon"   # stands in for the user's real home and canon home
reg="$scratch/canon-gate-scope-$(id -u)"
CANON="$ROOT/tools/canon"

# no scope registered: nothing is refused
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" bash -c 'source "$1"; gate_scope_guard "canon update"' _ "$ROOT/tools/gate-scope-lib.sh" 2>&1)" || fail "guard must pass with no gate scope"

"$TOOL" pre "$snap" > "$scratch/pre.out"
scope="$(sed -n 's/^CANON_HOME=\(.*\)\/canon$/\1/p' "$snap.scope")"
[[ -n "$scope" && -d "$scope/home" && -d "$scope/canon" ]] || fail "pre must create and report a scratch scope: $(cat "$scratch/pre.out")"
assert_contains "$(cat "$snap.scope")" "TMPDIR=$scope/tmp"   # what a pi gate is launched with (env $(cat snap.scope) pi -p …)

# the real-path canon update is rejected, and says why and when it clears (a concurrent run of the user's own gets this message)
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" run_fail "$CANON" update)"
assert_contains "$out" "refused"; assert_contains "$out" "clears when the gate ends"
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" run_fail "$ROOT/tools/skills.sh" refresh)"
assert_contains "$out" "refused"
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" run_fail "$ROOT/tools/canon-uninstall.sh" --yes)"
assert_contains "$out" "refused"
# a half-pinned gate (CANON_HOME in the scope, HOME real) is still refused; fully pinned goes through
HOME="$realhome" CANON_HOME="$scope/canon" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null && fail "HOME outside the scope must be refused"
HOME="$scope/home" CANON_HOME="$scope/canon" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" || fail "a pinned run must pass"
# read-only commands are untouched
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" "$ROOT/tools/skills.sh" list 2>&1 || true)"
[[ "$out" != *refused* ]] || fail "skills.sh list must not be guarded: $out"

# post ends the scope
"$TOOL" post "$snap" >/dev/null
[[ ! -d "$scope" && ! -e "$snap.scope" ]] || fail "post must delete the scratch scope"
HOME="$realhome" CANON_HOME="$realhome/.canon" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" || fail "after post the real path must pass"

# a gate that crashed before post: the scope goes stale by age, and by its scratch dir being gone
g() { HOME="$realhome" CANON_HOME="$realhome/.canon" "$@" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null; }
"$TOOL" pre "$snap" >/dev/null
env CANON_GATE_SCOPE_TTL=3600 bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null && fail "a fresh scope must still block"
f="$(ls "$reg"/*)"; sed -i.bak "s/^created=.*/created=$(( $(date +%s) - 7300 ))/" "$f"; rm -f "$f.bak"
g env || fail "a scope older than the TTL (default 2h) must be stale, not block forever"
[[ ! -e "$f" ]] || fail "a stale record must be cleaned up"
"$TOOL" pre "$snap" >/dev/null; f="$(ls "$reg"/*)"; rm -rf "$(sed -n 's/^dir=//p' "$f")"
g env || fail "a scope whose scratch dir is gone must be stale"

echo "gate-scope: ok (pre makes a scope, real-path canon update/skills/uninstall refused with reason and clear-time, pinned and read-only pass, post ends it, stale by age and by missing dir)"
