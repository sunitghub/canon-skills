#!/usr/bin/env bash
# t-32f9: tkt commit-push commits exactly the files named (from its own --dry-run list) in the ticket's checkout and pushes the
# branch to origin, never forced. Protects `tkt commit-push` and the board's Send panel "Commit and push" that runs it after its
# confirm. Every refusal changes nothing: same HEAD, same index, same working tree, origin untouched.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tkt-commit-push.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com
git init -q --bare "$W/origin.git"

# A git shim logs every push, so the test can prove none is ever forced.
REAL_GIT="$(command -v git)"; mkdir -p "$W/bin"
cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == push ]] && { printf '%s\n' "\$*" >> "$W/pushes"; break; }; done
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/bin/git"; export PATH="$W/bin:$PATH"; : > "$W/pushes"

P="$W/project"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
echo base > a.txt; echo base > b.txt; git add -A; git commit -qm base; git push -q origin HEAD:main; git branch -q -u origin/main
id="$("$TKT" create "Cloud ticket" -t task)"; other="$("$TKT" create "Other ticket" -t task)"
git add -f .tickets; git commit -qm tickets; git push -q origin HEAD:main
sig() { printf '%s|%s|%s|%s\n' "$(git rev-parse HEAD)" "$(git ls-files -s | cksum)" "$(git status --porcelain=v1 -uall | cksum)" "$(git --git-dir="$W/origin.git" rev-parse main)"; }

# Changes: a tracked edit, a staged edit (not to be committed), two untracked files in a folder, this ticket's file, another's.
echo edited > a.txt; echo staged > b.txt; git add b.txt; mkdir -p newdir; echo n1 > newdir/one.txt; echo n2 > newdir/two.txt
echo note >> ".tickets/$id/ticket.md"; echo note >> ".tickets/$other/ticket.md"
before="$(sig)"
out="$("$TKT" commit-push "$id" --dry-run)"
assert_contains "$out" "branch: main -> origin/main (0 commit(s) to push)"
for l in "file:  M a.txt" "file: M  b.txt" "file: ?? newdir/one.txt" "file: ?? newdir/two.txt" "file:  M .tickets/$id/ticket.md"; do
  grep -qxF -- "$l" <<< "$out" || fail "the dry run lacks the line '$l': $out"
done
[[ "$out" != *".tickets/$other/"* ]] || fail "the dry run listed another ticket's file: $out"
assert_eq "$before" "$(sig)"

# t-3741: each listed file also gets "mtime: <epoch seconds> <path>" (what the board's form reads to leave a file changed moments ago
# unticked); the file: lines above are unchanged.
touch -t 202001020304.00 a.txt; out="$("$TKT" commit-push "$id" --dry-run)"
want="$(date -j -f '%Y%m%d%H%M%S' 20200102030400 +%s 2>/dev/null || date -d '2020-01-02 03:04:00' +%s)"
grep -qxF "mtime: $want a.txt" <<< "$out" || fail "the dry run lacks a.txt's mtime ($want): $out"
grep -qE '^mtime: [0-9]+ newdir/one.txt$' <<< "$out" || fail "an untracked file has no mtime line: $out"
assert_eq "$before" "$(sig)"

