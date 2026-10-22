#!/usr/bin/env bash
# tkt worktree-reset (t-8f48): after a worktree's PR merged, reset its long-lived tracking branch to origin's default
# branch. It fetches first, refuses wherever a reset --hard would lose work (each refusal one line naming the fix),
# prints what goes, asks once (or --yes), and never pushes, deletes a branch or removes a worktree. Stash and other
# worktrees are shared and untouched: a notice. All remotes are local bare repos.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main
git init -q --bare "$W/origin.git"
S="$W/seed"; git clone -q "$W/origin.git" "$S" 2>/dev/null
(cd "$S" && echo base > a.txt && git add a.txt && git commit -qm base && git push -q origin HEAD:main)
P="$W/p"; git clone -q "$W/origin.git" "$P"
A="$W/wt-a"; B="$W/wt-b"
git -C "$P" worktree add -q -b track-a "$A" origin/main 2>/dev/null
git -C "$P" worktree add -q -b track-b "$B" origin/main 2>/dev/null
origin_refs() { git --git-dir="$W/origin.git" for-each-ref --format='%(refname) %(objectname)'; }
# run <dir> <args...>: sets rc and out (stdout and stderr), never aborts the suite.
run() { local d="$1"; shift; rc=0; out="$(cd "$d" && "$TKT" worktree-reset "$@" 2>&1 < /dev/null)" || rc=$?; }
refuses() {   # refuses <dir> <message part> [args...]: exit 1, the message, HEAD unchanged
  local d="$1" msg="$2" before; shift 2; before="$(git -C "$d" rev-parse HEAD)"
  run "$d" --yes "$@"; assert_eq 1 "$rc"; assert_contains "$out" "$msg"
  assert_eq "$before" "$(git -C "$d" rev-parse HEAD)"
}

# Usage.
refuses "$A" "use one" --dry-run
run "$A" --bogus; assert_eq 1 "$rc"; assert_contains "$out" "Usage: tkt worktree-reset"

# The work: a commit on track-a, pushed to its own remote branch, then squash-merged on GitHub (main gets new content
# whose commit is not track-a's). track-b stays behind.
(cd "$A" && echo work > a.txt && echo new > n.txt && git add . && git commit -qm "feat: the work" && git push -q origin track-a)
WORK="$(git -C "$A" rev-parse HEAD)"
(cd "$S" && echo work > a.txt && echo new > n.txt && echo merged > m.txt && git add . && git commit -qm "squash: the work (#1)" && git push -q origin HEAD:main)
MAIN="$(git --git-dir="$W/origin.git" rev-parse main)"
REFS="$(origin_refs)"

