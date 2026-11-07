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
mkdir -p scripts; printf '#!/usr/bin/env bash\ncp LEARNINGS.md "$STUB_W/seen-learnings" 2>/dev/null || true\ntouch "$STUB_W/ran"\ncase "$(cat "$STUB_W/inject" 2>/dev/null || true)" in\n  commit) echo x > injected.txt; git add injected.txt; git commit -qm injected ;;   # the tested tree stops being the merge\n  detach) git checkout -q --detach HEAD^ ;;\nesac\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
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

# regraded <head> — the ticket is graded at that head again, and unmerged
regraded() { printf 'evaluator-run-id: 1-9\ngraded-head: %s\n## Verdict\npass: all met\n' "$1" > ".tickets/$id/eval-report.md"; unmerge; }

# 4. a row both sides added (in different places, so git keeps both copies) appears once, not twice
git reset -q --hard "$BASE"; git -C "$WT" reset -q --hard "$BHEAD"
ROW_SHARED="$(row 2026-11-07 t-cccc)"
learn "11-06-2026 19:00" "$ROW_SHARED" "$ROW_MAIN" "$ROW_OLD" > LEARNINGS.md; git commit -qam "main adds the shared row at the top"
(cd "$WT" && learn "11-07-2026 12:00" "$ROW_BR" "$ROW_OLD" "$ROW_SHARED" > LEARNINGS.md && git commit -qam "branch adds the same row at the bottom"); H4="$(git -C "$WT" rev-parse HEAD)"
regraded "$H4"
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "a shared row should still merge: $out"
[[ "$(git show main:LEARNINGS.md | grep -cF 'finding of t-cccc')" == 1 ]] || fail "the shared row is not exactly one row"
[[ "$(git show main:LEARNINGS.md | grep -c '^| 20')" == 4 ]] || fail "expected 4 rows (shared once, main's, the branch's, the old one): $(git show main:LEARNINGS.md)"
echo "merge: an identical row both sides added is kept once"

# 5. a line a person wrote inside the managed block is never dropped: the conflict stays
git reset -q --hard "$BASE"; git -C "$WT" reset -q --hard "$BHEAD"
learn "11-06-2026 19:00" "$ROW_MAIN" "$ROW_OLD" | awk '/^\| Date \|/ { print "a note I wrote by hand" } { print }' > LEARNINGS.md; git commit -qam "main has a hand note inside the block"
(cd "$WT" && learn "11-07-2026 13:00" "$ROW_BR" "$ROW_OLD" > LEARNINGS.md && git commit -qam "branch adds its row"); H5="$(git -C "$WT" rev-parse HEAD)"
regraded "$H5"; before="$(sig)"; rc=0
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a hand-written line inside the block must refuse (rc $rc): $out"
assert_contains "$out" "conflicts in: LEARNINGS.md"; [[ "$(sig)" == "$before" ]] || fail "something changed although the merge refused"
echo "merge: refused a hand-written line inside the managed block"

# 6. a hand edit outside the block that both sides made differently (the heading) is a real conflict, not two headings
git reset -q --hard "$BASE"; git -C "$WT" reset -q --hard "$BHEAD"
learn "11-06-2026 19:00" "$ROW_MAIN" "$ROW_OLD" | sed '1s/.*/# Learnings (main)/' > LEARNINGS.md; git commit -qam "main retitles the file"
(cd "$WT" && learn "11-07-2026 14:00" "$ROW_BR" "$ROW_OLD" | sed '1s/.*/# Learnings (branch)/' > LEARNINGS.md && git commit -qam "branch retitles it differently"); H6="$(git -C "$WT" rev-parse HEAD)"
regraded "$H6"; before="$(sig)"; rc=0
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "two different hand edits outside the block must refuse (rc $rc): $out"
[[ "$(sig)" == "$before" ]] || fail "something changed although the merge refused"
echo "merge: refused two different hand edits outside the managed block"

