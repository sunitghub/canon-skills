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

# --fetch (the dialog's check): with origin's branch only as last fetched, a push done elsewhere is not seen; --fetch reads origin first.
refute() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }
git -C "$P" update-ref -d refs/remotes/origin/main
out="$("$TKT" finish "$id" --check < /dev/null 2>&1)"; assert_contains "$out" "origin has no main as last fetched"          # the stale copy: no news
out="$("$TKT" finish "$id" --check --fetch < /dev/null 2>&1)"; assert_contains "$out" "main is already on origin"            # origin read first: it has it
refute "$out" "could not reach origin"
git -C "$P" rev-parse -q --verify refs/remotes/origin/main >/dev/null || fail "--fetch did not read origin's main"
# ... and a push of what origin already has says so instead of claiming it pushed
git -C "$P" update-ref -d refs/remotes/origin/main
out="$("$TKT" finish "$id" --push --yes < /dev/null 2>&1)" || fail "finish --push of what origin has failed: $out"
assert_contains "$out" "origin already had main; nothing was sent"; refute "$out" "finish: pushed main to origin"
# offline: say so and show what was last fetched
git -C "$P" remote set-url origin "$W/nowhere.git"
out="$("$TKT" finish "$id" --check --fetch < /dev/null 2>&1)"; assert_contains "$out" "could not reach origin; showing what was last fetched"
git -C "$P" remote set-url origin "$W/origin.git"; git -C "$P" fetch -q origin
echo "finish --fetch: origin is read first; a push origin already had says so; offline is said"

# A push origin refuses (it moved) is not forced.
id2="$("$TKT" create "Second" -t task)"
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
# t-dde9: origin moved on meanwhile (someone else's commit). --check --fetch names it; Push merges origin's into main here, then pushes.
L2="$(git rev-parse main)"
out="$("$TKT" finish "$id2" --check --fetch < /dev/null 2>&1)" || fail "finish --check --fetch failed: $out"
assert_contains "$out" "finish: push: origin/main has 1 commit(s) main lacks: Push first merges origin/main into main here (a merge commit, never a rebase or force):"
assert_contains "$out" "someone else"
assert_eq "$L2" "$(git rev-parse main)"
# A push origin itself refuses (a hook there) is reported, never forced; the merge made here stays.
printf '#!/bin/sh\necho "origin says no" >&2\nexit 1\n' > "$W/origin.git/hooks/pre-receive"; chmod +x "$W/origin.git/hooks/pre-receive"
rc=0; out="$("$TKT" finish "$id2" --push --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a refused push should fail (rc $rc): $out"
assert_contains "$out" "Local main: merged origin/main"
assert_contains "$out" "was refused or failed (not forced)"
assert_eq "$OLD_ORIGIN" "$(git -C "$W/origin.git" rev-parse main)"
echo "finish --push: a push origin refuses is reported, not forced"
rm "$W/origin.git/hooks/pre-receive"
out="$("$TKT" finish "$id2" --push --yes < /dev/null 2>&1)" || fail "finish --push after origin moved failed: $out"
assert_contains "$out" "pushed main to origin"
assert_eq "$(git rev-parse main)" "$(git -C "$W/origin.git" rev-parse main)"
assert_eq "Merge origin/main into main" "$(git log -1 --format=%s main)"
assert_eq "$L2" "$(git rev-parse main^1)"; assert_eq "$OLD_ORIGIN" "$(git rev-parse main^2)"
echo "finish --push: origin's new commit is merged into main (a merge commit), then pushed"

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