# Context refusals: the main checkout; the default branch itself; a detached HEAD; outside git.
refuses "$P" "is the main checkout, not a linked worktree"
git -C "$B" checkout -q --ignore-other-worktrees main 2>/dev/null
refuses "$B" "main is the default branch itself"
git -C "$B" checkout -q track-b
git -C "$B" checkout -q --detach
refuses "$B" "HEAD is detached; check out the worktree's tracking branch"
git -C "$B" checkout -q track-b
mkdir "$W/plain"; refuses_plain() { rc=0; out="$(cd "$W/plain" && "$TKT" worktree-reset --yes 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "not inside a git worktree"; }
refuses_plain

# A failing fetch refuses: no reset onto a stale origin/main.
git -C "$P" remote set-url origin "$W/gone.git"
refuses "$A" "git fetch origin failed; nothing reset"
git -C "$P" remote set-url origin "$W/origin.git"
# origin/HEAD unset (as after git remote add): the default branch is read from origin itself; unreadable too: refuse.
git -C "$P" remote set-head origin -d
run "$A" --dry-run --dry-run; assert_eq 0 "$rc"; assert_contains "$out" "new tip: origin/main"
# git 2.48+ fetch recreates origin/HEAD (followRemoteHEAD), so the dry run above set it again: unset it for the unreadable case.
git -C "$P" remote set-head origin -d
git -C "$P" remote set-url origin "$W/gone.git"
refuses "$A" "cannot tell origin's default branch; run git remote set-head origin --auto"
git -C "$P" remote set-url origin "$W/origin.git"; git -C "$P" remote set-head origin main

# --dry-run prints what goes and changes nothing.
run "$A" --dry-run; assert_eq 0 "$rc"
assert_contains "$out" "new tip: origin/main ${MAIN:0:7} squash: the work (#1)"
assert_contains "$out" "${WORK:0:7} feat: the work"
assert_contains "$out" "worktree-reset: track-a in $A"
assert_contains "$out" "commits it drops from track-a (each is on a remote):"
assert_contains "$out" "files it changes to origin/main's version:"$'\n'$'    A\tm.txt'
assert_contains "$out" "the reset does not touch them: 0 stash entries"
assert_contains "$out" "dry run; nothing changed"
assert_eq "$WORK" "$(git -C "$A" rev-parse HEAD)"

# Work refusals, each with its fix; after each the worktree is put back.
echo dirty >> "$A/a.txt"; refuses "$A" "1 uncommitted or untracked path(s) (a.txt); commit and push them"; git -C "$A" checkout -q -- a.txt
echo u > "$A/untracked.txt"; refuses "$A" "uncommitted or untracked path(s) (untracked.txt)"; rm "$A/untracked.txt"
mkdir -p "$A/.claude"; echo n > "$A/.claude/notes.md"; refuses "$A" "(.claude/notes.md)"; rm -r "$A/.claude"
# Only UNTRACKED skill links are canon's: a staged file under .claude/skills is work.
mkdir -p "$A/.claude/skills"; echo t > "$A/.claude/skills/x.md"; git -C "$A" add -f .claude/skills/x.md
refuses "$A" "1 uncommitted or untracked path(s) (.claude/skills/x.md)"; git -C "$A" rm -q --cached .claude/skills/x.md; rm -r "$A/.claude"
# A staged rename is one path (the new name), not its source as a second entry.
git -C "$A" mv n.txt renamed.txt; refuses "$A" "1 uncommitted or untracked path(s) (renamed.txt);"
echo z > "$A/zz.txt"; refuses "$A" "2 uncommitted or untracked path(s) (renamed.txt, zz.txt);"; rm "$A/zz.txt"; git -C "$A" reset -q --hard
echo 1 > "$A/u1.txt"; echo 2 > "$A/u2.txt"; refuses "$A" "2 uncommitted or untracked path(s) (u1.txt, u2.txt);"; rm "$A/u1.txt" "$A/u2.txt"
git -C "$A" update-index --skip-worktree n.txt; refuses "$A" "1 file(s) marked skip-worktree or assume-unchanged"; git -C "$A" update-index --no-skip-worktree n.txt
# Run from a subdirectory the probes still cover the whole worktree.
mkdir -p "$A/sub/dir"; git -C "$A" update-index --skip-worktree n.txt; refuses "$A/sub/dir" "1 file(s) marked skip-worktree"; git -C "$A" update-index --no-skip-worktree n.txt; rm -r "$A/sub"
git -C "$A" update-index --assume-unchanged n.txt; refuses "$A" "1 file(s) marked skip-worktree or assume-unchanged"; git -C "$A" update-index --no-assume-unchanged n.txt
(cd "$A" && echo local > l.txt && git add l.txt && git commit -qm "local only")
refuses "$A" "track-a has 1 commit(s) on no remote"; git -C "$A" reset -q --hard "$WORK"
for op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  f="$(git -C "$A" rev-parse --path-format=absolute --git-path "$op")"; echo "$WORK" > "$f"
  refuses "$A" "a merge, rebase, cherry-pick or revert is in progress ($op)"; rm "$f"
done
for op in rebase-merge rebase-apply; do
  f="$(git -C "$A" rev-parse --path-format=absolute --git-path "$op")"; mkdir "$f"
  refuses "$A" "in progress ($op)"; rmdir "$f"
done
# A real conflicting cherry-pick, not only its marker file.
(cd "$A" && git checkout -q -b scratch "$MAIN~1" && echo other > a.txt && git commit -qam other && git checkout -q track-a \
  && { git cherry-pick scratch >/dev/null 2>&1 || true; })
refuses "$A" "in progress (CHERRY_PICK_HEAD)"; git -C "$A" cherry-pick --abort; git -C "$A" branch -q -D scratch
assert_eq "$WORK" "$(git -C "$A" rev-parse HEAD)"
# Without --yes and no terminal: refuses before resetting.
rc=0; out="$(cd "$A" && "$TKT" worktree-reset 2>&1 < /dev/null)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "no terminal to ask on; pass --yes"; assert_eq "$WORK" "$(git -C "$A" rev-parse HEAD)"

# The prompt: n keeps everything; y resets (asked on a real terminal through script(1), where it exists).
if script -qec true /dev/null >/dev/null 2>&1; then
  out="$(cd "$A" && printf 'n\n' | script -qec "$TKT worktree-reset" /dev/null 2>&1)"
  assert_contains "$out" "[y/N]"; assert_contains "$out" "nothing reset"; assert_eq "$WORK" "$(git -C "$A" rev-parse HEAD)"
else
  echo "SKIP: no script(1) here; the [y/N] prompt is untested on this host" >&2
fi

# The clean path on the squash-merged branch: a stash and the skill links are present and do not block it.
(cd "$B" && echo s > a.txt && git stash -q)
mkdir -p "$A/.claude/skills/sprint" "$A/.agents"; echo x > "$A/.claude/skills/sprint/SKILL.md"; ln -s ../.claude/skills "$A/.agents/skills"
run "$A" --yes; assert_eq 0 "$rc"
assert_contains "$out" "${WORK:0:7} feat: the work"
assert_contains "$out" "Reset track-a to origin/main? yes (--yes)"
assert_contains "$out" "notice: stash and other worktrees are shared and the reset does not touch them: 1 stash entry"
assert_contains "$out" "other worktree: $P"; assert_contains "$out" "other worktree: $B"
assert_contains "$out" "track-a now at ${MAIN:0:7} squash: the work (#1) (was ${WORK:0:8})"
assert_contains "$out" "the worktree keeps its identity: still $A on branch track-a"
assert_contains "$out" "next: sprint start <id> for the next ticket"
assert_eq "$MAIN" "$(git -C "$A" rev-parse HEAD)"; assert_eq track-a "$(git -C "$A" symbolic-ref --short HEAD)"
assert_file_exists "$A/.claude/skills/sprint/SKILL.md"
# Never pushes, deletes a branch or removes a worktree; the stash is still there.
assert_eq "$REFS" "$(origin_refs)"
git -C "$P" show-ref --verify -q refs/heads/track-a || fail "track-a was deleted"
assert_eq 3 "$(git -C "$P" worktree list | wc -l | tr -d ' ')"
assert_eq 1 "$(git -C "$B" stash list | wc -l | tr -d ' ')"
# Again: already there.
run "$A" --yes; assert_eq 0 "$rc"; assert_contains "$out" "already at origin/main"

# A branch only behind origin/main resets through the prompt's y (track-b, its stash dropped first).
git -C "$B" stash drop -q
if script -qec true /dev/null >/dev/null 2>&1; then
  # The answer is an await: whatever changes while the prompt waits is found before anything is reset.
  ask_during() {   # ask_during <dir> <command run while the prompt waits> <answer>: sets out and rc
    rm -f "$W/ans"; mkfifo "$W/ans"; : > "$W/ask.out"
    (cd "$1" && r=0; script -qec "$TKT worktree-reset" /dev/null < "$W/ans" > "$W/ask.out" 2>&1 || r=$?; echo "$r" > "$W/ask.rc") &
    exec 3> "$W/ans"; local n=0
    until grep -q 'y/N' "$W/ask.out"; do n=$((n + 1)); (( n < 100 )) || fail "no prompt"; sleep 0.1; done
    eval "$2"; printf '%s\n' "$3" >&3; exec 3>&-; wait
    out="$(cat "$W/ask.out")"; rc="$(cat "$W/ask.rc")"
  }
  BASE="$(git --git-dir="$W/origin.git" rev-parse main~1)"
  ask_during "$B" 'echo late > "$B/late.txt"' y
  assert_eq 1 "$rc"; assert_contains "$out" "1 uncommitted or untracked path(s) (late.txt)"; assert_eq "$BASE" "$(git -C "$B" rev-parse HEAD)"; rm "$B/late.txt"
  ask_during "$B" 'git -C "$B" commit -q --allow-empty -m moved' y
  assert_eq 1 "$rc"; assert_contains "$out" "track-b moved while asking; nothing reset"; git -C "$B" reset -q --hard "$BASE"
  ask_during "$B" 'git -C "$B" checkout -q -b other' y
  assert_eq 1 "$rc"; assert_contains "$out" "track-b moved while asking"; assert_eq "$BASE" "$(git -C "$B" rev-parse HEAD)"
  git -C "$B" checkout -q track-b; git -C "$B" branch -q -D other
  # Y resets: the prompt names the branch, the target and its sha.
  ask_during "$B" : Y
  assert_eq 0 "$rc"; assert_contains "$out" "Reset track-b to origin/main (${MAIN:0:8})? [y/N]"
  assert_contains "$out" "(none: track-b is behind origin/main)"; assert_contains "$out" "track-b now at ${MAIN:0:7}"
  assert_eq "$MAIN" "$(git -C "$B" rev-parse HEAD)"
fi

echo "PASS: tkt worktree-reset"