# Refusals: each changes nothing.
refuses() {   # refuses <message part> <args...>
  local part="$1"; shift; local rc=0 b; b="$(sig)"
  out="$("$TKT" commit-push "$id" "$@" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "commit-push $* should exit 1 (got $rc): $out"
  assert_contains "$out" "$part"; assert_eq "$b" "$(sig)"
}
refuses "is not one of this checkout's changes" --file "../outside.txt" --message "chore: x"
refuses "is not one of this checkout's changes" --file ".tickets/$other/ticket.md" --message "chore: x"
refuses "refused file name '-x' (empty, or starts with -)" --file "-x" --message "chore: x"
refuses "a commit needs --message" --file a.txt
refuses "a commit needs --message" --file a.txt --message ""
refuses "one line of at most 200 characters" --file a.txt --message "$(head -c 201 /dev/zero | tr '\0' x)"
refuses "one line of at most 200 characters" --file a.txt --message $'two\nlines'
refuses "nothing to commit (no --file) and nothing to push"
refuses "refused file name '' (empty, or starts with -)" --file "" --message "chore: x"
refuses "one line of at most 200 characters" --file a.txt --message $'cr\rhere'
for args in "--file" "--message"; do refuses "needs a" $args; done
refuses "Unknown option: --bogus" --bogus
rc=0; out="$("$TKT" commit-push 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "Usage: tkt commit-push <id>"
# What the list leaves out: a name with a tab, canon's own skill links; a staged rename is one line, its new name.
touch "$(printf 'tab\tname')"; mkdir -p .claude/skills/x && touch .claude/skills/x/SKILL.md
git mv a.txt a2.txt; out="$("$TKT" commit-push "$id" --dry-run)"
grep -qxF "file: RM a2.txt" <<< "$out" || fail "a staged rename is not one line under its new name: $out"
while IFS= read -r l; do [[ -e "${l:9}" ]] || fail "the dry run listed a path that is not here (a rename's source read as an entry?): '$l'"; done < <(grep '^file: ' <<< "$out")
[[ "$out" != *" a.txt"* && "$out" != *tab* && "$out" != *".claude/skills"* ]] || fail "the dry run listed a rename's old name, a tab name or a skill link: $out"
git mv a2.txt a.txt; rm -rf "$(printf 'tab\tname')" .claude; before="$(sig)"
# No origin, or one that cannot be reached: refused, nothing changed.
git remote rename origin up; refuses "this project has no origin remote" --file a.txt --message "chore: x"; git remote rename up origin
git remote set-url origin "$W/nowhere.git"; refuses "could not reach origin" --file a.txt --message "chore: x"; git remote set-url origin "$W/origin.git"
# A commit hook that refuses: nothing pushed, the reason and the staged state said.
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
rc=0; out="$("$TKT" commit-push "$id" --file a.txt --message "chore: x" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "git could not commit (a hook may have refused it); nothing pushed. The files are staged"
assert_eq "$(git --git-dir="$W/origin.git" rev-parse main)" "$(git rev-parse HEAD)"; rm .git/hooks/pre-commit; git reset -q -- a.txt