# reset_case — main and the branch back to the shared starting point, the ticket unmerged
reset_case() { git reset -q --hard "$BASE"; git -C "$WT" reset -q --hard "$BHEAD"; rm -f "$W/inject"; }
# refused <head> <label> — merge at that head must refuse (rc 1) with "conflicts in: LEARNINGS.md" and change nothing
refused() {
  regraded "$1"; local before rc=0 out; before="$(sig)"
  out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "$2 must refuse (rc $rc): $out"
  assert_contains "$out" "conflicts in: LEARNINGS.md"
  [[ "$(sig)" == "$before" ]] || fail "something changed although the merge refused: $2"
}
# edit_both <main-filter> <branch-filter> — each side rewrites LEARNINGS.md through its own shell filter and commits (rows differ, so git conflicts)
edit_both() {
  learn "11-06-2026 19:00" "$ROW_MAIN" "$ROW_OLD" | eval "$1" > LEARNINGS.md; git commit -qam "main edits LEARNINGS.md"
  (cd "$WT" && learn "11-07-2026 13:00" "$ROW_BR" "$ROW_OLD" | eval "$2" > LEARNINGS.md && git commit -qam "branch edits LEARNINGS.md"); H="$(git -C "$WT" rev-parse HEAD)"
}

# 7. t-27bc, _resolve_learnings_conflict outside-the-block check: an edit outside the block that only ONE side made, or that both made identically,
# is not a conflict: it lands once (guards a person's note from being refused or doubled on the shared file)
for variant in main-only branch-only same; do
  reset_case
  m=cat; b=cat
  case "$variant" in main-only) m="awk '{ print } END { print \"footer note\" }'";; branch-only) b="awk '{ print } END { print \"footer note\" }'";; same) m="awk '{ print } END { print \"footer note\" }'"; b="awk '{ print } END { print \"footer note\" }'";; esac
  edit_both "$m" "$b"; regraded "$H"
  out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "$variant: a one-sided outside edit should merge: $out"
  got="$(git show main:LEARNINGS.md)"
  [[ "$(grep -cx 'footer note' <<< "$got")" == 1 ]] || fail "$variant: the footer note is not there exactly once: $got"
  [[ "$(grep -c '^| 20' <<< "$got")" == 3 ]] || fail "$variant: expected 3 rows: $got"
done
echo "merge: an outside edit made by one side, or by both identically, lands once"

# 8. t-27bc, shape guard: a block that cannot be read as one table is a conflict left to the person (nothing dropped, nothing changed)
reset_case   # two BEGIN markers
edit_both "awk '/canon:learnings:BEGIN/ { print } { print }'" "awk '/canon:learnings:BEGIN/ { print } { print }'"
refused "$H" "two BEGIN markers"
reset_case   # two END markers
edit_both "awk '/canon:learnings:BEGIN/ { print \"<!-- canon:learnings:END -->\" } { print }'" "awk '/canon:learnings:BEGIN/ { print \"<!-- canon:learnings:END -->\" } { print }'"
refused "$H" "two END markers"
reset_case   # no "last run" stamp at all
edit_both "grep -v '^learnings-sweep'" "grep -v '^learnings-sweep'"
refused "$H" "no stamp line"
reset_case   # a block without its |---| separator row
edit_both "grep -v '^|---'" "grep -v '^|---'"
refused "$H" "a block with no separator row"
reset_case   # END before BEGIN (the block is never closed)
edit_both "awk '/canon:learnings:END/ { next } /canon:learnings:BEGIN/ { print \"<!-- canon:learnings:END -->\" } { print }'" "awk '/canon:learnings:END/ { next } /canon:learnings:BEGIN/ { print \"<!-- canon:learnings:END -->\" } { print }'"
refused "$H" "END before BEGIN"
echo "merge: refused a malformed block (2 BEGIN, 2 END, no stamp, no separator, END first)"

