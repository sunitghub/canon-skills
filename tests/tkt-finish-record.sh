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

# recorded <id> <expected paths, comma separated> — the last commit is canon's record of <id> and holds exactly those files
recorded() {
  [[ "$(git log -1 --format=%s)" == "chore: record merge of $1" ]] || fail "the last commit is not the record of $1: $(git log -1 --format=%s)"
  [[ "$(git show --name-only --format= HEAD | sort | paste -sd, -)" == "$2" ]] || fail "the record of $1 holds: $(git show --name-only --format= HEAD | paste -sd, -), not $2"
}
tdirty() { git checkout -q -- . ; git clean -fdq .tickets; }   # drop what a case left dirty

# 1. the record is left behind, then committed with the push; the tree is clean and origin has the commit with only those files
ticket one; id1="$id"
echo "cockpit-sessions: x" > ".tickets/$id1/cockpit-sessions.md"
dirty="$(git status --porcelain)"
assert_contains "$dirty" ".tickets/$id1/ticket.md"; assert_contains "$dirty" ".tickets/$id1/cockpit-sessions.md"
handoff_dirty=false; [[ "$dirty" == *HANDOFF.md* ]] && handoff_dirty=true   # the merge rewrites HANDOFF.md's generated Recent activity block: canon's own record
chk="$("$TKT" finish "$id1" --check 2>&1)"; assert_contains "$chk" "also commits canon's merge record first"
out="$("$TKT" finish "$id1" --push --yes 2>&1)" || fail "finish --push failed: $out"
assert_contains "$out" "committed canon's merge record for $id1"; assert_contains "$out" "finish: pushed main to origin"
[[ "$out" != *"these files are modified"* ]] || fail "it names modified files although the checkout is clean now: $out"   # t-27bc: finish --push's rest report
[[ -z "$(git status --porcelain)" ]] || fail "the main checkout still shows modified files: $(git status --porcelain)"
[[ "$(git log -1 --format=%s)" == "chore: record merge of $id1" ]] || fail "the last commit is not the record: $(git log -1 --format=%s)"
files="$(git show --name-only --format= HEAD | sort | paste -sd, -)"
[[ "$files" == ".tickets/$id1/cockpit-sessions.md,.tickets/$id1/ticket.md" || "$files" == ".tickets/$id1/cockpit-sessions.md,.tickets/$id1/ticket.md,HANDOFF.md" ]] \
  || fail "the record commit holds files that are not canon's merge record: $files"
if $handoff_dirty; then [[ "$files" == *HANDOFF.md ]] || fail "HANDOFF.md held only canon's generated block but was left out of the record: $files"
else [[ "$files" != *HANDOFF.md ]] || fail "a clean HANDOFF.md went into the record: $files"; fi
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
chk="$("$TKT" finish "$id4" --check 2>&1)"; [[ "$chk" != *"also commits canon's merge record"* ]] || fail "--check promises a record commit on another branch: $chk"
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
pushed="$(git show origin/main:".tickets/$id5/ticket.md" 2>/dev/null || true)"
[[ "$pushed" != *"my own note"* ]] || fail "the user's note was pushed"
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

# 8. t-27bc: a tracked, unchanged cockpit-sessions.md is not part of the record, and a ticket.md that a Windows checkout turned into CRLF
# (against HEAD's LF) is still canon's record, not a hand edit
ticket eight; id8="$id"
git checkout -q -- HANDOFF.md   # clean: its generated block is not part of this case
echo "cockpit-sessions: t" > ".tickets/$id8/cockpit-sessions.md"; git add ".tickets/$id8/cockpit-sessions.md"; git commit -qm "track sessions" -- ".tickets/$id8/cockpit-sessions.md"
awk '{ printf "%s\r\n", $0 }' ".tickets/$id8/ticket.md" > "$W/crlf" && cat "$W/crlf" > ".tickets/$id8/ticket.md"
out="$("$TKT" finish "$id8" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$out" != *cockpit-sessions.md* ]] || fail "an unchanged cockpit-sessions.md is named in the record: $out"
[[ "$out" != *HANDOFF.md* ]] || fail "a clean HANDOFF.md is named in the record: $out"
files="$(git show --name-only --format= HEAD | paste -sd, -)"
[[ "$files" == ".tickets/$id8/ticket.md" ]] || fail "the CRLF ticket.md is not the record commit's only file: $files"
tdirty
echo "finish: an unchanged tracked file stays out of the record; a CRLF checkout of canon's ticket.md still counts"

