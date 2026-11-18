#!/usr/bin/env bash
# t-c259: tkt land closes an imported cloud ticket here (the `tkt land` command, and the board's Continue here button that runs it).
# Prepare: a linked worktree on land/<id> at the PR head, the ticket started and bound to it. --finish: only after a closed
# ticket with a passing verdict graded on that worktree's head; it unbinds and removes worktree and branch. Every refusal changes nothing.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
unset CANON_TICKETS_DIR   # t-597f: a full-suite stamp sets it; the land case must resolve tickets itself (manual-qa honours it)

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tkt-land.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com
git init -q --bare "$W/origin.git"
git config --global url."$W/origin.git".pushInsteadOf https://github.com/acme/app.git

P="$W/project"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
git remote set-url origin https://github.com/acme/app.git
printf '.tickets/\n' > .gitignore; echo base > f.txt; git add -A; git commit -qm base; git push -q origin HEAD:main
git checkout -q -b claude/pr7; echo change > f.txt; git add f.txt; git commit -qm "the PR"; PRHEAD="$(git rev-parse HEAD)"
git push -q origin "HEAD:refs/pull/7/head"; git checkout -q main

id="$("$TKT" create "Cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"
awk '/^---$/ && ++n == 2 { print "github: acme/app#21" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"
WT="$W/project-worktrees/land-$id"; echo plan > ".tickets/$id/plan.md"

mkdir "$W/bin"; cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "pr list") cat "$STUB_W/prlist" ;;
  "pr view") printf '%s\t%s\t%s\t%s\t%s\n' "${STUB_STATE:-OPEN}" "${STUB_HEAD:?}" "${STUB_CROSS:-false}" "${STUB_MG:-MERGEABLE}" main ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$W/bin/gh"
REAL_GIT="$(command -v git)"
cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" fetch "* ]]; then a=(); for x in "\$@"; do [[ "\$x" == origin ]] && x="$W/origin.git"; a+=("\$x"); done; set -- "\${a[@]}"; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/bin/git"
export PATH="$W/bin:$PATH" STUB_LOG="$W/gh.log" STUB_W="$W" STUB_HEAD="$PRHEAD"
echo 7 > "$W/prlist"
sig() { { cksum < "$f"; ls "$W/project-worktrees" 2>&1; git branch --list 'land/*'; } | cksum; }

# refuses <label> <message> [env...] -- <args...>: exit 1, the message, and ticket, worktrees and branches unchanged.
refuses() {
  local label="$1" part="$2"; shift 2; local envs=(); while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  local before rc=0; before="$(sig)"
  out="$(env ${envs[@]+"${envs[@]}"} "$TKT" land "$id" "$@" < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "land should refuse $label (rc $rc): $out"
  assert_contains "$out" "$part"
  [[ "$(sig)" == "$before" ]] || fail "land changed state although it refused $label"
  echo "land: refused $label"
}

refuses "a PR from a fork" "comes from a fork" STUB_CROSS=true --
refuses "a closed PR" "is CLOSED, not open" STUB_STATE=CLOSED --
: > "$W/prlist"; refuses "no open PR" "no open PR says" --; echo 7 > "$W/prlist"
refuses "finish before prepare" "is not bound" -- --finish
printf 'graded-head: %s\npass: all met\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
refuses "a PR head that already has a verdict" "nothing to close here" --
rm ".tickets/$id/eval-report.md"
"$TKT" start "$id" >/dev/null
refuses "a ticket that is not open" "not open" --
"$TKT" close "$id" --no-sprint >/dev/null 2>&1 || sed -i.bak 's/^status: .*/status: closed/' "$f"; rm -f "$f.bak"   # t-75f5: closed, not merely started
refuses "a closed ticket without --fix" "tkt land $id --pr <N> --fix" --
refuses "a closed ticket without --fix, PR named" "tkt land $id --pr 7 --fix" -- --pr 7
sed -i.bak 's/^status: .*/status: in_progress/' "$f"; rm -f "$f.bak"
refuses "an in-progress ticket" "import its results first (tkt import-results $id)" --
[[ "$out" != *"--fix"* ]] || fail "the --fix hint is only for a closed ticket: $out"
"$TKT" reopen "$id" >/dev/null 2>&1 || sed -i.bak 's/^status: .*/status: open/' "$f"
grep -q '^status: open' "$f" || fail "test setup: ticket not reopened"

