#!/usr/bin/env bash
# tkt push-main (t-24b1): the merged dialog's "Push main to …". It pushes the local default branch only to remotes named
# by git config canon.mirror (never origin, never an unlisted remote such as a fork's upstream), never forces, and prints
# a command that puts a moved mirror back. All remotes are local bare repos.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main
for r in origin public upstream; do git init -q --bare "$W/$r.git"; done
P="$W/p"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
printf '.tickets/\n' > .gitignore; git add .gitignore; git commit -qm one; git push -q origin HEAD:main
git remote set-head origin main
git remote add public "$W/public.git"; git remote add upstream "$W/upstream.git"
git push -q public main; git push -q upstream main; OLD="$(git rev-parse main)"
echo two > two.txt; git add two.txt; git commit -qm two; NEW="$(git rev-parse main)"   # local main is ahead of all three
at() { git --git-dir="$W/$1.git" rev-parse -q --verify refs/heads/main || echo none; }

# No mirrors named: nothing pushed.
out="$("$TKT" push-main)"; assert_contains "$out" "no mirrors named"
assert_eq "$OLD|$OLD|$OLD" "$(at origin)|$(at public)|$(at upstream)"

# public named: only public moves; the undo line is printed and puts it back.
git config --add canon.mirror public
out="$("$TKT" push-main)"; assert_contains "$out" "public: main ${OLD:0:8} -> ${NEW:0:8}"
assert_eq "$OLD|$NEW|$OLD" "$(at origin)|$(at public)|$(at upstream)"
undo="$(sed -n 's/^  to undo: //p' <<< "$out")"
assert_eq "git push public $OLD:refs/heads/main --force-with-lease=refs/heads/main:$NEW" "$undo"
eval "$undo" 2>/dev/null; assert_eq "$OLD" "$(at public)"
"$TKT" push-main >/dev/null; out="$("$TKT" push-main)"; assert_contains "$out" "public: main already at ${NEW:0:8}"

# A mirror that has a commit main lacks: rejected, reported, not forced; exit 1.
X="$W/x"; git clone -q "$W/public.git" "$X" 2>/dev/null; (cd "$X" && echo m > m.txt && git add m.txt && git commit -qm mirror-only && git push -q origin HEAD:main)
AHEAD="$(at public)"; echo three > three.txt; git add three.txt; git commit -qm three
rc=0; out="$("$TKT" push-main 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "public: rejected, nothing forced"; assert_eq "$AHEAD" "$(at public)"

# origin is never a mirror; an unknown name is reported.
git config --unset-all canon.mirror; git config --add canon.mirror origin; git config --add canon.mirror nope
rc=0; out="$("$TKT" push-main 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "origin: skipped (origin is not a mirror)"; assert_contains "$out" "nope: no such remote"
assert_eq "$OLD" "$(at origin)"
echo "tkt-push-main: ok"