# 8b. t-27bc: canon rewrites a tracked cockpit-sessions.md whole; unlike ticket.md it is canon's record whatever HEAD held. And HANDOFF.md,
# changed only in canon's generated block and checked out with CRLF, is still the record
ticket eightb; id8b="$id"
echo "cockpit-sessions: old" > ".tickets/$id8b/cockpit-sessions.md"; git add ".tickets/$id8b/cockpit-sessions.md"; git commit -qm "track sessions" -- ".tickets/$id8b/cockpit-sessions.md"
echo "cockpit-sessions: new" > ".tickets/$id8b/cockpit-sessions.md"
[[ -n "$(git status --porcelain HANDOFF.md)" ]] || fail "the fixture no longer shows a merge rewriting HANDOFF.md's generated block"
awk '{ printf "%s\r\n", $0 }' HANDOFF.md > "$W/crlf" && cat "$W/crlf" > HANDOFF.md
out="$("$TKT" finish "$id8b" --push --yes 2>&1)" || fail "finish --push failed: $out"
recorded "$id8b" ".tickets/$id8b/cockpit-sessions.md,.tickets/$id8b/ticket.md,HANDOFF.md"
tdirty
echo "finish: a rewritten tracked cockpit-sessions.md and a CRLF HANDOFF.md (generated block only) are both the record"

# 9. t-27bc: a tracked cockpit-sessions.md the user deleted is the user's change, not the record: it stays deleted in the tree, uncommitted
ticket nine; id9="$id"
echo "cockpit-sessions: n" > ".tickets/$id9/cockpit-sessions.md"; git add ".tickets/$id9/cockpit-sessions.md"; git commit -qm "track sessions" -- ".tickets/$id9/cockpit-sessions.md"
rm ".tickets/$id9/cockpit-sessions.md"
out="$("$TKT" finish "$id9" --push --yes 2>&1)" || fail "finish --push failed: $out"
[[ "$(git show --name-only --format= HEAD | grep -c cockpit-sessions.md || true)" == 0 ]] || fail "a deleted file was committed as canon's record"
assert_contains "$(git status --porcelain)" " D .tickets/$id9/cockpit-sessions.md"
tdirty
echo "finish: a file the user deleted is not committed as the record"

# 10. t-27bc: a symlink standing in for a record file (cockpit-sessions.md, HANDOFF.md) is never committed
ticket ten; id10="$id"
echo "cockpit-sessions: l" > "$W/elsewhere.md"; ln -s "$W/elsewhere.md" ".tickets/$id10/cockpit-sessions.md"
cp HANDOFF.md "$W/handoff-copy.md"; rm HANDOFF.md; ln -s "$W/handoff-copy.md" HANDOFF.md
out="$("$TKT" finish "$id10" --push --yes 2>&1)" || fail "finish --push failed: $out"
files="$(git show --name-only --format= HEAD | paste -sd, -)"
[[ "$files" == ".tickets/$id10/ticket.md" ]] || fail "a symlink went into the record commit: $files"
[[ -L HANDOFF.md ]] || fail "the user's HANDOFF.md symlink was replaced"
rm HANDOFF.md; git checkout -q -- HANDOFF.md; tdirty
echo "finish: a symlinked record file is never committed"

# 11. t-27bc: the record is committed with the user's git identity when both name and email are set, with canon's when either is missing
for variant in both name-only none; do
  ticket "id-$variant"; idv="$id"
  : > "$W/gc"; printf '[user]\n\tuseConfigOnly = true\n' >> "$W/gc"
  case "$variant" in both) printf '\tname = Real Person\n\temail = real@example.com\n' >> "$W/gc" ;; name-only) printf '\tname = Real Person\n' >> "$W/gc" ;; esac
  out="$(GIT_CONFIG_GLOBAL="$W/gc" GIT_CONFIG_NOSYSTEM=1 "$TKT" finish "$idv" --push --yes 2>&1)" || fail "$variant: finish --push failed: $out"
  assert_contains "$out" "committed canon's merge record for $idv"
  want=canon; [[ "$variant" == both ]] && want="Real Person"
  [[ "$(git log -1 --format=%an)" == "$want" ]] || fail "$variant: the record's author is $(git log -1 --format=%an), not $want"
done
echo "finish: the record uses the user's identity when complete, canon's otherwise"

# 12. t-27bc: a record commit that fails (a pre-commit hook says no) names it, leaves nothing staged by canon, and the push still goes out
ticket twelve; id12="$id"
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
out="$("$TKT" finish "$id12" --push --yes 2>&1)" || { rm -f .git/hooks/pre-commit; fail "a failing record commit must not stop the push: $out"; }
rm -f .git/hooks/pre-commit
assert_contains "$out" "could not commit canon's merge record"; assert_contains "$out" "finish: pushed main to origin"
[[ -z "$(git diff --cached --name-only)" ]] || fail "canon left files staged after a failed record commit: $(git diff --cached --name-only)"
assert_contains "$(git status --porcelain)" " M .tickets/$id12/ticket.md"
tdirty
echo "finish: a failed record commit is named, leaves nothing staged, and does not stop the push"
echo "tkt-finish-record: ok"
