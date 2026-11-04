#!/usr/bin/env bash
# t-2906: tkt merge <id> merges a closed ticket's worktree branch into the main checkout's branch, the board's Check & merge for a
# worktree ticket. Prod path: `tkt merge` (the card's Check & merge, /api/github/<id>/merge-check and POST .../merge).
# Every refusal changes nothing: main's ref, the main checkout, the worktree and ticket.md stay as they were, and none of the
# branch's code runs. A merge is one commit whose tree is the tree the tests ran on, and main moves through _ff_here's rules.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-merge-branch.XXXXXX")"
use_fresh_board "$W/board"   # the branch.merged event goes through the board binary (built before HOME moves)
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" TMPDIR="$W/tmp" STUB_W="$W"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com

P="$W/project"; mkdir "$P"; cd "$P"; git init -q
# The suite leaves $STUB_W/ran behind, so a test can tell whether the branch's code ran at all.
mkdir -p scripts; printf '#!/usr/bin/env bash\ntouch "$STUB_W/ran"\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
printf '.tickets/\n' > .gitignore; echo base > base.txt; git add -A; git commit -qm base
WT="$W/wt"; git worktree add -q "$WT" -b feat/x
WT="$(cd "$WT" && pwd -P)"
(cd "$WT" && echo change > change.txt && git add change.txt && git commit -qm "the branch")
BHEAD="$(git rev-parse feat/x)"; BASE="$(git rev-parse main)"

id="$("$TKT" create "Worktree ticket" -t task)"; f=".tickets/$id/ticket.md"
printf '%s\n' "$WT" > ".tickets/$id/.cockpit-cwd"
eval_ok() { printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "${1:-$BHEAD}" > ".tickets/$id/eval-report.md"; }
eval_ok

sig() { printf '%s|%s|%s|%s\n' "$(cksum < "$f")" "$(git rev-parse main)" "$(git -C "$WT" status --porcelain)" "$(git status --porcelain)"; }

# refuses <label> <expected message> [merge args...]: exit 1, the message, nothing changed, nothing of the branch's ran.
refuses() {
  local label="$1" part="$2"; shift 2; local before rc=0; before="$(sig)"; rm -f "$W/ran"
  out="$("$TKT" merge "$id" "$@" < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "merge should refuse $label (rc $rc): $out"
  assert_contains "$out" "$part"
  [[ "$(sig)" == "$before" ]] || fail "something changed although merge refused $label"
  [[ ! -e "$W/ran" ]] || fail "the branch's test command ran although merge refused $label before asking"
  echo "merge: refused $label"
}

refuses "an open ticket" "not closed" --yes
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id" >/dev/null
printf 'graded-head: %s\nfail: one criterion\n' "$BHEAD" > ".tickets/$id/eval-report.md"
refuses "a failing verdict" "no passing evaluator verdict" --yes
eval_ok 0123456789abcdef0123456789abcdef01234567
refuses "a head the evaluator did not grade" "is not the commit the evaluator graded" --yes
eval_ok
mv ".tickets/$id/.cockpit-cwd" "$W/cwd"
refuses "a ticket with no worktree" "not bound to a worktree" --yes
mv "$W/cwd" ".tickets/$id/.cockpit-cwd"
echo edited >> "$WT/change.txt"
refuses "uncommitted changes in the worktree" "uncommitted changes the evaluator did not grade" --yes
assert_contains "$out" "change.txt"
git -C "$WT" checkout -q -- change.txt
refuses "--pr on a worktree ticket" "--pr is for a ticket sent to GitHub" --pr 3
refuses "--yes with --check" "do not go together" --yes --check

# A conflict: main changed the same file. The files are named, and so is the way out.
echo other > change.txt; git add change.txt; git commit -qm "main's change"; MAIN_C="$(git rev-parse HEAD)"
refuses "a conflicting merge" "conflicts in: change.txt" --yes
assert_contains "$out" "next: in $WT run git merge main"
git reset -q --hard HEAD~1; [[ "$(git rev-parse HEAD)" != "$MAIN_C" ]] || fail "the conflict fixture was not undone"

# A failing test command: not merged, the log kept.
refuses "a failing test command" "exit 1 failed on main + feat/x; not merging." --test "exit 1" --yes
assert_contains "$out" "Full log kept at:"; rm -f "$TMPDIR"/tkt-merge-*