# Prepare.
out="$("$TKT" land "$id" < /dev/null 2>&1)"; assert_contains "$out" "worktree: $WT"; assert_contains "$out" "sprint complete $id, then: tkt land $id --finish"
[[ "$out" != *"push them to the PR branch yourself"* ]] || fail "plain land printed the --fix hint: $out"   # the hint is for --fix only
# t-fff4: what a test run in the worktree lacks: .tickets/ is gitignored here, so the worktree has none; no node_modules anywhere, no line
assert_contains "$out" "  tests: CANON_TICKETS_DIR='$P/.tickets' (the worktree has no .tickets/)"
[[ "$out" != *"node_modules"* ]] || fail "land named a node_modules the main checkout does not have: $out"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$PRHEAD" ]] || fail "worktree is not at the PR head"
[[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" == "land/$id" ]] || fail "worktree is not on land/$id"
grep -q '^status: in_progress' "$f" || fail "ticket not in_progress"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$WT" ]] || fail ".cockpit-cwd is not the worktree"
# t-74d8: the close runs here, so its gates need canon's agents (and the skills) in this worktree
[[ "$(cd "$WT/.claude/agents" 2>/dev/null && pwd -P)" == "$(cd "$ROOT/agents" && pwd -P)" ]] || fail "land worktree's .claude/agents does not reach canon's agents"
[[ -f "$WT/.claude/skills/sprint/SKILL.md" ]] || fail "land worktree has no .claude/skills link"
refuses "a second land (ticket already started)" "not open" --

# Finish refusals: ticket not closed; closed with a verdict graded elsewhere; both leave the worktree.
refuses "finish of an unclosed ticket" "is not closed yet" -- --finish
sed -i.bak 's/^status: .*/status: closed/' "$f"
printf 'graded-head: 0123456789abcdef0123456789abcdef01234567\npass: all met\n' > ".tickets/$id/eval-report.md"
refuses "finish with a verdict on another head" "no passing evaluator verdict graded on the worktree head" -- --finish
[[ -d "$WT" ]] || fail "worktree removed although finish refused"
printf 'graded-head: %s\npass: all met\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
echo dirty > "$WT/f.txt"
refuses "finish with uncommitted work in the worktree" "worktree kept" -- --finish
git -C "$WT" checkout -q -- f.txt

# Finish.
out="$("$TKT" land "$id" --finish < /dev/null 2>&1)"; assert_contains "$out" "tkt merge-pr $id"
[[ ! -e "$WT" ]] || fail "worktree still there"
git show-ref --verify --quiet "refs/heads/land/$id" && fail "branch land/$id still there"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$P" ]] || fail ".cockpit-cwd not restored to the earlier binding"
[[ ! -e ".tickets/$id/.cockpit-cwd.before-land" ]] || fail "saved binding left behind"
[[ "$(git ls-remote "$W/origin.git")" != *"land/"* ]] || fail "land pushed a branch"

# Refusals that need their own open ticket: a bad --pr, no way to find the PR, a taken worktree path or branch name.
mk() { id="$("$TKT" create "Cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
  echo plan > ".tickets/$id/plan.md"
  [[ -z "${1:-}" ]] || { awk -v g="$1" '/^---$/ && ++n == 2 { print "github: " g } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; }; }
mk acme/app#23; refuses "a --pr that is not a number" "takes a PR number" -- --pr 5x
mk;             refuses "a ticket with no github line" "was not imported" -- --pr 7
mk acme/app#23; rm ".tickets/$id/plan.md"; refuses "a ticket whose results were not imported" "tkt import-results" -- --pr 7
out="$("$TKT" land t-zzzz < /dev/null 2>&1)" && fail "land accepted an unknown ticket"; assert_contains "$out" "t-zzzz"
mk other/repo#5; refuses "a github line for another repo" "line to find its PR by" --
mk acme/app#23; printf '7\n8\n' > "$W/prlist"; refuses "several open PRs" "several open PRs" --; echo 7 > "$W/prlist"
refuses "a PR that moved while fetching" "moved while fetching" STUB_HEAD=0123456789abcdef0123456789abcdef01234567 --
refuses "a PR ref origin does not have" "could not fetch PR #99" -- --pr 99
mkdir -p "$WT"; refuses "a taken worktree path" "already exists" --; rmdir "$WT"
git branch "land/$id"; refuses "a taken branch name" "already exists" --; git branch -q -D "land/$id"

# Commits made in the worktree are not on the PR yet: finish removes the worktree but keeps land/<id> (nothing is lost).
id="$("$TKT" create "Second cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
awk '/^---$/ && ++n == 2 { print "github: acme/app#22" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; echo plan > ".tickets/$id/plan.md"
# A failing verdict on the PR head does not stop land: only a passing one does.
printf 'graded-head: %s\nfail: one criterion\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
# t-fff4: silent when the worktree has both: this PR head tracks node_modules/ and .tickets/ (the main checkout has them too)
git checkout -q -B both "$PRHEAD"; mkdir -p node_modules .tickets/keep; echo k > node_modules/k; echo k > .tickets/keep/k
git add -f node_modules/k .tickets/keep/k; git commit -qm "tracks both"; H2="$(git rev-parse HEAD)"; git push -qf origin "HEAD:refs/pull/7/head"
git checkout -q main; mkdir -p "$P/node_modules"
printf 'graded-head: %s\nfail: one criterion\n' "$H2" > ".tickets/$id/eval-report.md"
out="$(STUB_HEAD="$H2" "$TKT" land "$id" < /dev/null 2>&1)" || fail "second land failed: $out"
[[ "$out" != *"node_modules"* ]] || fail "land named what the worktree already has: $out"
# t-597f: this PR head tracks .tickets/, so land keeps it out of the worktree (the main checkout's copy is the one every reader uses)
[[ ! -e "$WT/.tickets" ]] || fail "t-597f: the land worktree has its own .tickets/ from the PR"
assert_contains "$out" "  tests: CANON_TICKETS_DIR='$P/.tickets' (the worktree has no .tickets/)"   # true now: land kept it out
rmdir "$P/node_modules"; git push -qf origin "$PRHEAD:refs/pull/7/head"
echo more > "$WT/g.txt"; git -C "$WT" add g.txt; git -C "$WT" commit -qm "fix found while closing"; NEWHEAD="$(git -C "$WT" rev-parse HEAD)"
sed -i.bak 's/^status: .*/status: closed/' "$f"
printf 'graded-head: %s\nfail: one criterion\n' "$NEWHEAD" > ".tickets/$id/eval-report.md"
refuses "finish with a failing verdict on the worktree head" "no passing evaluator verdict" -- --finish
rm ".tickets/$id/eval-report.md"
refuses "finish with no eval-report.md" "no passing evaluator verdict" -- --finish
printf 'graded-head: %s\npass: all met\n' "$NEWHEAD" > ".tickets/$id/eval-report.md"
out="$("$TKT" land "$id" --finish < /dev/null 2>&1)"; assert_contains "$out" "land/$id kept"
[[ ! -e "$WT" ]] || fail "worktree still there"
[[ "$(git rev-parse "refs/heads/land/$id")" == "$NEWHEAD" ]] || fail "the commit made in the worktree was lost"
[[ ! -e ".tickets/$id/.land-head" ]] || fail ".land-head left behind"
# t-6623 --fix: a Check & merge whose suite failed here leaves a closed ticket whose PR head already has a passing verdict.
id="$("$TKT" create "Closed cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
awk '/^---$/ && ++n == 2 { print "github: acme/app#23" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; echo plan > ".tickets/$id/plan.md"
printf 'graded-head: %s\npass: all met\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
sed -i.bak 's/^status: .*/status: closed/' "$f"; rm -f "$f.bak"
refuses "a closed ticket without --fix" "not open" --
refuses "--fix together with --finish" "use one" -- --fix --finish
sed -i.bak 's/^status: closed/status: closed\nmerged: abc123/' "$f"; rm -f "$f.bak"
refuses "--fix on a merged ticket" "already merged" -- --fix
sed -i.bak '/^merged: /d' "$f"; rm -f "$f.bak"
mkdir "$P/node_modules"   # t-fff4: now the main checkout has node_modules (gitignored in a real project) and the worktree will not
out="$("$TKT" land "$id" --fix < /dev/null 2>&1)"; assert_contains "$out" "worktree: $WT"; assert_contains "$out" "push them to the PR branch yourself"
assert_contains "$out" "  tests: ln -s '$P/node_modules' '$WT/node_modules'"; rmdir "$P/node_modules"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$PRHEAD" ]] || fail "--fix worktree is not at the PR head"
grep -q '^status: in_progress' "$f" || fail "--fix did not reopen the closed ticket"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$WT" ]] || fail "--fix: .cockpit-cwd is not the worktree"
refuses "a plain land of an in_progress ticket" "not open" --
refuses "--fix on a ticket already in progress" "not open" -- --fix
# t-ca00: protects `tkt land --fix` (the board's Fix here on a conflicting PR): the next line says to merge the base in first.
id="$("$TKT" create "Conflicting cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
awk '/^---$/ && ++n == 2 { print "github: acme/app#24" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; echo plan > ".tickets/$id/plan.md"
out="$(STUB_MG=CONFLICTING "$TKT" land "$id" --fix < /dev/null 2>&1)"
assert_contains "$out" "next: in that worktree run git merge origin/main, resolve the conflicting files, then run the evaluator and sprint complete $id, then: tkt land $id --finish"
echo "land: a conflicting PR's next step says to merge the base first (t-ca00)"
# t-92f2: protects `tkt land --finish` (the card's Finish) after a fix here was pushed to the PR branch: the worktree head is the
# PR's current head on origin, so land/<id> holds nothing the PR lacks and goes; an unreadable PR ref keeps it.
finish_after_push() {   # <issue> <.land-pr override or ""> -> sets id, WT, NEWHEAD, out
  id="$("$TKT" create "Pushed fix $1" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
  awk -v gh="github: acme/app#$1" '/^---$/ && ++n == 2 { print gh } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; echo plan > ".tickets/$id/plan.md"
  git push -q -f "$W/origin.git" "$PRHEAD:refs/pull/8/head"; echo 8 > "$W/prlist"
  "$TKT" land "$id" < /dev/null >/dev/null 2>&1 || fail "land for the pushed-fix case failed"
  [[ "$(tr -d '[:space:]' < ".tickets/$id/.land-pr")" == 8 ]] || fail ".land-pr does not record PR 8"
  echo "fix $1" > "$WT/h.txt"; git -C "$WT" add h.txt; git -C "$WT" commit -qm "conflict fix"; NEWHEAD="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" push -q -f "$W/origin.git" "HEAD:refs/pull/8/head"
  [[ -z "$2" ]] || echo "$2" > ".tickets/$id/.land-pr"
  sed -i.bak 's/^status: .*/status: closed/' "$f"; rm -f "$f.bak"
  printf 'graded-head: %s\npass: all met\n' "$NEWHEAD" > ".tickets/$id/eval-report.md"
  out="$("$TKT" land "$id" --finish < /dev/null 2>&1)" || fail "finish failed: $out"
  [[ ! -e "$WT" ]] || fail "worktree still there"
  [[ ! -e ".tickets/$id/.land-pr" ]] || fail ".land-pr left behind"
}
finish_after_push 25 ""
! git show-ref --verify --quiet "refs/heads/land/$id" || fail "land/$id kept although its head is the PR's current head: $out"
[[ "$out" != *kept* ]] || fail "finish says kept: $out"
echo "land: finish deletes land/<id> when its head was pushed to the PR (t-92f2)"
finish_after_push 26 99
[[ "$(git rev-parse "refs/heads/land/$id")" == "$NEWHEAD" ]] || fail "land/$id deleted although the PR ref could not be read"
assert_contains "$out" "could not fetch PR #99"
echo "land: finish keeps land/<id> when the PR ref cannot be read (t-92f2)"
# Nothing committed here, but the PR moved on origin after land (another push): the head is still the one land started from
# (.land-head), so the branch holds nothing new and goes.
id="$("$TKT" create "PR moved after land" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
awk '/^---$/ && ++n == 2 { print "github: acme/app#27" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; echo plan > ".tickets/$id/plan.md"
git push -q -f "$W/origin.git" "$PRHEAD:refs/pull/8/head"
"$TKT" land "$id" < /dev/null >/dev/null 2>&1 || fail "land for the moved-PR case failed"
git -C "$WT" commit -q --allow-empty -m "someone else's push"; git -C "$WT" push -q -f "$W/origin.git" "HEAD:refs/pull/8/head"; git -C "$WT" reset -q --hard "$PRHEAD"
sed -i.bak 's/^status: .*/status: closed/' "$f"; rm -f "$f.bak"
printf 'graded-head: %s\npass: all met\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
out="$("$TKT" land "$id" --finish < /dev/null 2>&1)" || fail "finish failed: $out"
! git show-ref --verify --quiet "refs/heads/land/$id" || fail "land/$id kept although its head is the one land started from: $out"
echo "land: finish deletes land/<id> at its start head even when the PR moved (t-92f2)"
# t-597f: protects `tkt land` / the card's Continue here, Resume and Finish in a project that commits .tickets/ (the user's ToDo-Demo):
# the PR head carries the cloud's closed copy of the ticket. The land worktree must have no .tickets/ of its own, stay clean, and leave
# every read and write to the main checkout, so the close there ends in a plain --finish with no manual step.
id="$("$TKT" create "Tracked tickets" -t bug)"; f=".tickets/$id/ticket.md"; WT="$W/project-worktrees/land-$id"
awk '/^---$/ && ++n == 2 { print "github: acme/app#28" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"; echo plan > ".tickets/$id/plan.md"
# the PR head: the earlier PR plus the cloud's closed copy of this ticket, committed (built in a scratch index: .tickets/ is gitignored here)
printf -- '---\nid: %s\nstatus: closed\n---\n# the cloud copy\n' "$id" > "$W/cloudcopy"
GIT_INDEX_FILE="$W/idx" git read-tree "$PRHEAD"; blob="$(git hash-object -w "$W/cloudcopy")"
GIT_INDEX_FILE="$W/idx" git update-index --add --cacheinfo "100644,$blob,.tickets/$id/ticket.md"
GIT_INDEX_FILE="$W/idx" git update-index --add --cacheinfo "100644,$(echo '# Learnings' | git hash-object -w --stdin),LEARNINGS.md"   # t-8bd8: a tracked close doc
TH="$(git commit-tree "$(GIT_INDEX_FILE="$W/idx" git write-tree)" -p "$PRHEAD" -m "cloud close commits its ticket")"
git push -qf origin "$TH:refs/pull/9/head"; echo 9 > "$W/prlist"
sparse_main="$(git config --get core.sparseCheckout || echo off)"
# A git that refuses sparse-checkout: land says so and leaves nothing behind.
cat > "$W/bin/git-sparse-fail" <<SH
#!/usr/bin/env bash
[[ " \$* " == *" sparse-checkout "* ]] && { echo "sparse not supported here" >&2; exit 128; }
exec "$W/bin/git.real" "\$@"
SH
cp "$W/bin/git" "$W/bin/git.real"; cp "$W/bin/git-sparse-fail" "$W/bin/git"; chmod +x "$W/bin/git"
refuses "a git that cannot set sparse-checkout" "sparse not supported here" STUB_HEAD="$TH" --
mv "$W/bin/git.real" "$W/bin/git"
# t-edda: protects Continue here on Windows. Git Bash converts an argument that looks like an absolute path before calling git.exe:
# it turned `!/.tickets/` into `!C:/Program Files/Git/.tickets/` (keeps nothing out) and left the glob `/*` alone. The stub does the
# same to `sparse-checkout set`'s pattern operands only (never -C's path), unless MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL is set,
# as MSYS does; with MSYS_ALWAYS=1 it converts regardless (a git that stores something else: the read-back must refuse).
cat > "$W/bin/git-msys" <<SH
#!/usr/bin/env bash
a=(); set_seen=false
for x in "\$@"; do
  if \$set_seen && [[ "\$x" != -* && "\$x" != *'*'* && ( "\$x" == /* || "\$x" == '!/'* ) ]] \\
     && { [[ -n "\${MSYS_ALWAYS:-}" ]] || [[ -z "\${MSYS_NO_PATHCONV:-}" && -z "\${MSYS2_ARG_CONV_EXCL:-}" ]]; }; then
    if [[ "\$x" == '!'* ]]; then x="!C:/Program Files/Git\${x#!}"; else x="C:/Program Files/Git\$x"; fi
  fi
  [[ "\$x" == set && " \${a[*]} " == *" sparse-checkout "* ]] && set_seen=true
  a+=("\$x")
done
exec "$W/bin/git.real" "\${a[@]}"
SH
cp "$W/bin/git" "$W/bin/git.real"; cp "$W/bin/git-msys" "$W/bin/git"; chmod +x "$W/bin/git"
refuses "a git that stores a converted .tickets pattern (t-edda)" "git stored /*, !C:/Program Files/Git/.tickets/, not /*, !/.tickets/" MSYS_ALWAYS=1 STUB_HEAD="$TH" --
[[ ! -e "$WT" && -z "$(git branch --list "land/$id")" ]] || fail "t-edda: a refused land left its worktree or branch"
out="$(STUB_HEAD="$TH" "$TKT" land "$id" < /dev/null 2>&1)" || fail "t-597f: land of a PR that tracks .tickets failed: $out"
mv "$W/bin/git.real" "$W/bin/git"
assert_eq $'/*\n!/.tickets/' "$(git -C "$WT" sparse-checkout list)"   # t-edda: under the converting stub, land asked git without conversion
[[ ! -e "$WT/.tickets" ]] || fail "t-597f: the land worktree has its own .tickets/"
[[ -z "$(git -C "$WT" status --short)" ]] || fail "t-597f: the land worktree is not clean: $(git -C "$WT" status --short)"
[[ "$(git config --get core.sparseCheckout || echo off)" == "$sparse_main" ]] || fail "t-597f: sparse-checkout leaked into the main checkout"
[[ -f "$WT/f.txt" ]] || fail "t-597f: the sparse worktree lost a code file"
assert_contains "$(cd "$WT" && "$TKT" show "$id")" "in_progress"
[[ "$(cd "$WT" && "$SPRINT" current 2>/dev/null)" == *"$id"* ]] || fail "t-597f: sprint current from the worktree does not name $id"
(cd "$WT" && "$SPRINT" subagent-log --agent-id t597f-probe --agent-type evaluator --ticket "$id" >/dev/null 2>&1) || fail "t-597f: subagent-log failed in the worktree"
grep -q t597f-probe "$P/.claude/subagent-runs.jsonl" || fail "t-597f: subagent-log did not write the main checkout's log"
(cd "$WT" && "$SPRINT" manual-qa "$id" --by tester --step "probe|pass" >/dev/null 2>&1) || fail "t-597f: manual-qa failed in the worktree"
[[ -f "$P/.tickets/$id/evidence/manual-qa.md" ]] || fail "t-597f: manual-qa did not write the main checkout's ticket"
[[ ! -e "$WT/.tickets" && ! -e "$WT/.claude/subagent-runs.jsonl" ]] || fail "t-597f: a write landed in the worktree"
# t-8bd8: protects the close's gate dispatch, sprint complete and the card's Finish in a land worktree: the close docs (the DECISIONS.md
# row, the learnings row, a HANDOFF note) belong in the main checkout. gate-snapshot pre says where; sprint complete and --finish refuse
# one written in the worktree, naming it (a tracked edit stopped git's remove; an ignored one, like canon's DECISIONS.md, was deleted).
echo '# Acceptance' > ".tickets/$id/acceptance.md"   # gate-snapshot pre digests it (a real ticket always has one)
out="$(cd "$WT" && "$SPRINT" gate-snapshot pre "$P/.tickets/$id/gate-snapshot.txt" --role reviewer 2>&1)" || fail "t-8bd8: gate-snapshot pre failed: $out"
assert_contains "$out" "this is a land worktree: write the close's DECISIONS.md row, LEARNINGS.md row and any HANDOFF.md note in $P/"
(cd "$WT" && "$SPRINT" gate-snapshot post "$P/.tickets/$id/gate-snapshot.txt" >/dev/null 2>&1) || true; rm -f "$P/.tickets/$id/gate-snapshot.txt"*
rc=0; out="$("$SPRINT" gate-snapshot pre "$W/gs-main.txt" --role reviewer 2>&1)" || rc=$?; "$SPRINT" gate-snapshot post "$W/gs-main.txt" >/dev/null 2>&1 || true
[[ "$rc" == 0 ]] || fail "t-8bd8: gate-snapshot pre in the main checkout exited $rc: $out"
assert_contains "$out" "gate-snapshot: pre recorded"; [[ "$out" != *"land worktree"* ]] || fail "t-8bd8: gate-snapshot named a land worktree in the main checkout: $out"
echo "DECISIONS.md" >> "$P/.git/info/exclude"   # ignored, as in canon
echo "| row |" >> "$WT/LEARNINGS.md"; echo "| 2026-11-18 | row |" > "$WT/DECISIONS.md"; echo note > "$WT/HANDOFF.md"
rc=0; out="$(cd "$WT" && "$SPRINT" complete 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "t-8bd8: sprint complete closed with close docs in the land worktree (rc $rc): $out"
assert_contains "$out" "this land worktree has close docs that belong in the main checkout, $P:"
[[ "$(printf '%s\n' "$out" | tail -1)" == "  move each change into the main checkout's copy, undo it here"* ]] || fail "t-8bd8: sprint complete went past the guard: $out"
assert_contains "$out" "  LEARNINGS.md"; assert_contains "$out" "  DECISIONS.md"; assert_contains "$out" "  HANDOFF.md"
assert_grep '^status: in_progress$' "$f"
sed -i.bak 's/^status: .*/status: closed/' "$f"; rm -f "$f.bak"
printf 'graded-head: %s\npass: all met\n' "$TH" > ".tickets/$id/eval-report.md"
# t-edda: a worktree whose pattern was converted before this fix (the VM's) holds the PR's tracked .tickets/, and a ticket file there was
# edited: sprint complete, gate-snapshot post and --finish each name the repair, and nothing is closed or removed.
git -C "$WT" sparse-checkout set --no-cone '/*' '!C:/Program Files/Git/.tickets/'
[[ -f "$WT/.tickets/$id/ticket.md" ]] || fail "t-edda: the converted pattern did not bring the PR's .tickets/ back (the fixture is wrong)"
echo "edited in the worktree" >> "$WT/.tickets/$id/ticket.md"
rc=0; out="$(cd "$WT" && "$SPRINT" complete 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "t-edda: sprint complete went on in a converted land worktree (rc $rc): $out"
assert_contains "$out" "sparse-checkout pattern is wrong (!C:/Program Files/Git/.tickets/"; assert_contains "$out" 'sparse-checkout set --no-cone "/*" "!/.tickets/"'
rc=0; out="$(cd "$WT" && "$SPRINT" gate-snapshot post "$W/gs-none.txt" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "t-edda: gate-snapshot post went on (rc $rc): $out"; assert_contains "$out" "sparse-checkout pattern is wrong"
refuses "a land worktree whose .tickets pattern was converted (t-edda)" "sparse-checkout pattern is wrong (!C:/Program Files/Git/.tickets/" -- --finish
assert_contains "$out" "worktree kept"
git -C "$WT" checkout -q -- ".tickets/$id/ticket.md"; git -C "$WT" sparse-checkout set --no-cone '/*' '!/.tickets/'   # the repair the line names
[[ ! -e "$WT/.tickets" ]] || fail "t-edda: the repair left .tickets/ in the worktree"
echo "land: a converted .tickets pattern is refused at land, and an existing one is named with its repair (t-edda)"
refuses "close docs left in the land worktree" "has close docs that belong in the main checkout ($P): " -- --finish
assert_contains "$out" "DECISIONS.md"; assert_contains "$out" "LEARNINGS.md"; assert_contains "$out" "worktree kept"
[[ -f "$WT/DECISIONS.md" && -n "$(git branch --list "land/$id")" ]] || fail "t-8bd8: a refused finish lost the row or the branch"
git -C "$WT" checkout -q -- LEARNINGS.md; rm -f "$WT/HANDOFF.md"
# the ignored row alone (the case git's own remove deleted silently) is refused too
refuses "an ignored close doc alone in the land worktree" "($P): DECISIONS.md" -- --finish
rm -f "$WT/DECISIONS.md"
# a clean land worktree passes the guard (the close goes on to its own gates), and the helper answers only for a land worktree
out="$(cd "$WT" && "$SPRINT" complete 2>&1)" || true; [[ "$out" != *"close docs"* ]] || fail "t-8bd8: a clean land worktree was refused: $out"
( source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/ticket-root.sh"
  rc=0; o="$(land_close_docs "$WT")" || rc=$?; [[ "$rc" == 0 && -z "$o" ]] || fail "t-8bd8: a clean land worktree: rc $rc, '$o'"
  echo row > "$P/DECISIONS.md"; rc=0; land_close_docs "$P" >/dev/null || rc=$?; [[ "$rc" == 1 ]] || fail "t-8bd8: the main checkout counted as a land worktree"
  git -C "$P" worktree add -q -b feat/x "$W/wt-feat" main; echo row > "$W/wt-feat/DECISIONS.md"
  rc=0; land_close_docs "$W/wt-feat" >/dev/null || rc=$?; [[ "$rc" == 1 ]] || fail "t-8bd8: a normal worktree counted as a land worktree"
  git -C "$P" worktree add -q -b land/t-zz99 "$W/wt-land" main; echo row > "$W/wt-land/DECISIONS.md"   # not sparse: the branch decides
  [[ "$(land_close_docs "$W/wt-land")" == DECISIONS.md ]] || fail "t-8bd8: a land/* worktree without sparse-checkout was missed"
  git -C "$W/wt-feat" sparse-checkout set --no-cone '/*' '!/.tickets/' 2>/dev/null   # sparse, another branch name: the sparse rule decides
  [[ "$(land_close_docs "$W/wt-feat")" == DECISIONS.md ]] || fail "t-8bd8: a sparse land worktree on another branch was missed"
  rm -f "$P/DECISIONS.md"; git -C "$P" worktree remove --force "$W/wt-feat"; git -C "$P" worktree remove --force "$W/wt-land"; git -C "$P" branch -q -D feat/x land/t-zz99 )
echo "land: close docs in the land worktree are named by gate-snapshot, refused by sprint complete and --finish (t-8bd8)"
out="$("$TKT" land "$id" --finish < /dev/null 2>&1)" || fail "t-597f: finish failed: $out"
[[ ! -e "$WT" ]] || fail "t-597f: worktree still there"
echo "land: a PR that tracks .tickets/ gives a worktree with none, every read and write in main, and a plain finish (t-597f)"
echo "tkt land: ok"
