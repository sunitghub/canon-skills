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
export CANON_GATE_SCOPE_DIR="$scratch/registry"   # this test never registers a scope the rest of the suite could see
cd "$proj"; git config user.email t@example.com; git config user.name test
echo a > a.txt; git add -A >/dev/null; git commit -qm base
snap="$scratch/snap"
realhome="$scratch/realhome"; mkdir -p "$realhome/.canon"   # stands in for the user's real home and canon home
reg="$CANON_GATE_SCOPE_DIR"
CANON="$ROOT/tools/canon"
real_env() { HOME="$realhome" CANON_HOME="$realhome/.canon" "$@"; }   # the dispatcher runs in the user's real environment (t-9fb1: pre records it)
guard() { bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" >/dev/null 2>&1; }

# no scope registered: nothing is refused
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" bash -c 'source "$1"; gate_scope_guard "canon update"' _ "$ROOT/tools/gate-scope-lib.sh" 2>&1)" || fail "guard must pass with no gate scope"

real_env "$TOOL" pre "$snap" > "$scratch/pre.out"
scope="$(sed -n 's/^CANON_HOME=\(.*\)\/canon$/\1/p' "$snap.scope")"
[[ -n "$scope" && -d "$scope/home" && -d "$scope/canon" ]] || fail "pre must create and report a scratch scope: $(cat "$scratch/pre.out")"
assert_contains "$(cat "$snap.scope")" "TMPDIR=$scope/tmp"   # what a pi gate is launched with (env $(cat snap.scope) pi -p …)

# the real-path canon update is rejected, and says why and when it clears (a concurrent run of the user's own gets this message)
out="$(HOME="$realhome" CANON_HOME="$realhome/.canon" run_fail "$CANON" update)"
assert_contains "$out" "refused"; assert_contains "$out" "clears when the gate ends"
assert_contains "$out" "REAL home and canon home"; assert_contains "$out" "a scratch HOME and CANON_HOME"   # t-9fb1: the message says what is blocked and what is fine
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

# t-9fb1: only the REAL home and canon home are refused; any other HOME/CANON_HOME (a test's scratch dirs, as every canon suite pins) goes through while
# another project's gate is live: the stamps that failed on canon-site's gate
sh_="$scratch/sh"; mkdir -p "$sh_/home/.canon" "$sh_/canon"
HOME="$sh_/home" CANON_HOME="$sh_/canon" guard || fail "a scratch HOME and CANON_HOME must pass while a gate is live"
HOME="$sh_/home" env -u CANON_HOME bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" >/dev/null 2>&1 || fail "a scratch HOME with CANON_HOME unset (-> HOME/.canon) must pass"
HOME="$sh_/home" CANON_HOME="$realhome/.canon" guard && fail "the real CANON_HOME with a scratch HOME must be refused"
HOME="$realhome" CANON_HOME="$sh_/canon" guard && fail "the real HOME with a scratch CANON_HOME must be refused"
ln -s "$realhome" "$scratch/linkhome"
HOME="$scratch/linkhome" CANON_HOME="$scratch/linkhome/.canon" guard && fail "a symlink to the real home is the real home"
HOME="$realhome/" CANON_HOME="$realhome/.canon/" guard && fail "a trailing slash must not hide the real home"
HOME="$scratch/realhome/../realhome" CANON_HOME="$scratch/realhome/../realhome/.canon" guard && fail "a .. spelling must not hide the real home"
(cd "$realhome" && HOME=. CANON_HOME=./.canon guard) && fail "a relative HOME that is the real home must be refused"
HOME="" CANON_HOME="" guard && fail "an empty HOME must be refused (fail closed)"
# a spelling that differs only in case reaches the same folder on a case-insensitive disk (macOS): identity, not text, decides
up="$(printf '%s' "$realhome" | tr 'a-z' 'A-Z')"
if [[ "$up" != "$realhome" && -d "$up" ]]; then HOME="$up" CANON_HOME="$up/.canon" guard && fail "a case spelling of the real home is the real home"; fi
# a path that does not exist yet but resolves to the real home as text is refused: a later mkdir -p would make the folder and the same spelling is the real home
HOME="$realhome/no-such-dir/.." CANON_HOME="$sh_/canon" guard && fail "a nonexistent .. spelling of the real home must be refused"
HOME="$sh_/home" CANON_HOME="$realhome/.canon/no-such-dir/.." guard && fail "a nonexistent .. spelling of the real canon home must be refused"
HOME="$realhome//./x/.." CANON_HOME="$sh_/canon" guard && fail "//, . and .. spellings of the real home must be refused"
(cd "$realhome" && HOME="no-such-dir/.." CANON_HOME="$sh_/canon" guard) && fail "a relative nonexistent .. spelling of the real home must be refused"
HOME="$realhome/a/b/c/../../.." CANON_HOME="$sh_/canon" guard && fail "several nonexistent components then .. back to the real home must be refused"
HOME="$sh_/home" CANON_HOME="$realhome/.canon/a/b/../.." guard && fail "several nonexistent components then .. back to the real canon home must be refused"
# a symlink into a folder INSIDE the real home, then a missing folder, then ..: the kernel follows the link before it pops .., so this is the real home
mkdir -p "$realhome/sub" "$realhome/.canon/sub"; ln -s "$realhome/sub" "$scratch/link2"; ln -s "$realhome/.canon/sub" "$scratch/link3"
HOME="$scratch/link2/nx/../.." CANON_HOME="$sh_/canon" guard && fail "a symlinked prefix, a missing folder and .. that lead to the real home must be refused"
HOME="$sh_/home" CANON_HOME="$scratch/link3/nx/../.." guard && fail "the same through a symlink into the real canon home must be refused"
HOME="$scratch/link2/.." CANON_HOME="$sh_/canon" guard && fail "a symlink into the real home then .. (no missing folder) is the real home and must be refused"
HOME="$scratch/link2/../.." CANON_HOME="$sh_/canon" guard || fail "the folder that holds the real home is not the real home and must pass"
HOME="$scratch/link2" CANON_HOME="$sh_/canon" guard || fail "a symlink to a folder inside the real home is not the real home and must pass"
# a scratch path that does not exist yet and does not lead to the real home is fine
HOME="$sh_/deep/a/b/c" CANON_HOME="$sh_/deep/a/b/c/.canon" guard || fail "a deep nonexistent scratch path must pass"
HOME="$realhome/a/b/c" CANON_HOME="$realhome/a/b/c/.canon" guard || fail "a (nonexistent) folder INSIDE the real home is not the real home and must pass"
HOME="/" CANON_HOME="/no-such-canon-root" guard || fail "the filesystem root is not the real home"
HOME="$sh_/not-made-yet" CANON_HOME="$sh_/not-made-yet/.canon" guard || fail "a nonexistent scratch HOME elsewhere must pass"
out="$(HOME="$sh_/home" CANON_HOME="$sh_/canon" "$ROOT/tools/skills.sh" remove no-such-skill 2>&1 || true)"
[[ "$out" != *"close gate"* ]] || fail "skills.sh with a scratch HOME was refused by the gate scope: $out"
# a record from an older version (no home=/canon= lines) keeps the old rule: refuse unless both are inside the scope
f="$(ls "$reg"/*)"; cp "$f" "$scratch/rec.keep"; sed -i.bak '/^home=/d;/^canon=/d' "$f"; rm -f "$f.bak"
HOME="$sh_/home" CANON_HOME="$sh_/canon" guard && fail "an old-format record must keep the old rule (scratch outside the scope is refused)"
HOME="$scope/home" CANON_HOME="$scope/canon" guard || fail "an old-format record must let the gate's own scope through"
# the old rule needs BOTH inside the scope: one inside and one outside is refused
HOME="$scope/home" CANON_HOME="$sh_/canon" guard && fail "old rule: HOME in the scope but CANON_HOME outside must be refused"
HOME="$sh_/home" CANON_HOME="$scope/canon" guard && fail "old rule: CANON_HOME in the scope but HOME outside must be refused"
# a record naming only one of home= / canon= is not a new-format record: the old rule applies too
cp "$scratch/rec.keep" "$f"; sed -i.bak '/^canon=/d' "$f"; rm -f "$f.bak"
HOME="$sh_/home" CANON_HOME="$sh_/canon" guard && fail "a record with only home= must keep the old rule"
cp "$scratch/rec.keep" "$f"; sed -i.bak '/^home=/d' "$f"; rm -f "$f.bak"
HOME="$sh_/home" CANON_HOME="$sh_/canon" guard && fail "a record with only canon= must keep the old rule"
cp "$scratch/rec.keep" "$f"
grep -q "^home=$(cd -P "$realhome" && pwd -P)\$" "$f" && grep -q "^canon=$(cd -P "$realhome/.canon" && pwd -P)\$" "$f" || fail "pre did not record the real home and canon home: $(cat "$f")"

# the pi launch environment (scope CANON_HOME + TMPDIR, real HOME) and a bare TMPDIR change are still refused (reviewer t-b7df: the registry must not hide behind TMPDIR)
(env $(cat "$snap.scope") HOME="$realhome" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null) && fail "pi env with a real HOME must be refused"
(HOME="$realhome" CANON_HOME="$realhome/.canon" TMPDIR="$scratch/other" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null) && fail "a changed TMPDIR must not hide the scope"

# post ends the scope
"$TOOL" post "$snap" >/dev/null
[[ ! -d "$scope" && ! -e "$snap.scope" ]] || fail "post must delete the scratch scope"
HOME="$realhome" CANON_HOME="$realhome/.canon" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" || fail "after post the real path must pass"

# a gate that crashed before post: the scope goes stale by age, and by its scratch dir being gone
g() { HOME="$realhome" CANON_HOME="$realhome/.canon" "$@" bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null; }
real_env "$TOOL" pre "$snap" >/dev/null
real_env env CANON_GATE_SCOPE_TTL=3600 bash -c 'source "$1"; gate_scope_guard x' _ "$ROOT/tools/gate-scope-lib.sh" 2>/dev/null && fail "a fresh scope must still block"
f="$(ls "$reg"/*)"; sed -i.bak "s/^created=.*/created=$(( $(date +%s) - 7300 ))/" "$f"; rm -f "$f.bak"
g env || fail "a scope older than the TTL (default 2h) must be stale, not block forever"
[[ ! -e "$f" ]] || fail "a stale record must be cleaned up"
real_env "$TOOL" pre "$snap" >/dev/null; f="$(ls "$reg"/*)"; rm -rf "$(sed -n 's/^dir=//p' "$f")"
g env || fail "a scope whose scratch dir is gone must be stale"

echo "gate-scope: ok (pre makes a scope, real-path canon update/skills/uninstall refused with reason and clear-time, pinned and read-only pass, post ends it, stale by age and by missing dir)"
