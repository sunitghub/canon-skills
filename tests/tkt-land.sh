#!/usr/bin/env bash
# t-c259: tkt land closes an imported cloud ticket here (the `tkt land` command, and the board's Continue here button that runs it).
# Prepare: a linked worktree on land/<id> at the PR head, the ticket started and bound to it. --finish: only after a closed
# ticket with a passing verdict graded on that worktree's head; it unbinds and removes worktree and branch. Every refusal changes nothing.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

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
  "pr view") printf '%s\t%s\t%s\n' "${STUB_STATE:-OPEN}" "${STUB_HEAD:?}" "${STUB_CROSS:-false}" ;;
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
[[ "$(git -C "$WT" rev-parse HEAD)" == "$PRHEAD" ]] || fail "worktree is not at the PR head"
[[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" == "land/$id" ]] || fail "worktree is not on land/$id"
grep -q '^status: in_progress' "$f" || fail "ticket not in_progress"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$WT" ]] || fail ".cockpit-cwd is not the worktree"
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
"$TKT" land "$id" < /dev/null >/dev/null 2>&1 || fail "second land failed"
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
out="$("$TKT" land "$id" --fix < /dev/null 2>&1)"; assert_contains "$out" "worktree: $WT"; assert_contains "$out" "push them to the PR branch yourself"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$PRHEAD" ]] || fail "--fix worktree is not at the PR head"
grep -q '^status: in_progress' "$f" || fail "--fix did not reopen the closed ticket"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$WT" ]] || fail "--fix: .cockpit-cwd is not the worktree"
refuses "a plain land of an in_progress ticket" "not open" --
refuses "--fix on a ticket already in progress" "not open" -- --fix
echo "tkt land: ok"
