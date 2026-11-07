#!/usr/bin/env bash
# t-27bc: after tkt merge puts a worktree ticket's branch on the default branch, canon's own merge record (ticket.md's merged: fields,
# the untracked cockpit-sessions.md, and HANDOFF.md's generated Recent activity block) is left uncommitted in the main checkout, so master shows
# modified files and the board counts them. Prod path: `tkt finish --push --yes` (the Finish step's Push) first commits exactly those
# files as "chore: record merge of <id>", then pushes. Anything else that is dirty stays dirty and is named; nothing is staged with a
# wildcard; a checkout on another branch, or a project that ignores .tickets/, commits nothing.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-finish-record.XXXXXX")"
use_fresh_board "$W/board"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" TMPDIR="$W/tmp" STUB_W="$W"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com

git init -q --bare "$W/origin.git"
SEED="$W/seed"; git init -q "$SEED"; cd "$SEED"
mkdir -p scripts; printf '#!/usr/bin/env bash\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
printf '# Handoff\n\nnarrative\n' > HANDOFF.md
echo base > base.txt; git add -A; git commit -qm base
git remote add origin "$W/origin.git"; git push -q origin main
P="$W/project"; git clone -q "$W/origin.git" "$P"; cd "$P"; git remote set-head origin main >/dev/null

# ticket <name> -> creates a ticket, tracked on main (the project keeps .tickets/), a worktree branch with one commit, and a passing report
ticket() {
  local n="$1" wt="$W/wt-$1"
  id="$("$TKT" create "Ticket $n" -t task)"
  git add ".tickets/$id" && git commit -qm "track $id"; git push -q origin main
  git worktree add -q "$wt" -b "feat/$n"; wt="$(cd "$wt" && pwd -P)"
  # the close happens in the worktree and the branch carries it (the project tracks .tickets/), as in the real flow
  (cd "$wt" && echo "$n" > "change-$n.txt" && TKT_SPRINT_GATE_PASSED=1 "$TKT" close "$id" >/dev/null && git add . && git commit -qm "branch $n, closed")
  printf '%s\n' "$wt" > ".tickets/$id/.cockpit-cwd"
  # the evaluator's report is a late doc the branch carries: graded-head is the commit before it
  printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "$(git -C "$wt" rev-parse HEAD)" > "$wt/.tickets/$id/eval-report.md"
  (cd "$wt" && git add .tickets && git commit -qm "eval report")
  m="$("$TKT" merge "$id" --yes < /dev/null 2>&1)" || fail "tkt merge $id failed: $m"
}

# 1. the record is left behind, then committed with the push; the tree is clean and origin has the commit with only those files
ticket one; id1="$id"
echo "cockpit-sessions: x" > ".tickets/$id1/cockpit-sessions.md"
dirty="$(git status --porcelain)"
assert_contains "$dirty" ".tickets/$id1/ticket.md"; assert_contains "$dirty" ".tickets/$id1/cockpit-sessions.md"
chk="$("$TKT" finish "$id1" --check 2>&1)"; assert_contains "$chk" "also commits canon's merge record first"
out="$("$TKT" finish "$id1" --push --yes 2>&1)" || fail "finish --push failed: $out"
assert_contains "$out" "committed canon's merge record for $id1"; assert_contains "$out" "finish: pushed main to origin"
[[ -z "$(git status --porcelain)" ]] || fail "the main checkout still shows modified files: $(git status --porcelain)"
[[ "$(git log -1 --format=%s)" == "chore: record merge of $id1" ]] || fail "the last commit is not the record: $(git log -1 --format=%s)"
files="$(git show --name-only --format= HEAD | sort | paste -sd, -)"
[[ "$files" == ".tickets/$id1/cockpit-sessions.md,.tickets/$id1/ticket.md" || "$files" == ".tickets/$id1/cockpit-sessions.md,.tickets/$id1/ticket.md,HANDOFF.md" ]] \
  || fail "the record commit holds files that are not canon's merge record: $files"
[[ "$(git rev-parse HEAD)" == "$(git --git-dir="$W/origin.git" rev-parse main)" ]] || fail "origin does not have the record commit"
echo "finish: the merge record is committed with the push; the checkout is clean"