# t-dde9: the Windows repro. A project that tracks .tickets/, HANDOFF.md and LEARNINGS.md; a worktree ticket merged here (its ticket was
# committed here first, never pushed) while a cloud PR merged on origin. Both sides' closes rewrote HANDOFF.md's Recent block, added a
# Scratch entry and a LEARNINGS.md row; the cloud ticket's folder is also here, untracked (import-results), with per-machine fields and
# github.md. Push merges origin's main in (canon's docs resolved), sets the local ticket copy aside, and pushes.
hand() { # hand <recent line> <focus> [scratch lines...]
  printf '# Handoff\n\n<!-- canon:recent:BEGIN -->\n## Recent activity\n- %s\n<!-- canon:recent:END -->\n\nA note of the team, between the block and the narrative.\n\n<!-- canon:handoff:BEGIN -->\n## Current Focus\n%s\n<!-- canon:handoff:END -->\n' "$1" "$2"
  [[ $# -le 2 ]] || { printf '\n## Scratch\n\n'; printf '%s\n' "${@:3}"; }
}
learn() { # learn <stamp> <rows...>
  local stamp="$1"; shift
  printf '# Learnings\n\nlearnings-sweep last run: %s\n\n<!-- canon:learnings:BEGIN -->\n| Date | Ticket | Finding | Status |\n|---|---|---|---|\n' "$stamp"
  printf '%s\n' "$@"; printf '<!-- canon:learnings:END -->\n'
}
row() { printf '| %s | [%s](.tickets/%s/learnings.md) | finding of %s | UNPROMOTED |' "$1" "$2" "$2" "$2"; }
SC_OLD='- 2026-11-12 09:00 — s-cccc: notes left in old — paused'   # in the base; this checkout deletes it, the cloud keeps it: it stays deleted
SC_OLD2='- 2026-11-12 09:30 — s-dddd: notes left in old2 — paused'   # in the base; the cloud deletes it, this checkout keeps it: it stays deleted
SC_KEEP='- 2026-11-12 08:00 — s-eeee: notes left in keep — paused'   # in all three: kept
SC_HERE='- 2026-11-13 10:00 — s-aaaa: notes left in wt — paused'; SC_CLOUD='- 2026-11-13 11:00 — s-bbbb: notes left in cloud — paused'
# markmerged <id>: what tkt merge records on the ticket (the fields tkt finish reads), uncommitted, as tkt merge leaves them.
markmerged() { awk -v m="$(git rev-parse main)" -v b="$2" '/^---$/ && ++n == 2 { print "merged: " m; print "merged_into: main"; print "merged_branch: " b } { print }' ".tickets/$1/ticket.md" > "$W/mm" && mv "$W/mm" ".tickets/$1/ticket.md"; }
O3="$W/origin3.git"; git init -q --bare "$O3"
S3="$W/seed3"; git init -q "$S3"; cd "$S3"
echo base > base.txt; hand "old" "base focus" "$SC_KEEP" "$SC_OLD" "$SC_OLD2" > HANDOFF.md; learn "11-01-2026 09:00" "$(row 2026-11-01 t-0001)" > LEARNINGS.md
git add -A; git commit -qm base; git remote add origin "$O3"; git push -q origin main
P3="$W/project3"; git clone -q "$O3" "$P3"; git -C "$P3" remote set-head origin main >/dev/null
C3="$W/cloud3"; git clone -q "$O3" "$C3"
cd "$P3"
id5="$("$TKT" create "Worktree" -t task)"; git add ".tickets/$id5/ticket.md"; git commit -qm "chore: add ticket $id5"   # never pushed: the divergence
git checkout -qb feat/w
echo w > w.txt; hand "worktree close" "base focus" "$SC_KEEP" "$SC_OLD2" "$SC_HERE" > HANDOFF.md; learn "11-13-2026 10:00" "$(row 2026-11-13 t-aaaa)" "$(row 2026-11-01 t-0001)" > LEARNINGS.md
git add -A; git commit -qm "the worktree ticket"; git checkout -q main; git merge -q --no-ff feat/w -m "Merge branch 'feat/w'"; markmerged "$id5" feat/w
(cd "$C3" && mkdir -p .tickets/t-c3j5 && printf -- '---\nid: t-c3j5\nstatus: closed\n---\n# Cloud\n' > .tickets/t-c3j5/ticket.md \
  && echo report > .tickets/t-c3j5/eval-report.md && echo c > c.txt && hand "cloud close" "base focus" "$SC_KEEP" "$SC_OLD" "$SC_CLOUD" > HANDOFF.md \
  && learn "11-13-2026 11:00" "$(row 2026-11-13 t-bbbb)" "$(row 2026-11-01 t-0001)" > LEARNINGS.md && git add -A && git commit -qm "Merge pull request #2" && git push -q origin main)
mkdir -p .tickets/t-c3j5; echo report > .tickets/t-c3j5/eval-report.md; echo "sent as #2" > .tickets/t-c3j5/github.md
printf -- '---\nid: t-c3j5\nstatus: closed\ngithub: 2\nruns: github\n---\n# Cloud\n' > .tickets/t-c3j5/ticket.md
L3="$(git rev-parse main)"; O3TIP="$(git -C "$O3" rev-parse main)"
out="$("$TKT" finish "$id5" --check --fetch < /dev/null 2>&1)" || fail "finish --check --fetch failed: $out"
assert_contains "$out" "origin/main has 1 commit(s) main lacks: Push first merges origin/main into main here"
assert_eq "$L3" "$(git rev-parse main)"
out="$("$TKT" finish "$id5" --push --yes < /dev/null 2>&1)" || fail "finish --push failed on the Windows repro: $out"
assert_contains "$out" "merging origin/main conflicted only in canon's own docs (HANDOFF.md, LEARNINGS.md): resolved, both sides kept"
assert_contains "$out" "pushed main to origin"
assert_eq "$(git rev-parse main)" "$(git -C "$O3" rev-parse main)"; assert_eq "$O3TIP" "$(git rev-parse main^2)"
git show main:HANDOFF.md > "$W/h3"; ! grep -q '^<<<<<<<\|^>>>>>>>' "$W/h3" || fail "conflict markers in the merged HANDOFF.md"
assert_grep '^base focus$' "$W/h3"; assert_grep "^$SC_HERE\$" "$W/h3"; assert_grep "^$SC_KEEP\$" "$W/h3"; assert_grep "^$SC_CLOUD\$" "$W/h3"
assert_grep '^<!-- canon:recent:BEGIN -->$' "$W/h3"; ! grep -q "s-cccc\|s-dddd" "$W/h3" || fail "a Scratch entry deleted on one side came back"
[[ "$(grep -n '^<!-- canon:recent:BEGIN -->$' "$W/h3" | cut -d: -f1)" -lt "$(grep -n '^A note of the team' "$W/h3" | cut -d: -f1)" ]] \
  || fail "the Recent block moved from where it was"
git show main:LEARNINGS.md > "$W/l3"; assert_grep 't-aaaa' "$W/l3"; assert_grep 't-bbbb' "$W/l3"
[[ -f c.txt && -f w.txt ]] || fail "the merge did not bring both sides' files"
assert_grep '^github: 2$' .tickets/t-c3j5/ticket.md; assert_file_exists .tickets/t-c3j5/github.md
echo "finish --push: the Windows repro (diverged main, HANDOFF/LEARNINGS conflicts, an untracked cloud ticket copy) merges and pushes"

# Refusals: a conflict in a person's HANDOFF.md narrative, or in any other file, changes nothing here or on origin.
refuse_merge() { # refuse_merge <label> <expected>
  local rc=0 m o s; m="$(git rev-parse main)"; o="$(git -C "$O3" rev-parse main)"; s="$(git status --porcelain)"
  out="$("$TKT" finish "$id6" --push --yes < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "finish --push should refuse $1 (rc $rc): $out"
  assert_contains "$out" "$2"; assert_contains "$out" "nothing"
  [[ "$(git rev-parse main)" == "$m" && "$(git -C "$O3" rev-parse main)" == "$o" && "$(git status --porcelain)" == "$s" ]] || fail "something changed although $1 was refused"
  echo "finish --push: refused $1, nothing changed"
}
git add -A >/dev/null 2>&1 || true; git commit -qm "local record" >/dev/null 2>&1 || true; git push -q origin main
(cd "$C3" && git pull -q)
id6="$("$TKT" create "Narrative" -t task)"; git add ".tickets/$id6/ticket.md"; git commit -qm "chore: add ticket $id6"
git checkout -qb feat/n; sed -i.bak 's/^base focus$/focus from here/' HANDOFF.md && rm -f HANDOFF.md.bak; echo n > n.txt; git add -A; git commit -qm narrative
git checkout -q main; git merge -q --no-ff feat/n -m "Merge branch 'feat/n'"; markmerged "$id6" feat/n
(cd "$C3" && sed -i.bak 's/^base focus$/focus from the cloud/' HANDOFF.md && rm -f HANDOFF.md.bak && git add -A && git commit -qm "cloud narrative" && git push -q origin main)
"$TKT" finish "$id6" --push --yes < /dev/null >/dev/null 2>&1 && fail "the first push should not get through"   # commits canon's record, then refuses
refuse_merge "a HANDOFF.md narrative conflict" "conflicts in: HANDOFF.md"
# mkmerge <name> <file> <content>: a ticket merged here (canon's record committed, as Finish's first step does), unpushed; sets id6.
mkmerge() {
  git fetch -q origin; git reset -q --hard origin/main; (cd "$C3" && git pull -q)
  id6="$("$TKT" create "$1" -t task)"; git add ".tickets/$id6/ticket.md"; git commit -qm "chore: add ticket $id6"
  git checkout -qb "feat/$1"; printf '%s\n' "$3" > "$2"; git add -A; git commit -qm "$1"
  git checkout -q main; git merge -q --no-ff "feat/$1" -m "Merge branch 'feat/$1'"; markmerged "$id6" "feat/$1"; git add ".tickets/$id6/ticket.md"; git commit -qm "chore: record merge of $id6"
}
mkmerge code base.txt here-code
(cd "$C3" && echo cloud-code > base.txt && git add -A && git commit -qm "cloud code" && git push -q origin main)
refuse_merge "a conflict in a code file" "conflicts in: base.txt"
# A force-pushed origin (commits it had are gone) is never merged into: that would bring back what was removed.
mkmerge force f.txt here; git fetch -q origin
(cd "$C3" && git reset -q --hard HEAD~1 && echo r > r.txt && git add -A && git commit -qm "rewritten" && git push -qf origin main)
"$TKT" finish "$id6" --check --fetch < /dev/null >/dev/null 2>&1   # the dialog's read moves origin/main first: the guard must still see it
refuse_merge "a force-pushed origin" "origin/main was rewritten (force-pushed"
# Only behind, not diverged (pushed from another clone, origin/main here stale): a fast-forward, never a needless merge commit.
mkmerge behind b.txt b; git push -q "$O3" main:main   # by path: origin/main here is not updated
(cd "$C3" && git pull -q && echo x > x.txt && git add -A && git commit -qm "after it" && git push -q origin main)
out="$("$TKT" finish "$id6" --push --yes < /dev/null 2>&1)" || fail "finish --push failed when only behind: $out"
assert_contains "$out" "(fast-forward)"; [[ "$out" != *"Merge origin/main"* ]] || fail "a merge commit when only behind: $out"
assert_eq "after it" "$(git log -1 --format=%s main)"; assert_eq "$(git rev-parse main)" "$(git -C "$O3" rev-parse main)"
echo "finish --push: only behind origin is a fast-forward, no merge commit"
# t-e790: a project that tracks .tickets/: a Manual ticket sent with --manual-after-merge comes back in the PR closed and without manual:
# (the cloud's copy), while here it is open and Manual (import-results). Updating main sets the local copy aside and keeps it: the merge
# never closes it before the person's test, and never stops on it either.
(cd "$C3" && git pull -q && mkdir -p .tickets/t-mmmm && printf -- '---\nid: t-mmmm\nstatus: open\ntype: task\npriority: 2\n---\n# Manual\n' > .tickets/t-mmmm/ticket.md \
  && git add -A && git commit -qm "chore: add ticket t-mmmm" && git push -q origin main)
mkmerge manualpr mp.txt mp
printf -- '---\nid: t-mmmm\nstatus: open\ntype: task\npriority: 2\nmanual: true\ngithub: acme/app#9\nruns: github\ncloud_status: closed\n---\n# Manual\n' > .tickets/t-mmmm/ticket.md
(cd "$C3" && printf -- '---\nid: t-mmmm\nstatus: closed\ntype: task\npriority: 2\nclosed: 2026-11-13T00:00:00Z\n---\n# Manual\n' > .tickets/t-mmmm/ticket.md \
  && git add -A && git commit -qm "Merge pull request #9" && git push -q origin main)
out="$("$TKT" finish "$id6" --push --yes < /dev/null 2>&1)" || fail "finish --push stopped on the local Manual ticket copy: $out"
assert_contains "$out" "pushed main to origin"
assert_grep '^manual: true$' .tickets/t-mmmm/ticket.md; assert_grep '^status: open$' .tickets/t-mmmm/ticket.md
assert_grep '^status: closed$' <(git show main:.tickets/t-mmmm/ticket.md)   # what merged is the cloud's copy; the local one is kept beside it
echo "finish --push: a tracked Manual ticket's local copy (open, Manual) is kept across the merge"
cd "$P"

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
