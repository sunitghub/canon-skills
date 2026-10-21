#!/usr/bin/env bash
# tkt push-main (t-24b1): the merged dialog's "Push main to …". It pushes origin's default branch (what GitHub merged),
# never the local branch, only to remotes named by git config canon.mirror (never origin, never an unlisted remote such
# as a fork's upstream), never forces, and prints a command that puts a moved mirror back. All remotes are local bare repos.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch trunk
for r in origin public upstream; do git init -q --bare "$W/$r.git"; done
P="$W/p"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
printf '.tickets/\n' > .gitignore; git add .gitignore; git commit -qm one; git push -q origin HEAD:trunk
git remote add public "$W/public.git"; git remote add upstream "$W/upstream.git"
git push -q public trunk; git push -q upstream trunk; OLD="$(git rev-parse trunk)"
# GitHub merged a PR: origin's trunk moves on. Local trunk is behind it and holds a commit that was never merged.
M="$W/merge"; git clone -q "$W/origin.git" "$M" 2>/dev/null
(cd "$M" && echo merged > merged.txt && git add merged.txt && git commit -qm merged && git push -q origin HEAD:trunk)
NEW="$(git --git-dir="$W/origin.git" rev-parse trunk)"
echo local > local.txt; git add local.txt; git commit -qm "local only"; LOCAL="$(git rev-parse trunk)"
at() { git --git-dir="$W/$1.git" rev-parse -q --verify refs/heads/trunk || echo none; }

# No mirrors named: nothing pushed.
out="$("$TKT" push-main)"; assert_contains "$out" "no mirrors named"
assert_eq "$NEW|$OLD|$OLD" "$(at origin)|$(at public)|$(at upstream)"

# public named: it gets origin's trunk (the default branch read from origin, not assumed "main"), never the local-only
# commit; upstream and origin do not move; the undo line puts public back.
git config --add canon.mirror public
out="$("$TKT" push-main)"; assert_contains "$out" "public: trunk ${OLD:0:8} -> ${NEW:0:8}"
assert_eq "$NEW|$NEW|$OLD" "$(at origin)|$(at public)|$(at upstream)"
git --git-dir="$W/public.git" cat-file -e "$LOCAL" 2>/dev/null && fail "the local-only commit reached the mirror"
undo="$(sed -n 's/^  to undo: //p' <<< "$out")"
assert_eq "git push public $OLD:refs/heads/trunk --force-with-lease=refs/heads/trunk:$NEW" "$undo"
eval "$undo" 2>/dev/null; assert_eq "$OLD" "$(at public)"
"$TKT" push-main >/dev/null; out="$("$TKT" push-main)"; assert_contains "$out" "public: trunk already at ${NEW:0:8}"

# A mirror with no trunk yet gets it, with nothing to undo to.
git init -q --bare "$W/fresh.git"; git remote add fresh "$W/fresh.git"; git config --add canon.mirror fresh
out="$("$TKT" push-main)"; assert_contains "$out" "fresh: trunk ${NEW:0:8}"; [[ "$(grep -c 'to undo: git push fresh' <<< "$out" || true)" == 0 ]] || fail "an undo line for a mirror that had no trunk"
assert_eq "$NEW" "$(at fresh)"; git config --unset canon.mirror fresh
rc=0; "$TKT" push-main extra >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"

# t-b6b6: a project that ships binaries (origin's commit carries scripts/check-binaries-released.sh and its manifest) is pushed
# only once that commit is released. The stub judges the manifest AT the commit push-main passes (--rev), like the real script.
stub='#!/usr/bin/env bash
[ "$1" = --rev ] || exit 2
m="$(git show "$2:tools/cockpit-daemon.sha256")" || exit 2
case "$m" in *LAG*) echo "NOT RELEASED  linux-amd64: cockpit-daemon is at abc but the newest manifest line is old" >&2; exit 1 ;; esac
exit 0'
(cd "$M" && git pull -q origin trunk && mkdir -p scripts tools && printf '%s\n' "$stub" > scripts/check-binaries-released.sh \
  && echo LAG > tools/cockpit-daemon.sha256 && git add scripts tools && git commit -qm "daemon change, not released" && git push -q origin HEAD:trunk)
mkdir -p scripts && printf '%s\n' "$stub" > scripts/check-binaries-released.sh   # this checkout's copy (untracked), as in canon
UNREL="$(git --git-dir="$W/origin.git" rev-parse trunk)"; before="$(at public)"
rc=0; out="$("$TKT" push-main 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "push-main: ${UNREL:0:8} (origin/trunk) is not released yet; nothing pushed"
assert_contains "$out" "NOT RELEASED  linux-amd64"; assert_contains "$out" "run scripts/release-daemon.sh"
assert_eq "$before" "$(at public)"
(cd "$M" && echo OK > tools/cockpit-daemon.sha256 && git commit -qam "record the release" && git push -q origin HEAD:trunk)
REL="$(git --git-dir="$W/origin.git" rev-parse trunk)"
out="$("$TKT" push-main)"; assert_contains "$out" "public: trunk ${before:0:8} -> ${REL:0:8}"
rm -rf scripts; NEW="$REL"

# A mirror that has a commit origin lacks: rejected, reported, not forced; exit 1.
X="$W/x"; git clone -q "$W/public.git" "$X" 2>/dev/null; (cd "$X" && echo m > m.txt && git add m.txt && git commit -qm mirror-only && git push -q origin HEAD:trunk)
AHEAD="$(at public)"
rc=0; out="$("$TKT" push-main 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "public: rejected, nothing forced"; assert_eq "$AHEAD" "$(at public)"

# origin is never a mirror; an unknown name is reported.
git config --unset-all canon.mirror; git config --add canon.mirror origin; git config --add canon.mirror nope
rc=0; out="$("$TKT" push-main 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "origin: skipped (origin is not a mirror)"; assert_contains "$out" "nope: no such remote"
assert_eq "$NEW" "$(at origin)"

# origin cannot be read: nothing pushed, exit 1.
git config --unset-all canon.mirror; git config --add canon.mirror upstream; git remote set-url origin "$W/gone.git"
rc=0; out="$("$TKT" push-main 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "could not fetch origin"; assert_eq "$OLD" "$(at upstream)"
echo "tkt-push-main: ok"