# 9. t-27bc, hand line among the rows (case 5 puts it before the header, this one between rows) is never dropped; a blank line is not a row
reset_case
edit_both "awk '{ print } /^\\|---/ { print \"a note I wrote by hand\" }'" "cat"
refused "$H" "a hand-written line among the rows"
reset_case
edit_both "awk '{ print } /^\\|---/ { print \"\" }'" "cat"
regraded "$H"
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "a blank line in the block should still merge: $out"
got="$(git show main:LEARNINGS.md)"
[[ "$(sed -n '/BEGIN/,/END/p' <<< "$got" | sed '1d;$d' | grep -vc '^|' || true)" == 0 ]] || fail "a blank or stray line survived inside the block: $got"
echo "merge: a hand line among the rows refuses; a blank line is dropped, not kept as a row"

# 10. t-27bc: conflict markers already in the file (outside the block, on all three sides) must not be written back as a resolved file
reset_case
edit_both "awk '{ print } END { print \"<<<<<<< left over from an old merge\" }'" "awk '{ print } END { print \"<<<<<<< left over from an old merge\" }'"
refused "$H" "conflict markers in the output"
echo "merge: refused when conflict markers would remain in the resolved file"

# 11. t-27bc: git merge-file failing hard (a binary file) refuses; the stamp that cannot be parsed is kept as it was, not blanked
reset_case
edit_both "awk '{ print } /^\\|---/ { print \"| 2026-11-06 | bin~ | x | y |\" }' | tr '~' '\\000'" "awk '{ print } /^\\|---/ { print \"| 2026-11-07 | bin~ | x | y |\" }' | tr '~' '\\000'"
refused "$H" "a file git merge-file cannot merge (binary)"
reset_case
edit_both "sed 's/^learnings-sweep last run: .*/learnings-sweep last run: sometime/'" "sed 's/^learnings-sweep last run: .*/learnings-sweep last run: sometime else/'"
regraded "$H"
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "unparseable stamps should still merge: $out"
[[ "$(git show main:LEARNINGS.md | grep -c '^learnings-sweep last run: ')" == 1 ]] || fail "the stamp line is gone or doubled: $(git show main:LEARNINGS.md)"
echo "merge: a binary file refuses; an unparseable stamp is kept as one line"

# 12. t-27bc, a conflict in some other file only (LEARNINGS.md merges cleanly) is never touched by the resolver
reset_case; git -C "$WT" reset -q --hard "$BASE^"   # the branch leaves LEARNINGS.md alone: it merges cleanly
(cd "$WT" && echo branch-edit > base.txt && git commit -qam "branch edits base.txt only"); H="$(git -C "$WT" rev-parse HEAD)"
echo main-edit > base.txt; git commit -qam "main edits base.txt only"
regraded "$H"; before="$(sig)"; rc=0
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a conflict only in base.txt must refuse (rc $rc): $out"
assert_contains "$out" "conflicts in: base.txt"; [[ "$(sig)" == "$before" ]] || fail "something changed although the merge refused"
echo "merge: refused a conflict in a file other than LEARNINGS.md"

# 13. t-27bc, post-test tree check: the tree that lands must be the tree the tests ran on. A test run that moves the scratch clone's tree
# (here: a commit; for a resolved merge: HEAD off the merge) makes the merge refuse with nothing landed.
tree_refuses() { # tree_refuses <inject> <head> <label>
  regraded "$2"; echo "$1" > "$W/inject"; local before rc=0 out; before="$(sig)"
  out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
  [[ "$rc" != 0 ]] || fail "$3: a merge whose tree is not the tested tree must refuse: $out"
  assert_contains "$out" "tree the tests ran on"
  [[ "$(sig)" == "$before" ]] || fail "$3: something landed although the tree was not the tested one"
  rm -f "$W/inject"
}
reset_case; git -C "$WT" reset -q --hard "$BASE"   # a clean merge (no LEARNINGS.md conflict)
(cd "$WT" && echo more > more.txt && git add more.txt && git commit -qm "branch adds a file"); H="$(git -C "$WT" rev-parse HEAD)"
tree_refuses commit "$H" "clean merge"
reset_case   # a resolved LEARNINGS.md merge
tree_refuses detach "$BHEAD" "resolved merge, clone left off the merge"
echo "merge: refused when the tree to land is not the tree the tests ran on (clean and resolved merges)"
echo "tkt-merge-learnings: ok"