# --check: the report the board's dialog reads; none of the branch's code runs.
before="$(sig)"; rm -f "$W/ran"
out="$("$TKT" merge "$id" --check < /dev/null 2>&1)" || fail "merge --check failed: $out"
assert_contains "$out" "feat/x: 1 file changed"
assert_contains "$out" "merge: ready: would run scripts/test.sh on main + feat/x, then merge"
[[ "$(sig)" == "$before" && ! -e "$W/ran" ]] || fail "--check changed something or ran the branch's code"
out="$("$TKT" merge "$id" --check --test "" < /dev/null 2>&1)" || fail "merge --check --test '' failed: $out"
assert_contains "$out" "merge: ready: no test command (pass --test); would merge feat/x on the gates alone"
echo "merge --check: report lines, nothing run"

# An edited file in the main checkout that the merge changes: --check names it; the merge stops with main unchanged.
echo mine > change.txt
out="$("$TKT" merge "$id" --check < /dev/null 2>&1)" || fail "merge --check failed: $out"
assert_contains "$out" "edited in the main checkout and changed by this merge"
assert_contains "$out" "change.txt"
refuses_after_tests() {
  local rc=0 m; m="$(git rev-parse main)"
  out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "merge should stop at the update (rc $rc): $out"
  [[ "$(git rev-parse main)" == "$m" ]] || fail "main moved although a file there differs"
  ! grep -q '^merged:' "$f" || fail "merged: written although main did not move"
}
refuses_after_tests
assert_contains "$out" "not merged; main is unchanged"
assert_contains "$out" "then run: tkt merge $id"
assert_eq mine "$(cat change.txt)"
echo "merge: an edited file in the main checkout stops the update, nothing changed"

# The merge built here must hold exactly the tree the tests ran on: a git that builds another one (shimmed) is refused.
mkdir -p "$W/bin"; REAL_GIT="$(command -v git)"
cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
if [[ -n "\${STUB_TREE:-}" && " \$* " == *" merge-tree --write-tree "* && " \$* " != *" --name-only "* ]]; then echo "\$STUB_TREE"; exit 0; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/bin/git"
m="$(git rev-parse main)"
out="$(PATH="$W/bin:$PATH" STUB_TREE="$(git rev-parse "$BASE^{tree}")" "$TKT" merge "$id" --yes < /dev/null 2>&1)" && fail "merge should refuse a tree that is not the tested one: $out"
assert_contains "$out" "is not the tree the tests ran on ("
assert_eq "$m" "$(git rev-parse main)"; ! grep -q '^merged:' "$f" || fail "merged: written although the tree check refused"
echo "merge: refused a merge tree that is not the tested tree"

# A copy identical to the merged one is canon's own kind of difference (_ff_here sets it aside); the merge goes through.
echo change > change.txt
rm -f "$W/ran"
out="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "merge --yes failed: $out"
assert_file_exists "$W/ran"
new="$(git rev-parse main)"
assert_contains "$out" "Merged feat/x into main ($new)."
assert_contains "$out" "next: the worktree $WT is free"   # no remote here: nothing to push or reset against
assert_eq "Merge branch 'feat/x'" "$(git log -1 --format=%s main)"
assert_eq "$BASE" "$(git rev-parse main^1)"
assert_eq "$(git rev-parse main^2)" "$BHEAD"
assert_eq "$(git rev-parse "$new^{tree}")" "$(git merge-tree --write-tree "$new^1" "$BHEAD" | awk 'NR == 1')"
assert_eq change "$(cat change.txt)"
[[ -z "$(git status --porcelain)" ]] || fail "the main checkout is not clean after the merge: $(git status --porcelain)"
assert_grep "^merged: $new$" "$f"
line="$(event_line branch.merged "$id")"; assert_contains "$line" '"branch":"feat/x"'
echo "merge --yes: one merge commit with both parents, the tested tree, merged: and the event"

refuses "an already merged ticket" "is already merged" --yes

