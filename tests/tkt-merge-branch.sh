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

# runs: github goes to merge-pr, unchanged.
id3="$("$TKT" create "Cloud" -t task)"; f3=".tickets/$id3/ticket.md"
awk '/^---$/ && ++n == 2 { print "runs: github" } { print }' "$f3" > "$W/t" && mv "$W/t" "$f3"
out="$("$TKT" merge "$id3" --check < /dev/null 2>&1)" && fail "merge-pr should refuse here (no GitHub origin)"
assert_contains "$out" "merge-pr"
echo "merge: a ticket sent to GitHub goes to merge-pr"

echo "tkt-merge-branch: ok"