# Commit two of the files: exactly those land, the staged b.txt stays staged and out of the commit; the push is plain.
msg200="chore: $id $(head -c 220 /dev/zero | tr '\0' w)"; msg200="${msg200:0:200}"; [[ ${#msg200} == 200 ]] || fail "test setup: message is ${#msg200} long"
out="$("$TKT" commit-push "$id" --file a.txt --file newdir/one.txt --message "$msg200")"   # 200 characters: the limit, allowed
[[ "$out" =~ commit-push:\ committed\ [0-9a-f]{8}\ \(2\ file\(s\)\):\  ]] || fail "the commit line does not name the commit: $out"; assert_contains "$out" "(2 file(s)): $msg200"
assert_contains "$out" "commit-push: pushed main to origin"; assert_contains "$out" "  to undo: git revert "
assert_eq "a.txt newdir/one.txt" "$(git show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"
assert_eq "M  b.txt" "$(git status --porcelain=v1 -- b.txt)"; assert_eq "?? newdir/two.txt" "$(git status --porcelain=v1 -uall -- newdir)"

# A file named like a pattern is that one file: '*.txt' commits only itself, never every .txt here.
echo star > '*.txt'; echo plain > plain.txt
out="$("$TKT" commit-push "$id" --file '*.txt' --message "chore: star")"; assert_contains "$out" "(1 file(s)): chore: star"
assert_eq "*.txt" "$(git show --name-only --format= HEAD)"; assert_eq "?? plain.txt" "$(git status --porcelain=v1 -- plain.txt)"; rm plain.txt

# Nothing to commit, but a commit to push: --file-less run pushes it.
git commit -qm "local only" -- b.txt; out="$("$TKT" commit-push "$id")"; assert_contains "$out" "pushed main to origin"
[[ "$out" != *"to undo"* && "$out" != *committed* ]] || fail "a push with nothing committed named a commit or an undo: $out"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"

# t-420c: origin has commits this branch lacks. Only behind: the dry run lists them, the run brings them in (a fast-forward), then
# commits and pushes. Diverged: merged in first (t-dde9's rules, one merge commit), then committed and pushed, so send-issue's
# check (no commit on no branch of origin) passes. Every refusal changes nothing and names the way on. Prod path: the Send panel's
# Commit and push (commit-push-preview, commit-push) and its preview.
C="$W/other-clone"; git clone -q "$W/origin.git" "$C" 2>/dev/null
theirs() { (cd "$C" && git pull -q --no-rebase origin main && printf '%s\n' "$2" > "$1" && git add "$1" && git commit -qm "theirs: $1" && git push -q origin HEAD:main); }
old_text() { [[ "$1" != *"Run git pull first"* && "$1" != *"The PR is merged on GitHub"* ]] || fail "an old message: $1"; }
theirs c.txt theirs
before="$(sig)"; out="$("$TKT" commit-push "$id" --dry-run)"
assert_contains "$out" "merge: origin/main has 1 commit(s) main lacks: Commit and push first brings them into main (a fast-forward):"
assert_contains "$out" "theirs: c.txt"; assert_eq "$before" "$(sig)"
echo nb > newdir/behind.txt; out="$("$TKT" commit-push "$id" --file newdir/behind.txt --message "chore: behind")"; assert_contains "$out" "pushed main to origin"; old_text "$out"
assert_eq "$(git rev-parse HEAD^)" "$(git --git-dir="$W/origin.git" rev-parse main^)"   # the file commit sits on origin's commit
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"; assert_eq "theirs" "$(cat c.txt)"

# Diverged: a local commit and one of origin's. The dry run counts the local commit, names the merge and origin's commit, changes nothing.
git commit -qm "mine: d" --allow-empty; theirs e.txt e-theirs
before="$(sig)"; out="$("$TKT" commit-push "$id" --dry-run)"
assert_contains "$out" "branch: main -> origin/main (1 commit(s) to push)"
assert_contains "$out" "merge: origin/main has 1 commit(s) main lacks: Commit and push first merges origin/main into main here (a merge commit, never a rebase or force):"
assert_contains "$out" "theirs: e.txt"; assert_eq "$before" "$(sig)"
# without --file (a diverged branch always has something to push): one merge commit, parents local then origin, then pushed
lold="$(git rev-parse HEAD)"; oold="$(git --git-dir="$W/origin.git" rev-parse main)"
out="$("$TKT" commit-push "$id")"; old_text "$out"; assert_contains "$out" "merged origin/main ("; assert_contains "$out" "pushed main to origin"
assert_eq "Merge origin/main into main" "$(git log -1 --format=%s)"; assert_eq "$lold $oold" "$(git log -1 --format=%P)"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"
assert_eq 0 "$(git rev-list --count HEAD --not --remotes=origin)"   # what send-issue checks before it sends ("on no branch of origin")
# with --file: merged, then the file committed on the merge, then pushed
git commit -qm "mine: f" --allow-empty; theirs f.txt f-theirs; echo n3 > newdir/three.txt
out="$("$TKT" commit-push "$id" --file newdir/three.txt --message "chore: diverged")"; old_text "$out"
assert_eq "chore: diverged" "$(git log -1 --format=%s)"; assert_eq "Merge origin/main into main" "$(git log -1 --format=%s HEAD^)"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"

# Refusals, each changing nothing (refuses checks HEAD, the index, the files and origin) and ending with the way on.
# a conflict in a person's file: named
echo n4 > newdir/four.txt; echo mine > g.txt; git add g.txt; git commit -qm "mine: g"; theirs g.txt g-theirs
refuses "conflicts in: g.txt" --file newdir/four.txt --message "chore: x"; old_text "$out"; assert_contains "$out" "then Commit and push again"
assert_contains "$out" "Merge it by hand in $P: git merge origin/main"   # the checkout it ran in, not "the main checkout"
git reset -q --hard HEAD^; git pull -q --no-rebase origin main
# a file the merge changes that is edited here (uncommitted): named
git commit -qm "mine: h" --allow-empty; theirs h.txt h-theirs; echo h-here > h.txt
refuses "origin/main could not be merged into local main:" --file newdir/four.txt --message "chore: x"; old_text "$out"
assert_contains "$out" "h.txt"; assert_contains "$out" "Commit and push again"
rm h.txt; git pull -q --no-rebase origin main; git push -q origin HEAD:main
# origin rewritten (force-pushed after this checkout fetched it): the dry run says it will refuse, the run refuses
theirs i.txt i-theirs; git fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
(cd "$C" && git reset -q --hard HEAD^ && echo j > j.txt && git add j.txt && git commit -qm "theirs: j" && "$REAL_GIT" push -q -f origin HEAD:main)   # the rewrite under test, outside the push log the never-forced check reads
git commit -qm "mine: k" --allow-empty
git fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
before="$(sig)"; out="$("$TKT" commit-push "$id" --dry-run)"
assert_contains "$out" "merge: origin/main was rewritten (force-pushed: commits it had are gone): Commit and push will refuse; nothing is merged or pushed. Look at origin/main first"
assert_eq "$before" "$(sig)"
refuses "origin/main was rewritten (force-pushed: commits it had are gone): nothing merged, committed or pushed. Look at origin/main first, then Commit and push again" --file newdir/four.txt --message "chore: x"
old_text "$out"
git merge -q --no-edit origin/main; git push -q origin HEAD:main; (cd "$C" && git fetch -q origin && git reset -q --hard origin/main)

# canon's own docs conflicting (both sides added a LEARNINGS.md row): resolved, both kept, pushed
learn() { printf '# Learnings\n\nlearnings-sweep last run: %s\n\n<!-- canon:learnings:BEGIN -->\n| Date | Ticket | Finding | Status |\n|---|---|---|---|\n' "$1"; shift; printf '%s\n' "$@"; printf '<!-- canon:learnings:END -->\n'; }
row() { printf '| %s | [%s](.tickets/%s/learnings.md) | finding of %s | UNPROMOTED |' "$1" "$2" "$2" "$2"; }
learn "11-01-2026 09:00" "$(row 2026-11-01 t-0001)" > LEARNINGS.md; git add LEARNINGS.md; git commit -qm learnings; git push -q origin HEAD:main
learn "11-13-2026 10:00" "$(row 2026-11-13 t-aaaa)" "$(row 2026-11-01 t-0001)" > LEARNINGS.md; git commit -qam "mine: row"
(cd "$C" && git pull -q --no-rebase origin main && learn "11-13-2026 11:00" "$(row 2026-11-13 t-bbbb)" "$(row 2026-11-01 t-0001)" > LEARNINGS.md && git commit -qam "theirs: row" && git push -q origin HEAD:main)
out="$("$TKT" commit-push "$id")"; assert_contains "$out" "conflicted only in canon's own docs (LEARNINGS.md): resolved, both sides kept"
assert_grep t-aaaa LEARNINGS.md; assert_grep t-bbbb LEARNINGS.md; assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"

# One owner (criterion 5): the rewritten-origin check and the merge are called only from the two shared helpers and _ff_local_base.
calls="$(awk '/^[_a-z]+\(\) *\{/ { f = $1 } /^[[:space:]]*#/ { next } /_origin_rewritten "|_merge_origin_into_base "/ { print f }' "$TKT" | sort -u | paste -sd' ' -)"
assert_eq "_ff_local_base() _merge_origin_before_push() _origin_merge_preview()" "$calls"

# Detached HEAD: refused.
git checkout -q --detach; refuses "is not on a branch (detached HEAD)" --file newdir/two.txt --message "chore: x"; git checkout -q main

# A ticket bound to a linked worktree: its checkout and branch are the ones listed and pushed.
git worktree add -q -b wt-branch "$W/wt" main; printf '%s\n' "$W/wt" > ".tickets/$id/.cockpit-cwd"
out="$("$TKT" commit-push "$id" --dry-run)"; [[ "$out" != *"file:"* ]] || fail "a clean checkout listed files: $out"
echo wt > "$W/wt/w.txt"
out="$("$TKT" commit-push "$id" --dry-run)"; assert_contains "$out" "commit-push: $id in $W/wt"; assert_contains "$out" "branch: wt-branch -> origin/wt-branch (new on origin)"
grep -qxF "file: ?? w.txt" <<< "$out" || fail "the bound worktree's file is not listed: $out"
# t-420c: the worktree's own branch, diverged from origin's: merged and pushed in the worktree, the main checkout untouched
git -C "$W/wt" push -q origin wt-branch; git -C "$W/wt" commit -qm "wt: mine" --allow-empty
(cd "$C" && git fetch -q origin && git checkout -q -b wt-branch origin/wt-branch && echo x > wtx.txt && git add wtx.txt && git commit -qm "theirs: wtx" && git push -q origin wt-branch && git checkout -q main)
mainsig="$(git rev-parse HEAD) $(git status --porcelain=v1 -uall | cksum)"
out="$("$TKT" commit-push "$id" --dry-run)"; assert_contains "$out" "merge: origin/wt-branch has 1 commit(s) wt-branch lacks: Commit and push first merges"
out="$("$TKT" commit-push "$id")"; assert_contains "$out" "pushed wt-branch to origin"
assert_eq "Merge origin/wt-branch into wt-branch" "$(git -C "$W/wt" log -1 --format=%s)"; assert_eq "x" "$(cat "$W/wt/wtx.txt")"
assert_eq "$(git -C "$W/wt" rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse wt-branch)"
assert_eq "$mainsig" "$(git rev-parse HEAD) $(git status --porcelain=v1 -uall | cksum)"
rm ".tickets/$id/.cockpit-cwd"; git worktree remove --force "$W/wt"; git branch -q -D wt-branch

# A branch origin does not have yet: pushed with -u, tracking origin/<branch>.
git checkout -q -b feat/new; out="$("$TKT" commit-push "$id" --dry-run)"; assert_contains "$out" "branch: feat/new -> origin/feat/new (new on origin)"
out="$("$TKT" commit-push "$id" --file newdir/two.txt --message "chore: new branch")"; assert_contains "$out" "(new branch, tracking origin/feat/new)"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$W/origin.git" rev-parse feat/new)"; assert_eq "origin/feat/new" "$(git rev-parse --abbrev-ref '@{u}')"

# A push origin rejects (a hook): the commit stays here, and the output says how to retry and how to undo.
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$W/origin.git/hooks/pre-receive"; chmod +x "$W/origin.git/hooks/pre-receive"
echo more > a.txt; rc=0; out="$("$TKT" commit-push "$id" --file a.txt --message "chore: rejected" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "here; push failed:"; assert_contains "$out" "retry: git push origin feat/new   undo the commit: git reset --soft HEAD^"
assert_eq "chore: rejected" "$(git log -1 --format=%s)"; [[ "$(git --git-dir="$W/origin.git" rev-parse feat/new)" != "$(git rev-parse HEAD)" ]] || fail "the rejected push reached origin"

# t-2560: a ticket whose folder is NOT tracked (the issue carries its text; the cloud rebuilds it) is never listed or committed;
# a tracked one (above) still is. Prod path: the Send panel's Commit and push (commit-push-preview and commit-push).
git checkout -q -- . 2>/dev/null || true; git reset -q
loose="$("$TKT" create "Untracked ticket" -t task)"; printf '# Plan\n' > ".tickets/$loose/plan.md"; echo touch > a.txt
out="$("$TKT" commit-push "$loose" --dry-run)"
[[ "$out" != *".tickets/$loose/"* ]] || fail "an untracked ticket folder was listed: $out"
grep -qxF "file:  M a.txt" <<< "$out" || fail "the project's own change is missing: $out"
rc=0; out="$("$TKT" commit-push "$loose" --file ".tickets/$loose/plan.md" --message x 2>&1)" || rc=$?
[[ "$rc" != 0 ]] || fail "commit-push accepted an untracked ticket file"; assert_contains "$out" "is not one of this checkout's changes"
git checkout -q -- a.txt

# Never forced: no push carried a force flag.
! grep -qE -- '(^| )(-f|--force|--force-with-lease[^ ]*|\+refs)' "$W/pushes" || fail "a push was forced: $(cat "$W/pushes")"
[[ -s "$W/pushes" ]] || fail "the push log is empty: the shim saw no push"

echo "tkt-commit-push: ok"