# A branch already in main, on a ticket with no merged: line.
id2="$("$TKT" create "Second" -t task)"
git worktree add -q "$W/wt2" -b feat/old "$new"
printf '%s\n' "$(cd "$W/wt2" && pwd -P)" > ".tickets/$id2/.cockpit-cwd"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$new" > ".tickets/$id2/eval-report.md"
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id2" >/dev/null
out="$("$TKT" merge "$id2" --yes < /dev/null 2>&1)" && fail "merge of a branch already in main should refuse"
assert_contains "$out" "feat/old is already in main; nothing to merge"
echo "merge: refused a branch already in main"

# A project that tracks .tickets/ and HANDOFF.md (evaluator of t-2906): the main checkout holds canon's own local edits to files
# the merge changes, a HANDOFF.md whose only change is the Recent activity block and this ticket's ticket.md differing only in
# canon's per-machine fields. Both are set aside, the merge goes through, the branch's narrative and the closed ticket arrive,
# the local fields are kept, and HANDOFF.md gets the "merged here" Recent line (handoff_recent).
P2="$W/tracked"; mkdir "$P2"; cd "$P2"; git init -q
printf '# Handoff\n\n<!-- canon:handoff:BEGIN -->\n## Current Focus\nbefore\n<!-- canon:handoff:END -->\n' > HANDOFF.md
echo base > base.txt; git add -A; git commit -qm base
id4="$("$TKT" create "Tracked" -t task)"; f4=".tickets/$id4/ticket.md"; git add "$f4"; git commit -qm "chore: add ticket"
WT4="$W/wt4"; git worktree add -q "$WT4" -b feat/y; WT4="$(cd "$WT4" && pwd -P)"
TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id4" >/dev/null
cp "$f4" "$WT4/$f4"
(cd "$WT4" && sed -i.bak 's/^before$/after the branch/' HANDOFF.md && rm -f HANDOFF.md.bak && echo y > y.txt && git add HANDOFF.md y.txt "$f4" && git commit -qm "the branch")
printf '%s\n' "$WT4" > ".tickets/$id4/.cockpit-cwd"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$(git rev-parse feat/y)" > ".tickets/$id4/eval-report.md"
awk '/^---$/ && ++n == 2 { print "cloud_status: done" } { print }' "$f4" > "$W/t4" && mv "$W/t4" "$f4"   # a per-machine field, local only
"$SPRINT_CHECK_BIN" event plan.approved --source sprint --project "$(pwd -P)" "ticket=$id4" tier=normal </dev/null >/dev/null 2>&1
"$SPRINT_CHECK_BIN" recent --project "$(pwd -P)" --handoff HANDOFF.md </dev/null >/dev/null 2>&1
assert_grep '^<!-- canon:recent:BEGIN -->$' HANDOFF.md   # the main checkout's HANDOFF.md now differs only in the block
out="$("$TKT" merge "$id4" --yes < /dev/null 2>&1)" || fail "merge with canon's own local edits set aside failed: $out"
assert_contains "$out" "Merged feat/y into main"
assert_grep '^after the branch$' HANDOFF.md
assert_contains "$(cat HANDOFF.md)" "merged here (feat/y)"
assert_grep '^status: closed$' "$f4"; assert_grep '^cloud_status: done$' "$f4"; assert_grep '^merged: ' "$f4"
echo "merge: a block-only HANDOFF.md and the ticket's per-machine fields are set aside and kept; the Recent line is written"
cd "$P"

