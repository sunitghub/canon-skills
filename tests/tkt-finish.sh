#!/usr/bin/env bash
# t-e1a2: tkt merge targets the project's default branch by ref when the main checkout is on another branch, and tkt finish pushes it
# and resets the worktree. Prod path: the card's Check & merge (merge-check and POST merge) and the Finish step's two routes.
# Every refusal changes nothing.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-finish.XXXXXX")"
use_fresh_board "$W/board"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" TMPDIR="$W/tmp" STUB_W="$W"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com

# origin is a bare repository; the project is a clone of it, so origin/HEAD points at main.
git init -q --bare "$W/origin.git"
SEED="$W/seed"; git init -q "$SEED"; cd "$SEED"
mkdir -p scripts; printf '#!/usr/bin/env bash\ntouch "$STUB_W/ran"\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
printf '.tickets/\n' > .gitignore; echo base > base.txt; git add -A; git commit -qm base
git remote add origin "$W/origin.git"; git push -q origin main
P="$W/project"; git clone -q "$W/origin.git" "$P"; cd "$P"
git remote set-head origin main >/dev/null
WT="$W/wt"; git worktree add -q "$WT" -b track/one; WT="$(cd "$WT" && pwd -P)"
git -C "$WT" push -q -u origin track/one
git -C "$WT" switch -q -c feat/x
(cd "$WT" && echo change > change.txt && git add change.txt && git commit -qm "the branch")
BHEAD="$(git -C "$WT" rev-parse HEAD)"

id="$("$TKT" create "Worktree ticket" -t task)"; f=".tickets/$id/ticket.md"
printf '%s\n' "$WT" > ".tickets/$id/.cockpit-cwd"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$BHEAD" > ".tickets/$id/eval-report.md"
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id" >/dev/null

# The main checkout moves to another branch, with a local edit to a canon file (the t-zpmp case).
git switch -q -c chore/other
echo local-note >> .gitignore
CHECKOUT_SIG() { printf '%s|%s|%s' "$(git symbolic-ref --short HEAD)" "$(git rev-parse HEAD)" "$(git status --porcelain)"; }
before="$(CHECKOUT_SIG)"; MAIN0="$(git rev-parse main)"

# --check names the target and says it merges by ref.
rm -f "$W/ran"
out="$("$TKT" merge "$id" --check < /dev/null 2>&1)" || fail "merge --check failed: $out"
assert_contains "$out" "merge: into main"
assert_contains "$out" "merge: the main checkout is on chore/other; merging into main by ref, the checkout stays on chore/other"
[[ ! -e "$W/ran" ]] || fail "--check ran the branch's code"
echo "merge --check: names main and says by ref"

# A default branch checked out in another worktree is refused in --check, before any test, and nothing changes.
OW="$W/ow"; git worktree add -q "$OW" main
{
  rc=0; out="$("$TKT" merge "$id" --check < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "merge should refuse a default branch checked out in another worktree (rc $rc): $out"
  assert_contains "$out" "main is checked out in $(cd "$OW" && pwd -P)"
  [[ "$(git rev-parse main)" == "$MAIN0" && "$(CHECKOUT_SIG)" == "$before" ]] || fail "something changed although merge refused"
  git worktree remove --force "$OW"
  echo "merge: refused a default branch checked out in another worktree"
}

# The merge: main moves by ref (first parent the old tip), the checkout stays on its branch with its edit, nothing is stashed.
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "merge --yes by ref failed: $out"
assert_contains "$out" "Merged feat/x into main ("
NEW="$(git rev-parse main)"
assert_eq "$MAIN0" "$(git rev-parse main^1)"
assert_eq "$BHEAD" "$(git rev-parse main^2)"
assert_eq "$before" "$(CHECKOUT_SIG)"
assert_eq "" "$(git stash list)"
assert_grep '^merged_into: main$' "$f"; assert_grep '^merged_branch: feat/x$' "$f"
echo "merge --yes: main moved by ref; the checkout, its branch and its local edit are untouched"

# finish --check lists the commits a push sends and says the reset waits for the push.
out="$("$TKT" finish "$id" --check < /dev/null 2>&1)" || fail "finish --check failed: $out"
assert_contains "$out" "git push origin main sends 2 commit(s)"
assert_contains "$out" "the branch"
assert_contains "$out" "reset after the push"
refuses() { local part="$1"; shift; local rc=0; out="$("$TKT" finish "$id" "$@" < /dev/null 2>&1)" || rc=$?; [[ "$rc" == 1 ]] || fail "finish $* should refuse (rc $rc): $out"; assert_contains "$out" "$part"; }
refuses "run it with --yes" --push
refuses "run it with --yes" --reset
refuses "not on origin yet; push it first" --reset --yes
[[ "$(git -C "$W/origin.git" rev-parse main)" == "$MAIN0" ]] || fail "origin moved although nothing was pushed"
echo "finish: --check lists the commits; push and reset need --yes; reset waits for the push"

