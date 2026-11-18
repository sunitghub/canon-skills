#!/usr/bin/env bash
# record-ticket-commit (t-8990) — in a project that tracks .tickets/, the cloud paths (tkt merge-pr, the Manual close after a merge)
# leave the ticket's folder and canon's HANDOFF Recent block changed on main. record_ticket_commit commits exactly those paths and
# pushes the base branch, never forced; it does nothing in a project that ignores .tickets/, refuses (one line, nothing changed) on
# another branch or a base behind origin, keeps other staged files staged, leaves a HANDOFF narrative edit out, and puts the index
# back when a hook refuses. Prod path: tools/ticket-root.sh record_ticket_commit, called by tkt merge-pr and sprint's Manual close.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
use_fresh_board "$W/board"
export HOME="$W/home" CANON_HOME="$W/canon-home" XDG_CONFIG_HOME="$W/xdg" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CANON_TICKETS_DIR
source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/ticket-root.sh"

git init -q --bare -b main "$W/origin.git"
P="$W/app"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"; git checkout -q -b main 2>/dev/null || true
mkdir -p .tickets/t-ab12; printf -- '---\nid: t-ab12\nstatus: open\n---\n# x\n' > .tickets/t-ab12/ticket.md
printf '# Handoff\n\n<!-- canon:recent:BEGIN -->\n## Recent activity\n- 11-05 21:28 · t-ab12 · plan approved\n<!-- canon:recent:END -->\n\n<!-- canon:handoff:BEGIN -->\nold\n<!-- canon:handoff:END -->\n' > HANDOFF.md
echo code > app.txt; git add -A; git commit -qm base; git push -q origin main
up() { git rev-parse "$1"; }
rec() { RECORDED=false; record_ticket_commit "$@" > "$W/rec.out"; out="$(cat "$W/rec.out")"; }   # not in $(…): RECORDED must reach this shell

# 1. merged: + github.md + the Recent block grew: one commit of exactly those, pushed; an unrelated staged file stays staged
echo 'merged: abc' >> .tickets/t-ab12/ticket.md; echo '# GitHub' > .tickets/t-ab12/github.md; echo q > ".tickets/t-ab12/it's \"x\".md"   # a quote in a name (xargs -0)
sed -i.bak 's/^- 11-05 21:28 .*/&\n- 11-05 21:36 · t-ab12 · merged (PR #7)/' HANDOFF.md; rm -f HANDOFF.md.bak
echo staged > other.txt; git add other.txt; echo dirty >> app.txt
rec "$P" t-ab12 main "chore: record t-ab12 merge of #7"
assert_contains "$out" "and pushed main to origin"; [[ "$out" != *"earlier local"* ]] || fail "named local commits when there were none: $out"; $RECORDED || fail "RECORDED not set"
assert_eq "chore: record t-ab12 merge of #7" "$(git log -1 --format=%s)"
assert_eq "$(printf '%s\n' .tickets/t-ab12/github.md "\".tickets/t-ab12/it's \\\"x\\\".md\"" .tickets/t-ab12/ticket.md HANDOFF.md | sort)" "$(git show --name-only --format= HEAD | sort)"
assert_eq "$(up HEAD)" "$(git --git-dir="$W/origin.git" rev-parse main)"
assert_eq "" "$(git status --porcelain -- .tickets/t-ab12 HANDOFF.md)"
assert_eq "A  other.txt" "$(git status --porcelain -- other.txt)"; assert_eq " M app.txt" "$(git status --porcelain -- app.txt)"
git reset -q other.txt; rm other.txt; git checkout -q -- app.txt

# 2. nothing to record
rec "$P" t-ab12 main x; assert_contains "$out" "nothing to record for t-ab12"; $RECORDED && fail "recorded nothing"
# 3. a HANDOFF narrative edit is left out (only the ticket folder is committed)
sed -i.bak 's/^old$/new focus/' HANDOFF.md; rm -f HANDOFF.md.bak; echo 'cloud_status: closed' >> .tickets/t-ab12/ticket.md
git commit -q --allow-empty -m "local merge"   # an unpushed commit on main goes with the record: the line names it
rec "$P" t-ab12 main "chore: record t-ab12 close"; assert_contains "$out" "pushed main to origin (with 1 earlier local commit)"
assert_eq ".tickets/t-ab12/ticket.md" "$(git show --name-only --format= HEAD)"; assert_eq " M HANDOFF.md" "$(git status --porcelain -- HANDOFF.md)"
git checkout -q -- HANDOFF.md

# 4. another branch, and a base behind origin: one line, nothing committed
echo x >> .tickets/t-ab12/ticket.md; before="$(up HEAD)"
git checkout -q -b side; rec "$P" t-ab12 main x; assert_contains "$out" "is on side, not main"; assert_eq "$before" "$(up HEAD)"; git checkout -q main
C="$W/c2"; git clone -q "$W/origin.git" "$C" 2>/dev/null; echo more >> "$C/app.txt"; git -C "$C" commit -qam ahead; git -C "$C" push -q origin main; git fetch -q origin
rec "$P" t-ab12 main x; assert_contains "$out" "behind origin/main"; assert_eq "$before" "$(up HEAD)"
git merge -q --ff-only origin/main

# 5. a refusing pre-commit hook: nothing committed, the index of the ticket folder as it was (an already staged entry kept)
echo y >> .tickets/t-ab12/github.md; git add .tickets/t-ab12/github.md; idx="$(git ls-files -s -- .tickets/t-ab12)"; head="$(up HEAD)"
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
rec "$P" t-ab12 main x; assert_contains "$out" "could not commit"; assert_contains "$out" "hook says no"
assert_eq "$head" "$(up HEAD)"; assert_eq "$idx" "$(git ls-files -s -- .tickets/t-ab12)"; $RECORDED && fail "recorded on a refused commit"
rm .git/hooks/pre-commit

# 6. a refused push: the commit stays here and the line says how to push it
printf '#!/bin/sh\nexit 1\n' > "$W/origin.git/hooks/pre-receive"; chmod +x "$W/origin.git/hooks/pre-receive"
rec "$P" t-ab12 main "chore: record t-ab12 close"; assert_contains "$out" "the push was refused"; assert_contains "$out" "push it: git push origin main"
assert_eq "chore: record t-ab12 close" "$(git log -1 --format=%s)"; rm "$W/origin.git/hooks/pre-receive"

# 7. a project that ignores .tickets/ (canon's own repo): nothing at all — decided by what git tracks, not by .gitignore's current text
printf '.tickets/\n' > .gitignore; git rm -rq --cached .tickets; git add .gitignore; git commit -qm ignore; head="$(up HEAD)"
echo z >> .tickets/t-ab12/ticket.md; rec "$P" t-ab12 main x; assert_eq "" "$out"; assert_eq "$head" "$(up HEAD)"
echo edited > .gitignore; rec "$P" t-ab12 main x; assert_eq "" "$out"; assert_eq "$head" "$(up HEAD)"   # an untracked ticket stays out
git checkout -q -- .gitignore

echo "record-ticket-commit: ok"