# t-c91a: a project that tracks .tickets/ and a ticket closed ONLY in its worktree (the real flow: copy_ticket_back does nothing
# for a tracked .tickets/, the closed ticket and its eval-report.md reach main through this merge). Main's copy still says open.
# The worktree's own copy decides. (The block above closes the ticket in main first, which is why this was never seen.)
P3="$W/tracked-wt"; mkdir "$P3"; cd "$P3"; git init -q
mkdir -p scripts; printf '#!/usr/bin/env bash\ntouch "$STUB_W/ran"\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
echo base > base.txt; mkdir .tickets; printf '.cockpit-*\nACTIVE\n' > .tickets/.gitignore
id5="$("$TKT" create "Tracked, closed in its worktree" -t task)"; f5=".tickets/$id5/ticket.md"
git add -A; git commit -qm base
WT5="$W/wt5"; git worktree add -q "$WT5" -b feat/z; WT5="$(cd "$WT5" && pwd -P)"
printf '%s\n' "$WT5" > ".tickets/$id5/.cockpit-cwd"
(cd "$WT5" && echo z > z.txt && TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id5" >/dev/null && git add -A && git commit -qm "the branch and the closed ticket")
printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$(git -C "$WT5" rev-parse HEAD)" > "$WT5/.tickets/$id5/eval-report.md"
(cd "$WT5" && git add -A && git commit -qm "eval report (late docs)")
assert_grep '^status: open$' "$f5"; assert_grep '^status: closed$' "$WT5/$f5"   # the premise: main open, the worktree closed
[[ ! -e ".tickets/$id5/eval-report.md" ]] || fail "the premise is wrong: main already has the eval report"
id_s="$id"; f_s="$f"; WT_s="$WT"; id="$id5"; f="$f5"; WT="$WT5"   # refuses/sig read these
out="$("$TKT" merge "$id5" --check < /dev/null 2>&1)" || fail "merge --check refused a tracked-.tickets ticket closed in its worktree: $out"
assert_contains "$out" "merge: ready: would run scripts/test.sh on main + feat/z, then merge"
echo "merge --check: a tracked .tickets/ ticket closed only in its worktree is ready"
# The worktree's copy is the authority: main says closed, the worktree reopened it.
sed -i.bak 's/^status: open$/status: closed/' "$f5" && rm -f "$f5.bak"
sed -i.bak 's/^status: closed$/status: open/' "$WT5/$f5" && rm -f "$WT5/$f5.bak"
refuses "a copy reopened in the worktree (main's copy says closed)" "is open, not closed" --yes
git checkout -q -- "$f5"; git -C "$WT5" checkout -q -- "$f5"
# A link in the worktree's path is never read: main's copy (open) decides.
mv "$WT5/.tickets/$id5" "$W/ext5"; ln -s "$W/ext5" "$WT5/.tickets/$id5"
refuses "a symlinked worktree ticket folder (main's copy is open)" "is open, not closed" --yes
rm "$WT5/.tickets/$id5"; mv "$W/ext5" "$WT5/.tickets/$id5"
# An eval report that is only in the worktree's folder, not committed on the branch, is not part of what merges: not trusted.
git -C "$WT5" rm -q --cached -- ".tickets/$id5/eval-report.md"
refuses "an eval report the branch does not carry" "no passing evaluator verdict" --yes
git -C "$WT5" reset -q HEAD -- ".tickets/$id5/eval-report.md"
# merged: in the worktree's copy refuses too.
awk '/^---$/ && ++n == 2 { print "merged: abc1234" } { print }' "$WT5/$f5" > "$W/t5" && mv "$W/t5" "$WT5/$f5"
refuses "a worktree copy that already says merged" "is already merged (abc1234)" --yes
git -C "$WT5" checkout -q -- "$f5"
# The merge: main moves, and main's own copy now reads closed (it arrived through the merge).
rm -f "$W/ran"; m5="$(git rev-parse main)"
out="$("$TKT" merge "$id5" --yes < /dev/null 2>&1)" || fail "merge --yes failed for a tracked-.tickets ticket closed in its worktree: $out"
assert_file_exists "$W/ran"
assert_contains "$out" "Merged feat/z into main ("
assert_eq "$m5" "$(git rev-parse main^1)"
assert_grep '^status: closed$' "$f5"
[[ -f ".tickets/$id5/eval-report.md" ]] || fail "the eval report did not arrive with the merge"
echo "merge --yes: a tracked .tickets/ ticket closed only in its worktree merges, and main's copy closes with it"
id="$id_s"; f="$f_s"; WT="$WT_s"; cd "$P"

# runs: github goes to merge-pr, unchanged.
id3="$("$TKT" create "Cloud" -t task)"; f3=".tickets/$id3/ticket.md"
awk '/^---$/ && ++n == 2 { print "runs: github" } { print }' "$f3" > "$W/t" && mv "$W/t" "$f3"
out="$("$TKT" merge "$id3" --check < /dev/null 2>&1)" && fail "merge-pr should refuse here (no GitHub origin)"
assert_contains "$out" "merge-pr"
echo "merge: a ticket sent to GitHub goes to merge-pr"

echo "tkt-merge-branch: ok"