# --push sends only main.
git branch other-local "$BHEAD"
out="$("$TKT" finish "$id" --push --yes < /dev/null 2>&1)" || fail "finish --push --yes failed: $out"
assert_contains "$out" "pushed main to origin"
assert_eq "$NEW" "$(git -C "$W/origin.git" rev-parse main)"
git -C "$W/origin.git" rev-parse -q --verify refs/heads/other-local >/dev/null && fail "the push sent a branch other than main"
out="$("$TKT" finish "$id" --check < /dev/null 2>&1)"; assert_contains "$out" "main is already on origin"
echo "finish --push: pushed main only"

# --reset runs in the worktree and puts it back on its tracking branch.
out="$("$TKT" finish "$id" --reset --yes < /dev/null 2>&1)" || fail "finish --reset --yes failed: $out"
assert_eq "feat/x" "$(git -C "$WT" symbolic-ref --short HEAD)"
assert_eq "$NEW" "$(git -C "$WT" rev-parse HEAD)"
out="$("$TKT" finish "$id" --reset --yes < /dev/null 2>&1)"; assert_contains "$out" "nothing to reset"
out="$("$TKT" finish "$id" --check < /dev/null 2>&1)"; assert_contains "$out" "at origin's main or has moved on to new work; nothing to reset"
# A long-lived worktree branch keeps its name for the next ticket: once it has commits main does not, the old ticket's reset is
# not offered again (its Finish card would come back).
(cd "$WT" && echo next > next.txt && git add next.txt && git commit -qm "the next ticket's work")
out="$("$TKT" finish "$id" --check < /dev/null 2>&1)"; assert_contains "$out" "has moved on to new work; nothing to reset"
out="$("$TKT" finish "$id" --reset --yes < /dev/null 2>&1)"; assert_contains "$out" "nothing to reset"
[[ "$(git -C "$WT" log -1 --format=%s)" == "the next ticket's work" ]] || fail "finish --reset touched a worktree that had moved on"
echo "finish --reset: the worktree branch is back at origin's main"

# A push origin refuses (it moved) is not forced.
id2="$("$TKT" create "Second" -t task)"; f2=".tickets/$id2/ticket.md"
git switch -q main 2>/dev/null || true
git switch -q chore/other
WT2="$W/wt2"; git worktree add -q "$WT2" -b feat/y main; WT2="$(cd "$WT2" && pwd -P)"
(cd "$WT2" && echo y > y.txt && git add y.txt && git commit -qm "second")
printf '%s\n' "$WT2" > ".tickets/$id2/.cockpit-cwd"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$(git -C "$WT2" rev-parse HEAD)" > ".tickets/$id2/eval-report.md"
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id2" >/dev/null
"$TKT" merge "$id2" --yes < /dev/null >/dev/null 2>&1 || fail "second merge failed"
git clone -q "$W/origin.git" "$W/other" && (cd "$W/other" && echo z > z.txt && git add z.txt && git commit -qm "someone else" && git push -q origin main)
OLD_ORIGIN="$(git -C "$W/origin.git" rev-parse main)"
# An origin ref never fetched is said, not shown as "0 commits".
git update-ref -d refs/remotes/origin/main
out="$("$TKT" finish "$id2" --check < /dev/null 2>&1)"; assert_contains "$out" "origin has no main as last fetched"
git fetch -q origin
rc=0; out="$("$TKT" finish "$id2" --push --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a refused push should fail (rc $rc): $out"
assert_contains "$out" "was refused or failed (not forced)"
assert_eq "$OLD_ORIGIN" "$(git -C "$W/origin.git" rev-parse main)"
echo "finish --push: a push origin refuses is reported, not forced"

# A default branch that does not exist here is refused with the way out, and nothing changes.
id4="$("$TKT" create "No local main" -t task)"
WT4="$W/wt4"; git worktree add -q "$WT4" -b feat/z main; WT4="$(cd "$WT4" && pwd -P)"
(cd "$WT4" && echo z4 > z4.txt && git add z4.txt && git commit -qm "fourth")
printf '%s\n' "$WT4" > ".tickets/$id4/.cockpit-cwd"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$(git -C "$WT4" rev-parse HEAD)" > ".tickets/$id4/eval-report.md"
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id4" >/dev/null
git branch -m main main-gone
rc=0; out="$("$TKT" merge "$id4" --check < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a missing default branch should be refused (rc $rc): $out"
assert_contains "$out" "origin's default branch main does not exist here"
git branch -m main-gone main
echo "merge: refused a default branch that does not exist here"

# --dismiss sets finish_dismissed (no --yes, it touches only the ticket's own field) and is refused with --yes.
rc=0; out="$("$TKT" finish "$id" --dismiss --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "--dismiss --yes should be refused (rc $rc): $out"
out="$("$TKT" finish "$id" --dismiss < /dev/null 2>&1)" || fail "finish --dismiss failed: $out"
assert_contains "$out" "dismissed"
assert_grep '^finish_dismissed: ' "$f"
echo "finish --dismiss: the ticket records it"

# A ticket tkt merge did not merge has nothing to finish.
id3="$("$TKT" create "Plain" -t task)"
rc=0; out="$("$TKT" finish "$id3" --check < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "finish on an unmerged ticket should fail"; assert_contains "$out" "nothing to finish"

echo "tkt-finish: ok"