# 2. a file the user edited is left alone and named; the record is still committed
ticket two; id2="$id"
echo "cockpit-sessions: y" > ".tickets/$id2/cockpit-sessions.md"
echo "my own change" >> base.txt
out="$("$TKT" finish "$id2" --push --yes 2>&1)" || fail "finish --push failed: $out"
assert_contains "$out" "committed canon's merge record for $id2"
assert_contains "$out" "not canon's merge record, left as they are: base.txt"
[[ "$(git status --porcelain)" == " M base.txt" ]] || fail "only the user's file should be left: $(git status --porcelain)"
[[ "$(git show --name-only --format= HEAD | grep -c base.txt || true)" == 0 ]] || fail "the user's file went into the record commit"
git checkout -q -- base.txt
echo "finish: a user's own edit stays dirty and named, outside the record commit"

# 3. HANDOFF.md the user edited by hand is not canon's record: it is never committed
ticket three; id3="$id"
echo "a line I wrote myself" >> HANDOFF.md
out="$("$TKT" finish "$id3" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$(git show --name-only --format= HEAD | grep -c '^HANDOFF.md$' || true)" == 0 ]] || fail "a hand-edited HANDOFF.md was committed"
assert_contains "$(git status --porcelain)" "HANDOFF.md"
git checkout -q -- HANDOFF.md
echo "finish: a hand-edited HANDOFF.md is never committed"

# 4. a checkout on another branch commits nothing
ticket four; id4="$id"
git switch -q -c chore/other; echo "cockpit-sessions: z" > ".tickets/$id4/cockpit-sessions.md"
before="$(git rev-parse chore/other)"
out="$("$TKT" finish "$id4" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$(git rev-parse chore/other)" == "$before" ]] || fail "a commit was made on the checkout's other branch"
[[ "$out" != *"committed canon's merge record"* ]] || fail "it claims to have committed the record on another branch: $out"
echo "finish: a checkout on another branch commits nothing"
git switch -q main; git checkout -q -- . ; git clean -fdq .tickets   # back on main with a clean tree for the cases below

# 5. a ticket.md the user also edited by hand is not canon's record: left dirty and named, never committed under canon's message
ticket five; id5="$id"
echo "my own note on the ticket" >> ".tickets/$id5/ticket.md"
echo "cockpit-sessions: w" > ".tickets/$id5/cockpit-sessions.md"
out="$("$TKT" finish "$id5" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$(git show --name-only --format= HEAD | grep -c 'ticket.md' || true)" == 0 ]] || fail "a hand-edited ticket.md went into canon's record commit"
assert_contains "$(git status --porcelain)" ".tickets/$id5/ticket.md"
git show origin/main:".tickets/$id5/ticket.md" 2>/dev/null | grep -q "my own note" && fail "the user's note was pushed"
git checkout -q -- ".tickets/$id5/ticket.md"
echo "finish: a hand-edited ticket.md is never committed or pushed"

# 6. a file the user staged is not swept into the record commit and stays staged
ticket six; id6="$id"
echo "cockpit-sessions: v" > ".tickets/$id6/cockpit-sessions.md"
echo staged > staged.txt; git add staged.txt
out="$("$TKT" finish "$id6" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$(git show --name-only --format= HEAD | grep -c 'staged.txt' || true)" == 0 ]] || fail "a staged unrelated file went into the record commit"
[[ "$(git status --porcelain staged.txt)" == "A  staged.txt" ]] || fail "the user's staged file is no longer staged: $(git status --porcelain staged.txt)"
git reset -q staged.txt; rm -f staged.txt
echo "finish: a staged unrelated file stays staged and out of the record commit"

# 7. a record file git ignores is never committed (and never an error)
ticket seven; id7="$id"
echo "cockpit-sessions: u" > ".tickets/$id7/cockpit-sessions.md"; echo ".tickets/$id7/cockpit-sessions.md" >> .git/info/exclude
out="$("$TKT" finish "$id7" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$(git show --name-only --format= HEAD | grep -c 'cockpit-sessions.md' || true)" == 0 ]] || fail "an ignored file was committed"
echo "finish: an ignored record file is left out"
echo "tkt-finish-record: ok"
