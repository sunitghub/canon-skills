#!/usr/bin/env bash
# t-27bc: tkt merge (a closed ticket's worktree branch, the board's Check & merge) resolves a conflict that is ONLY in LEARNINGS.md itself:
# every close appends a row inside the canon:learnings block and rewrites the "last run" stamp, so two tickets closed in different
# checkouts always collide there. Prod path: `tkt merge` -> _merge_core -> _resolve_learnings_conflict. Both sides' rows are kept
# (newest first, an identical row once, the newest stamp), the tests run on the resolved tree and that tree is what lands. A conflict in any
# other file, or a LEARNINGS.md with no canon:learnings block, still refuses with nothing changed: a conflict is never hidden.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-merge-learnings.XXXXXX")"
use_fresh_board "$W/board"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" TMPDIR="$W/tmp" STUB_W="$W"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com

# a LEARNINGS.md the way learnings-sweep writes it: a stamp line, then a managed table between markers
learn() { # learn <stamp> <rows...>
  local stamp="$1"; shift
  printf '# Learnings\n\nlearnings-sweep last run: %s\n\n<!-- canon:learnings:BEGIN -->\n| Date | Ticket | Finding | Status |\n|---|---|---|---|\n' "$stamp"
  printf '%s\n' "$@"
  printf '<!-- canon:learnings:END -->\n'
}
row() { printf '| %s | [%s](.tickets/%s/learnings.md) | finding of %s | UNPROMOTED |' "$1" "$2" "$2" "$2"; }
ROW_OLD="$(row 2026-11-01 t-0001)"; ROW_MAIN="$(row 2026-11-06 t-bbbb)"; ROW_BR="$(row 2026-11-07 t-aaaa)"

P="$W/project"; mkdir "$P"; cd "$P"; git init -q
# the suite records the LEARNINGS.md it ran against, so the test can tell the tests ran on the resolved tree
mkdir -p scripts; printf '#!/usr/bin/env bash\ncp LEARNINGS.md "$STUB_W/seen-learnings" 2>/dev/null || true\ntouch "$STUB_W/ran"\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
printf '.tickets/\n' > .gitignore; echo base > base.txt; learn "11-01-2026 09:00" "$ROW_OLD" > LEARNINGS.md
git add -A; git commit -qm base
WT="$W/wt"; git worktree add -q "$WT" -b feat/x; WT="$(cd "$WT" && pwd -P)"
(cd "$WT" && learn "11-07-2026 12:00" "$ROW_BR" "$ROW_OLD" > LEARNINGS.md && echo change > change.txt && git add -A && git commit -qm "the branch")
learn "11-06-2026 18:30" "$ROW_MAIN" "$ROW_OLD" > LEARNINGS.md; git add -A; git commit -qm "main closes another ticket"
BHEAD="$(git rev-parse feat/x)"; BASE="$(git rev-parse main)"

id="$("$TKT" create "Worktree ticket" -t task)"; f=".tickets/$id/ticket.md"
printf '%s\n' "$WT" > ".tickets/$id/.cockpit-cwd"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$BHEAD" > ".tickets/$id/eval-report.md"
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id" >/dev/null
unmerge() { grep -vE '^(merged|merged_into|merged_branch):' "$f" > "$f.t" && mv "$f.t" "$f"; }   # a fresh start for the next case
sig() { printf '%s|%s|%s\n' "$(cksum < "$f")" "$(git rev-parse main)" "$(git status --porcelain)"; }

# 1. a LEARNINGS.md-only conflict merges: both rows, rows newest first, one stamp (the newest), the tests ran on that file
rm -f "$W/ran" "$W/seen-learnings"
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "a LEARNINGS.md-only conflict should merge: $out"
assert_contains "$out" "conflicted only in LEARNINGS.md: resolved it"
assert_contains "$out" "Merged feat/x into main"
got="$(git show main:LEARNINGS.md)"
[[ "$(grep -c '^learnings-sweep last run:' <<< "$got")" == 1 ]] || fail "two stamp lines survived: $got"
assert_contains "$got" "learnings-sweep last run: 11-07-2026 12:00"
rows="$(grep '^| 20' <<< "$got" | cut -d'|' -f2,3 | paste -sd';' -)"
exp="$(printf '%s\n' "$ROW_BR" "$ROW_MAIN" "$ROW_OLD" | cut -d'|' -f2,3 | paste -sd';' -)"
[[ "$rows" == "$exp" ]] \
  || fail "rows are not both sides' rows newest first: $rows"
[[ "$(grep -c 'canon:learnings:BEGIN' <<< "$got")" == 1 && "$(grep -c 'canon:learnings:END' <<< "$got")" == 1 ]] || fail "the markers are not single: $got"
[[ -e "$W/ran" ]] || fail "the tests did not run"
[[ "$(cat "$W/seen-learnings")" == "$got" ]] || fail "the tests ran on a different LEARNINGS.md than the one that landed"
[[ "$(git rev-list --parents -n1 main | wc -w | tr -d ' ')" == 3 ]] || fail "the landed commit is not a two-parent merge"
[[ "$(git rev-parse main^2)" == "$BHEAD" && "$(git rev-parse main^1)" == "$BASE" ]] || fail "the merge commit's parents are not main and the branch head"
[[ "$(git show main:change.txt)" == change ]] || fail "the branch's own file did not land"
echo "merge: resolved a LEARNINGS.md-only conflict, both rows, newest stamp, tested tree landed"

# 2. a second conflicted file refuses and names both, nothing changes
git reset -q --hard "$BASE"; git -C "$WT" reset -q --hard "$BHEAD"; unmerge
rm -f "$W/ran"
(cd "$WT" && echo branch-edit > base.txt && git commit -qam "branch edits base.txt") ; BHEAD2="$(git -C "$WT" rev-parse HEAD)"
echo main-edit > base.txt; git commit -qam "main edits base.txt"
printf 'evaluator-run-id: 1-2\ngraded-head: %s\n## Verdict\npass: all met\n' "$BHEAD2" > ".tickets/$id/eval-report.md"
before="$(sig)"; rc=0
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a LEARNINGS.md plus base.txt conflict must refuse (rc $rc): $out"
assert_contains "$out" "does not merge into main"; assert_contains "$out" "LEARNINGS.md"; assert_contains "$out" "base.txt"
[[ "$(sig)" == "$before" && ! -e "$W/ran" ]] || fail "something changed or ran although the merge refused a two-file conflict"
echo "merge: refused LEARNINGS.md plus another conflicted file, naming both"

# 3. a LEARNINGS.md with no canon:learnings block is not resolved
git reset -q --hard "$BASE"; git -C "$WT" reset -q --hard "$BHEAD"; unmerge
printf 'no managed block here\nmain line\n' > LEARNINGS.md; git commit -qam "main rewrites LEARNINGS.md without the block"
(cd "$WT" && printf 'no managed block here\nbranch line\n' > LEARNINGS.md && git commit -qam "branch rewrites it too"); BHEAD3="$(git -C "$WT" rev-parse HEAD)"
printf 'evaluator-run-id: 1-3\ngraded-head: %s\n## Verdict\npass: all met\n' "$BHEAD3" > ".tickets/$id/eval-report.md"
before="$(sig)"; rc=0
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a LEARNINGS.md without the managed block must refuse (rc $rc): $out"
assert_contains "$out" "conflicts in: LEARNINGS.md"
[[ "$(sig)" == "$before" ]] || fail "something changed although the merge refused"
echo "merge: refused a LEARNINGS.md conflict with no managed block"
echo "tkt-merge-learnings: ok"
