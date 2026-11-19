#!/usr/bin/env bash

# t-f7e6: wt_write_ok (the worktree link check every writer makes) lives in platform-lib.sh; a caller that sources only this file gets it.
# shellcheck source=platform-lib.sh
declare -F wt_write_ok >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"
_CANON_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # t-e9aa: tools/, for _canon_setup_edit_only

# _worktree_main_tickets <dir> — t-6be7: when <dir> is a linked worktree (its .git is a FILE: "gitdir: <repo>/.git/worktrees/<name>"),
# the main checkout's .tickets path; nothing otherwise. One owner of the pointer rules, shared by tickets_dir and `sprint eval-verdict`.
_worktree_main_tickets() {
  local dir="$1" gitdir
  [[ -f "$dir/.git" ]] || return 0
  gitdir="$(sed -n 's/^gitdir: //p' "$dir/.git")"
  case "$gitdir" in
    # t-7301: Git for Windows writes a drive-letter pointer ("C:/Users/.../.git/worktrees/x"). It is absolute, so
    # it must not be joined onto $dir; map it to the shell's own form when cygpath can (matches `pwd -P`).
    [A-Za-z]:[\\/]*)
      gitdir="${gitdir//\\//}"
      if command -v cygpath >/dev/null 2>&1; then
        local mapped
        if mapped="$(cygpath -u "$gitdir" 2>/dev/null)" && [[ -n "$mapped" ]]; then gitdir="$mapped"; fi
      fi
      ;;
    /*) ;;
    *) gitdir="$dir/$gitdir" ;;
  esac
  case "$gitdir" in
    */worktrees/*) echo "$(dirname "${gitdir%/worktrees/*}")/.tickets" ;;
  esac
}

tickets_dir() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    # t-dec4: the walk stops at home: a folder under home is its own project, so neither home's .tickets nor its .git (a dotfiles repository)
    # nor anything above home (C:\Users, /Users) can be its project; started IN home it falls through to home's own .tickets below, so home
    # is a project like any other. (-ef: the same file by device and inode, so a symlinked or differently spelled HOME matches; no forks.)
    if [[ -n "${HOME:-}" && "$dir" -ef "$HOME" ]]; then break; fi
    # t-5738: a .tickets in a drive root or a system folder is not a project's. Skip it and keep walking; a .git there still counts.
    # (A folder with its own .git is a project at once, so the guard, which forks about twenty times, runs only without one.)
    if [[ -d "$dir/.tickets" ]] && { [[ -d "$dir/.git" ]] || [[ -z "$(folder_guard_reason "$dir")" ]]; }; then echo "$dir/.tickets"; return 0; fi
    [[ -d "$dir/.git" ]] && echo "$dir/.tickets" && return 0
    # t-cd06: a git-worktree checkout's .git is a FILE ("gitdir: <repo>/.git/
    # worktrees/<name>"), not a directory — the check above never matches it,
    # so a session running inside a worktree used to fall off the walk
    # entirely and find no .tickets at all (live-reproduced: "tkt ls shows no
    # tickets at all" from inside a real worktree). .tickets lives only in the
    # MAIN checkout, never per-worktree, so resolve the gitdir pointer back to
    # the real repo root instead of treating the worktree itself as one.
    if [[ -f "$dir/.git" ]]; then
      local main_tickets
      main_tickets="$(_worktree_main_tickets "$dir")"
      if [[ -n "$main_tickets" ]]; then echo "$main_tickets"; return 0; fi
    fi
    dir="$(dirname "$dir")"
  done
  echo "$PWD/.tickets"
}

project_root() {
  dirname "$(tickets_dir)"
}

# ticket_path <path> — t-597f: a `.tickets/…` path named from a folder with no .tickets of its own (a land worktree: its tickets are
# the main checkout's, t-cd06) is that path in the project's ticket folder, so the close docs' relative paths work there. Any other
# path is printed unchanged.
ticket_path() {
  if [[ "$1" == .tickets/* && ! -e .tickets ]]; then echo "$(tickets_dir)/${1#.tickets/}"; else echo "$1"; fi
}

# stray_tickets — t-597f: in a tkt land worktree (it never has a .tickets/ of its own: land keeps a tracked one out with sparse-checkout,
# and a land/<id> branch of a project that ignores .tickets has none), a .tickets/ for tickets the main checkout holds: a gate wrote a
# relative path, and every reader there now sees that folder instead of the ticket. Prints the stray files and returns 0 when there are
# any. Any other worktree's own .tickets/ is legitimate (an adopted worktree's copy, t-3abc; one that tracks its own, t-f7e6).
stray_tickets() {
  local wt main d id files="" sparse=false
  wt="$(worktree_root 2>/dev/null)" || return 1
  [[ -f "$wt/.git" && -d "$wt/.tickets" ]] || return 1
  main="$(_worktree_main_tickets "$wt")"; [[ -n "$main" && -d "$main" ]] || return 1
  [[ "$(land_sparse_state "$wt")" == ok ]] && sparse=true   # t-edda: the one reader of the pattern
  $sparse || [[ "$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" == land/* ]] || return 1
  for d in "$wt"/.tickets/*/; do
    [[ -d "$d" ]] || continue; id="$(basename "$d")"; [[ -f "$main/$id/ticket.md" ]] || continue
    if $sparse; then files+="$(find "$d" -type f)"$'\n'
    else files+="$(git -C "$wt" ls-files --others -- ".tickets/$id")"$'\n'; fi
  done
  files="$(printf '%s' "$files" | grep . || true)"
  [[ -n "$files" ]] || return 1
  printf '%s\n' "$files"
}

# t-8bd8: the root files a close writes by a relative path (complete.md steps 6 and 8: the DECISIONS.md row, the learnings-sweep row,
# a HANDOFF note). In a tkt land worktree they belong in the main checkout, like its .tickets (t-597f): written in the worktree, a
# tracked one makes `git worktree remove` refuse and an ignored one is deleted with the worktree.
LAND_CLOSE_DOCS=(DECISIONS.md DECISIONS-archive.md LEARNINGS.md LEARNINGS-archive.md HANDOFF.md)

# land_sparse_state <worktree> — t-edda: ok when its sparse-checkout keeps .tickets/ out (`!/.tickets/`), converted when the pattern
# names .tickets/ under some other path (Git Bash's path conversion rewrote `!/.tickets/` into `!C:/Program Files/Git/.tickets/`,
# which keeps nothing out), none otherwise. Prints the state and sets LAND_SPARSE_STATE (and, when converted, LAND_SPARSE_BAD to the
# stored line) for a caller that runs it outside $(…).
land_sparse_state() {
  local list ln; LAND_SPARSE_BAD=""; LAND_SPARSE_STATE=none
  if list="$(git -C "$1" sparse-checkout list 2>/dev/null)"; then
    if [[ $'\n'"$list"$'\n' == *$'\n!/.tickets/\n'* ]]; then LAND_SPARSE_STATE=ok   # no early-exit pipe (pipefail)
    else while IFS= read -r ln; do [[ "$ln" == '!'*/.tickets/ ]] && { LAND_SPARSE_BAD="$ln"; LAND_SPARSE_STATE=converted; break; }; done <<< "$list"; fi
  fi
  echo "$LAND_SPARSE_STATE"
}

# land_sparse_repair <worktree> — t-edda: returns 0 and prints the repair when the worktree's .tickets/ pattern was converted; 1 otherwise.
land_sparse_repair() {
  land_sparse_state "$1" >/dev/null; [[ "$LAND_SPARSE_STATE" == converted ]] || return 1
  echo "this land worktree's sparse-checkout pattern is wrong ($LAND_SPARSE_BAD: Git Bash rewrote it), so it holds the PR's own .tickets/ and a close there reads that copy, not the main checkout's."
  echo "  repair, in PowerShell (it does not rewrite paths): git -C \"$1\" sparse-checkout set --no-cone \"/*\" \"!/.tickets/\""
  echo "  first move any ticket edits made in $1/.tickets/ to the main checkout's copy (git refuses to drop a changed file); then run this again."
}

# _is_land_worktree <dir> — a tkt land worktree: a linked worktree on land/*, or one whose sparse-checkout names .tickets/ (kept out, or
# t-edda: meant to be, with a converted pattern).
_is_land_worktree() {
  [[ -f "$1/.git" ]] || return 1
  [[ "$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null)" == land/* ]] && return 0
  [[ "$(land_sparse_state "$1")" != none ]]
}

# land_main_root <worktree> — the main checkout's root for a linked worktree.
land_main_root() { local m; m="$(_worktree_main_tickets "$1")"; [[ -n "$m" ]] && dirname "$m"; }

# land_close_docs <worktree> — t-8bd8: returns 1 unless <worktree> is a tkt land worktree; else prints each LAND_CLOSE_DOCS file at its
# root that is changed, new or ignored-but-present (a fresh land worktree holds no ignored file, so one is a close's write), one per
# line, nothing when there is none. Takes the path: --finish runs from the main checkout. A git failure prints its reason (refuse).
land_close_docs() {
  local wt="$1" out
  _is_land_worktree "$wt" || return 1
  out="$(git -C "$wt" -c core.quotepath=off status --porcelain=v1 --ignored --untracked-files=all -- "${LAND_CLOSE_DOCS[@]}" 2>&1)" \
    || { echo "git could not read the status of $wt: $out"; return 0; }
  [[ -z "$out" ]] || printf '%s\n' "$out" | cut -c4-
}

# worktree_root — the caller's OWN worktree top-level directory (t-01a4),
# distinct from project_root(): project_root() always redirects to the MAIN
# checkout (.tickets/ lives only there, t-cd06), but a per-worktree gate needs
# to know which worktree the caller is actually IN. Walks up from $PWD to the
# nearest ancestor with a .git entry (file, for a linked worktree — or
# directory, for the main checkout) and returns ITS path, symlink-resolved
# (`cd ... && pwd -P`, matching the daemon's Go EvalSymlinks intent so a
# bash-written .cockpit-cwd compares equal to one the daemon wrote).
worktree_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -e "$dir/.git" ]]; then
      (cd "$dir" && pwd -P)
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  (cd "$PWD" && pwd -P)
}

# Late docs written after the evaluator grades that a merge may carry unreviewed (t-fdb1): the learnings sweep's two files, which
# the cloud commits after its gates (complete.md step 8). One owner for these names: tools/sprint's stale-eval gate (t-1b74) builds
# its wider list from them; merge-pr and import-results add only the merged ticket's own folder (late_docs_delta). Residual risk,
# accepted: every sprint start reads LEARNINGS.md (start.md), so an unreviewed row from a cloud branch reaches agents; merge-pr
# names the files before it asks. The always-loaded and start-read docs (AGENTS.md, CLAUDE.md, PROMOTED.md, HANDOFF.md,
# DECISIONS.md) and other tickets' folders are not here.
MERGE_SAFE_LATE_ALT='LEARNINGS\.md$|LEARNINGS-archive\.md$'
# t-2a95: the docs the close itself writes that a LOCAL worktree merge (tkt merge, Check & merge) also takes as late: the wrapup's
# HANDOFF.md narrative (written at complete.md step 1, before grading, but uncommitted, so past graded-head) and DECISIONS.md's row
# (step 6, after grading). The close gate accepted them on this branch, and a close in the main checkout commits the same files to
# main with no merge check at all. A cloud merge (merge-pr, import-results, github-status) never takes them: nobody here saw the
# cloud's write (t-fdb1), so its HANDOFF.md passes only with the Recent block alone changed (t-dfaf) and its DECISIONS.md only with rows
# added that name the ticket (t-7d84, both in late_docs_delta). tools/sprint's close-time list
# builds from this name.
MERGE_SAFE_CLOSE_ALT='HANDOFF\.md$|DECISIONS\.md$|DECISIONS-archive\.md$'
# The one other late file (t-75f5): the audit log the gates append to (subagent-log.sh). A cloud session commits it after its evaluator
# graded, so without it every clean cloud run reads as new code. It is data, not instructions (no agent loads it), and it may only GROW:
# a changed or removed line is a rewrite and needs a re-grade. Nothing else under .claude/ is late-safe. tools/sprint's close-time
# list builds its regex from this name.
MERGE_SAFE_AUDIT_LOG='.claude/subagent-runs.jsonl'

# _handoff_block_ok <file>: t-dfaf: is the Recent activity block in this HANDOFF.md copy exactly what canon writes? One BEGIN and one END marker
# line, in that order (a second block or a stray marker is not a line the pattern below allows), and between them only the fixed header, the fixed "Written by canon" line, the empty-state line, blank lines and
# event lines of the writer's shape: `- MM-DD HH:MM · <ticket id or -> · <one of its known phrases>`. A line of free text, a link or an
# instruction fails it: the head's block is text an agent reads at session start, so the late-doc exemption is for canon's own lines only.
# (tools/canon-go/internal/board/recent.go recentBlock and recentKinds are the owners of this shape; tests/tkt-merge-pr.sh pins both ends.)
_handoff_block_ok() {
  local f="$1" inner n total ok dot='·' pat tier='[a-z-]{1,16}' model='[A-Za-z0-9._:/-]{1,80}' branch='[A-Za-z0-9._/-]{1,100}'   # no space in any class: a value is one word, a sentence is not a value
  # `recent --strip` finds the markers as substrings anywhere in the text; this check reads whole lines. They must see the same block, so the
  # marker text occurs exactly twice in the file (once as a whole BEGIN line, once as a whole END line), and the file holds no NUL (bash
  # would drop it from the lines below, so what is checked would not be what is merged).
  [[ "$(wc -c < "$f")" == "$(tr -d '\000' < "$f" | wc -c)" ]] || return 1
  n="$(LC_ALL=C grep -ao '<!-- canon:recent:' "$f" | wc -l)"; [[ "${n//[[:space:]]/}" == 2 ]] || return 1
  inner="$(tr -d '\r' < "$f" | sed -n '/^<!-- canon:recent:BEGIN -->$/,/^<!-- canon:recent:END -->$/p')"
  [[ "$(printf '%s\n' "$inner" | sed -n '$p')" == '<!-- canon:recent:END -->' ]] || return 1   # END came before BEGIN, or a marker is not a whole line
  inner="$(printf '%s\n' "$inner" | sed '1d;$d')"
  total="$(printf '%s\n' "$inner" | wc -l)"; total="${total//[[:space:]]/}"
  pat="## Recent activity|_Written by canon from the activity log at plan approval, sprint close and merge; edits here are replaced\\._|- No stage recorded yet\\.|"
  pat+="- [0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} $dot (t-[a-z0-9]{4}|-) $dot ("
  # t-864c: the gate roles are platform-lib.sh's GATE_ROLES (loaded by tkt and sprint), so a new gate's line is never refused here
  local roles="${GATE_ROLES:-reviewer evaluator}"; roles="${roles// /|}"
  pat+="plan approved( \\($tier\\))?|($roles) (pass|fail|partial|not-run|YES|NO|READY|GAPS|unknown|-)( \\($model\\))?|sprint completed"
  pat+="|sent to GitHub( \\(issue #[0-9]{1,7}\\))?|cloud results imported( \\(PR #[0-9]{1,7}\\))?|merged( \\(PR #[0-9]{1,7}\\))?|merged here( \\($branch\\))?)"
  # count, not "print the first miss": a grep that errors, or reads binary data, counts fewer lines and fails the check (a blank line matches the empty alternative)
  ok="$(printf '%s\n' "$inner" | LC_ALL=C grep -acxE "($pat)?" || true)"; ok="${ok//[[:space:]]/}"
  [[ -n "$ok" && "$ok" == "$total" ]]
}

# late_doc_path <path> <ticket-id> [local] — t-2a95: the one rule for which repo path is a late doc by its name: a file under
# .tickets/<ticket-id>/ with no dotfile component, a merge-safe late doc (MERGE_SAFE_LATE_ALT) and, for a local merge, one the close
# writes (MERGE_SAFE_CLOSE_ALT). Read by late_docs_delta and by tkt merge's close record, so what --yes commits the merge accepts.
# The audit log (append-only) and HANDOFF.md's Recent block have their own content rules in late_docs_delta.
late_doc_path() {
  local alt="$MERGE_SAFE_LATE_ALT"; [[ "${3:-}" == local ]] && alt+="|$MERGE_SAFE_CLOSE_ALT"
  [[ "$1" =~ ^($alt|\.tickets/$2/([^./][^/]*/)*[^./][^/]*$) ]]
}

# _branch_ok <name> — t-24b1: a branch name read from GitHub or a remote goes on git and gh command lines only when
# git accepts it as a branch name and it cannot be read as an option.
_branch_ok() { [[ -n "$1" && "$1" != -* ]] && git check-ref-format --branch "$1" >/dev/null 2>&1; }

# _default_branch <root> — t-e1a2: the project's default branch: origin/HEAD's, else main, else master (the first that exists
# locally). Prints it; returns 1 with nothing printed when none is there.
_default_branch() {
  local b
  b="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"; b="${b#origin/}"
  if [[ -z "$b" ]]; then
    for b in main master; do git -C "$1" rev-parse -q --verify "refs/heads/$b^{commit}" >/dev/null 2>&1 && break || b=""; done
  fi
  [[ -n "$b" ]] && _branch_ok "$b" && printf '%s\n' "$b"
}

# _base_branch <root> — t-99d2: the branch the gates compare against: _default_branch (origin/HEAD, else local main, else master), else
# the remote's own main or master when only those refs exist (a clone without origin/HEAD or a local default branch).
_base_branch() {
  local b
  b="$(_default_branch "$1")" && { printf '%s\n' "$b"; return 0; }
  for b in main master; do git -C "$1" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 && { printf '%s\n' "$b"; return 0; }; done
  return 1
}

# default_base_ref <root> — t-99d2: the headless tools' default base REF (not a commit): origin/<default branch> when it exists, else the
# local default branch; prints nothing and returns 1 when neither resolves. Was origin/main then main in two copies.
default_base_ref() {
  local b; b="$(_base_branch "${1:-.}")" || return 1
  if git -C "${1:-.}" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1; then printf 'origin/%s\n' "$b"
  elif git -C "${1:-.}" rev-parse -q --verify "refs/heads/$b" >/dev/null 2>&1; then printf '%s\n' "$b"
  else return 1; fi
}

# gate_base <root> — t-99d2: the close gates' base, the one owner of the rule: `git merge-base HEAD origin/<default branch>`, where the
# default branch is origin/HEAD's (else main, else master: _default_branch). Prints the commit; on failure prints the reason (naming the
# branch it looked for) and returns 1. A master repo used to fail here, as every caller hard-coded origin/main.
gate_base() {
  local root="${1:-.}" b out
  b="$(_base_branch "$root")" || { echo "no default branch: origin/HEAD is not set and there is no main or master, local or on origin"; return 1; }
  git -C "$root" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 || { echo "no origin/$b to compare with"; return 1; }
  out="$(git -C "$root" merge-base HEAD "origin/$b" 2>/dev/null)" && [[ -n "$out" ]] || { echo "HEAD has no common ancestor with origin/$b"; return 1; }
  printf '%s\n' "$out"
}

# record_ticket_commit <root> <id> <base> <message> — t-8990: in a project that tracks .tickets/, the cloud paths (merge-pr, the
# Manual close after a merge) leave the ticket's folder (merged:, github.md, the close records) and canon's HANDOFF Recent block
# changed on main. This commits exactly those paths as <message> and pushes the base branch to origin, never forced, so main is
# clean and in sync (user decision 2026-11-17). Only when the main checkout is on <base> and <base> is at or past origin's; other
# staged files stay staged (commit --only); a refused commit puts the index of those paths back as it was. Prints one line about
# what it did or why not, and always returns 0: the merge or close it follows already succeeded. Sets RECORDED=true on a commit.
record_ticket_commit() {
  local root="$1" id="$2" base="$3" msg="$4" head saved out sha rb t1 t2 ahead note
  local paths=()
  RECORDED=false
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  # only a ticket git already tracks (a project that commits its tickets; the merged PR brought it in): never by what .gitignore says now
  [[ -n "$(git -C "$root" ls-files -- ".tickets/$id/ticket.md" 2>/dev/null)" ]] || return 0
  head="$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)" || head=""
  [[ "$head" == "$base" ]] || { echo "record: the main checkout is on ${head:-a detached HEAD}, not $base, so .tickets/$id/ is not committed; commit it on $base by hand"; return 0; }
  if git -C "$root" rev-parse -q --verify "refs/remotes/origin/$base" >/dev/null \
    && ! git -C "$root" merge-base --is-ancestor "refs/remotes/origin/$base" HEAD 2>/dev/null; then
    echo "record: $base here is behind origin/$base, so .tickets/$id/ is not committed; update $base, then commit it by hand"; return 0
  fi
  paths=(".tickets/$id")
  # HANDOFF.md only when its one difference from HEAD is canon's Recent block (t-dfaf's rule; CRs ignored)
  if git -C "$root" ls-files --error-unmatch -- HANDOFF.md >/dev/null 2>&1 && ! git -C "$root" diff --quiet HEAD -- HANDOFF.md 2>/dev/null \
    && rb="$(recent_board 2>/dev/null)"; then
    t1="$(mktemp)"; t2="$(mktemp)"
    if ( set -o pipefail; git -C "$root" show HEAD:HANDOFF.md 2>/dev/null | "$rb" recent --strip | LC_ALL=C tr -d '\r' ) > "$t1" \
      && ( set -o pipefail; "$rb" recent --strip < "$root/HANDOFF.md" | LC_ALL=C tr -d '\r' ) > "$t2" && cmp -s "$t1" "$t2"; then
      paths+=(HANDOFF.md)
    fi
    rm -f "$t1" "$t2"
  fi
  [[ -n "$(git -C "$root" status --porcelain=v1 --untracked-files=all -- "${paths[@]}" 2>/dev/null)" ]] \
    || { echo "record: nothing to record for $id"; return 0; }
  saved="$(git -C "$root" ls-files -s -- "${paths[@]}" 2>/dev/null)"
  # tracked changes, plus only the untracked files git does not ignore (a project may ignore .tickets/ and track some tickets by force;
  # canon's own markers stay out through .tickets/.gitignore)
  local u; u="$(git -C "$root" ls-files -z --others --exclude-standard -- "${paths[@]}" 2>/dev/null | tr '\0' '\n')"
  if ! out="$(git -C "$root" add -u -- "${paths[@]}" 2>&1 && { [[ -z "$u" ]] || git -C "$root" ls-files -z --others --exclude-standard -- "${paths[@]}" | (cd "$root" && xargs -0 git add --) 2>&1; } \
    && git -C "$root" commit -q --only -m "$msg" -- "${paths[@]}" 2>&1)"; then
    git -C "$root" reset -q -- "${paths[@]}" 2>/dev/null
    [[ -z "$saved" ]] || printf '%s\n' "$saved" | git -C "$root" update-index --index-info 2>/dev/null
    # t-7db9: a hook's own BLOCKED line is the reason; the last line is often the end of its suite's output
    local why; why="$(grep -m1 '^\[pre-commit\] BLOCKED' <<< "$out" || true)"
    echo "record: could not commit .tickets/$id/ (${why:-$(printf '%s' "$out" | tail -1)}); nothing changed, commit it by hand"; return 0
  fi
  sha="$(git -C "$root" rev-parse --short HEAD)"
  # shellcheck disable=SC2034  # RECORDED is read by the callers (tkt merge-pr, sprint's Manual close)
  RECORDED=true
  if ! git -C "$root" remote get-url origin >/dev/null 2>&1; then echo "record: committed $sha ($msg); no origin to push to"; return 0; fi
  # the push also publishes the base's other local commits (a diverged merge's merge commit): say so
  ahead="$(git -C "$root" rev-list --count "refs/remotes/origin/$base..HEAD" 2>/dev/null || echo 1)"; ahead=$((ahead - 1)); note=""
  (( ahead <= 0 )) || { note=" (with $ahead earlier local commit"; (( ahead == 1 )) || note+="s"; note+=")"; }
  if out="$(git -C "$root" push -q origin "refs/heads/$base:refs/heads/$base" < /dev/null 2>&1)"; then
    echo "record: committed $sha ($msg) and pushed $base to origin$note"
  else
    echo "record: committed $sha ($msg) here; the push was refused ($(printf '%s' "$out" | tail -1)); push it: git push origin $base"
  fi
  return 0
}

# decisions_seed_header — t-00d3: the four lines `sprint start` seeds DECISIONS.md with (ensure_context_files); one owner, also the only
# header a cloud PR may create the file with (late_docs_delta).
decisions_seed_header() { printf '# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n'; }

# decisions_added_rows <git-dir> <from> <to> — t-7d84: the lines DECISIONS.md gains from <from> to <to>, one per line, CRs dropped; the
# rows late_docs_delta accepts and merge-pr / import-results print. Exits non-zero when git cannot tell.
decisions_added_rows() {
  local d out
  d="$(git -C "$1" -c core.quotepath=off diff -U0 --no-renames "$2" "$3" -- DECISIONS.md 2>/dev/null)" || return 1
  # only lines inside a hunk: before the first @@ are the ---/+++ headers; an added line whose text starts "++ " also shows as "+++ "
  out="$(printf '%s\n' "$d" | awk '/^@@/{ h = 1; next } !h { next } /^\+/{ s = substr($0, 2); sub(/\r$/, "", s); print s }')"
  # t-00d3: a file the PR creates starts with canon's seed header; only an exact match is dropped (other text stays and fails the row rule)
  local hdr; hdr="$(decisions_seed_header)"   # a string prefix compare, no early-exit pipe (pipefail)
  if ! git -C "$1" cat-file -e "$2:DECISIONS.md" 2>/dev/null && [[ "$out" == "$hdr" || "$out" == "$hdr"$'\n'* ]]; then
    out="${out#"$hdr"}"; out="${out#$'\n'}"; [[ -z "$out" ]] || printf '%s\n' "$out"
  else printf '%s\n' "$out"; fi
}

# late_docs_delta <git-dir> <graded> <head> <ticket-id> [local] — t-fdb1: prints the files changed from graded to head, one per line.
# Returns 0 when head descends from graded and every file is a merge-safe late doc, the audit log with lines only added, or sits in
# .tickets/<ticket-id>/ (no dotfile component; an empty delta included), 1 when a file is not, or any changed path becomes a symlink or a submodule (they are the
# ones printed), 2 when graded is not an ancestor of head, the id is not a plain ticket id, or git cannot tell (prints the reason).
# A rename counts both paths. `local` (tkt merge of a worktree branch) also takes the close's own docs (late_doc_path). A late doc at
# the root that head deletes is not late in any mode: a delete is no close's write (t-2a95).
late_docs_delta() {
  local dir="$1" graded="$2" head="$3" id="$4" mode="${5:-}" files other p
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "not a ticket id: $id"; return 2; }
  git -C "$dir" merge-base --is-ancestor "$graded" "$head" 2>/dev/null \
    || { echo "graded-head ${graded:0:7} is not an ancestor of ${head:0:7}"; return 2; }
  files="$(git -C "$dir" -c core.quotepath=off diff --no-renames --name-only "$graded" "$head" 2>&1)" \
    || { echo "git could not list the files from ${graded:0:7} to ${head:0:7}: $files"; return 2; }
  other=""
  while IFS= read -r p; do [[ -z "$p" ]] || late_doc_path "$p" "$id" "$mode" || other+="$p"$'\n'; done <<< "$files"
  local gone; gone="$(git -C "$dir" -c core.quotepath=off diff --no-renames --name-only --diff-filter=D "$graded" "$head" 2>&1)" \
    || { echo "git could not list the files deleted from ${graded:0:7} to ${head:0:7}: $gone"; return 2; }
  while IFS= read -r p; do [[ -n "$p" && "$p" != */* ]] && late_doc_path "$p" "$id" "$mode" && other+="$p (deleted)"$'\n'; done <<< "$gone"
  other="$(printf '%s' "$other" | grep . || true)"
  # t-75f5: the audit log passes only when lines were added and none removed (a binary file shows "-"; a rewrite shows removals).
  if [[ $'\n'"$other"$'\n' == *$'\n'"$MERGE_SAFE_AUDIT_LOG"$'\n'* ]]; then
    local ns add del _rest kept="" ln grew=false
    ns="$(git -C "$dir" -c core.quotepath=off diff --numstat --no-renames "$graded" "$head" -- "$MERGE_SAFE_AUDIT_LOG" 2>&1)" \
      || { echo "git could not count the lines of $MERGE_SAFE_AUDIT_LOG from ${graded:0:7} to ${head:0:7}: $ns"; return 2; }
    read -r add del _rest <<< "$ns"
    [[ "$add" =~ ^[0-9]+$ && "$add" -gt 0 && "$del" == 0 ]] && grew=true   # "0 0" is a mode-only change or an empty log removed: not growth
    while IFS= read -r ln; do
      if [[ "$ln" != "$MERGE_SAFE_AUDIT_LOG" ]]; then kept+="$ln"$'\n'
      elif ! $grew; then kept+="$ln (rewritten; not appended)"$'\n'; fi
    done <<< "$other"
    other="$kept"
  fi
  # t-dfaf: canon writes the Recent activity block into HANDOFF.md at `sprint complete`, always after the grade, so a cloud run's PR head
  # differs from graded-head by that block. HANDOFF.md passes only when graded and head are identical with the block removed (CRs ignored;
  # `recent --strip` is the rule merge-pr uses for a local copy). Any other change, an unreadable blob or a board without `recent` keeps it refused.
  if [[ $'\n'"$other"$'\n' == *$'\nHANDOFF.md\n'* ]]; then
    local rb t1 t2 same=false
    if rb="$(recent_board 2>/dev/null)"; then
      t1="$(mktemp)"; t2="$(mktemp)"
      if ( set -o pipefail; git -C "$dir" cat-file blob "$graded:HANDOFF.md" 2>/dev/null | "$rb" recent --strip | LC_ALL=C tr -d '\r' ) > "$t1" \
        && ( set -o pipefail; git -C "$dir" cat-file blob "$head:HANDOFF.md" 2>/dev/null | "$rb" recent --strip | LC_ALL=C tr -d '\r' ) > "$t2" \
        && cmp -s "$t1" "$t2"; then
        git -C "$dir" cat-file blob "$head:HANDOFF.md" 2>/dev/null > "$t2" && _handoff_block_ok "$t2" && same=true
      fi
      rm -f "$t1" "$t2"
    fi
    $same && other="$(printf '%s\n' "$other" | grep -vx 'HANDOFF.md' || true)"
  fi
  # t-7d84: a cloud close writes its DECISIONS.md row at complete.md step 6, after the grade (user, 2026-11-17: accept it). DECISIONS.md
  # passes only when lines were added and none removed, and every added line is a table row `| YYYY-MM-DD | <decision> | <reason> |`
  # (t-00d3: bold optional, a cloud agent writes it either way) that names this ticket (it may cite others too). The file exists at both
  # ends, or (t-00d3) the PR creates it starting with canon's exact seed header. An edit, a removal, a row for another ticket only, or any
  # other line keeps it refused.
  if [[ $'\n'"$other"$'\n' == *$'\nDECISIONS.md\n'* ]]; then
    local dns dadd ddel _dr drows dok=false ln nrows=0
    local dhdr=0   # t-00d3: a file the PR creates carries the 4-line seed header before its rows
    git -C "$dir" cat-file -e "$graded:DECISIONS.md" 2>/dev/null || dhdr=4
    if git -C "$dir" cat-file -e "$head:DECISIONS.md" 2>/dev/null \
      && dns="$(git -C "$dir" diff --numstat --no-renames "$graded" "$head" -- DECISIONS.md 2>/dev/null)"; then
      read -r dadd ddel _dr <<< "$dns"
      [[ "$dadd" =~ ^[0-9]+$ ]] && dadd=$((dadd - dhdr))
      # 1 to 3 rows, each `| YYYY-MM-DD | <decision> | <reason> |` (four cell bars, both cells non-empty, bold optional: t-00d3), no control
      # character, naming this ticket; and every line git counts as added (less an exact seed header) must be one of them (t-7d84 reviewer
      # + security review: a "++ " line hid as a diff header)
      if [[ "$dadd" =~ ^[0-9]+$ && "$dadd" -ge 1 && "$dadd" -le 3 && "$ddel" == 0 ]] && drows="$(decisions_added_rows "$dir" "$graded" "$head")"; then
        dok=true
        while IFS= read -r ln; do
          nrows=$((nrows + 1))
          [[ "$ln" =~ ^\|\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ \|\ [^|\ ][^|]*\|\ [^|\ ][^|]*\ \|$ ]] && [[ ! "$ln" =~ [[:cntrl:]] ]] \
            && [[ "$ln" =~ (^|[^A-Za-z0-9-])$id([^A-Za-z0-9-]|$) ]] || { dok=false; break; }
        done <<< "$drows"
        [[ "$nrows" == "$dadd" ]] || dok=false
      fi
    fi
    $dok && other="$(printf '%s\n' "$other" | grep -vx 'DECISIONS.md' || true)"
  fi
  # A name is not the content: a symlink (120000) or submodule (160000) under an allowed name points somewhere else.
  local raw; raw="$(git -C "$dir" -c core.quotepath=off diff --raw --no-renames "$graded" "$head" 2>&1)" \
    || { echo "git could not list the file modes from ${graded:0:7} to ${head:0:7}: $raw"; return 2; }
  other+="$(printf '%s\n' "$raw" | awk -F'\t' '{ split($1, m, " "); if (m[2] == "120000" || m[2] == "160000") print "\n" $2 " (symlink or submodule)" }')"
  other="$(printf '%s\n' "$other" | grep . || true)"
  if [[ -n "$other" ]]; then printf '%s\n' "$other"; return 1; fi
  printf '%s\n' "$files" | grep . || true
}

# t-b2ff: canon must not treat a system folder or a drive root as a project (t-dec4: the home folder is one; tickets_dir stops its walk there) (an Administrator PowerShell opens in
# C:\Windows\System32; canon there would serve, then fill, a folder nobody keeps tickets in). folder_guard_reason <dir> prints why
# <dir> is refused, or nothing. The same table is common.NotAProject in tools/canon-go/internal/common/folderguard.go (the board);
# tests/folder-guard.sh and its Go test run one corpus through both. A .git at <dir> (inside the Windows tree: at it or above it)
# makes it a project; a .tickets folder never does. Git Bash shows C:\Windows as /c/windows; a C:\ form is accepted too.
folder_guard_reason() {
  local raw="$1" form dir why
  case "$raw" in
    [A-Za-z]:*) _folder_guard_one "$raw"; return 0 ;;
  esac
  # as given and with links resolved (/etc is /private/etc on macOS)
  for form in "$(cd "$raw" 2>/dev/null && pwd -L)" "$(cd "$raw" 2>/dev/null && pwd -P)"; do
    [[ -n "$form" ]] || continue
    why="$(_folder_guard_one "$form")"
    [[ -z "$why" ]] || { printf '%s\n' "$why"; return 0; }
  done
}

# _folder_guard_one <absolute path or C:\ form>: the reason for that one spelling of a folder, or nothing.
_folder_guard_one() {
  local dir="$1" p why="" tree=0 d
  case "$dir" in
    # t-c8c6: a C:\ form is walked as /c/...: canon's key, then lower-cased (the guard's table ignores case, as its Go twin does). platform-lib.sh
    # is loaded only here, when a caller that sources this file alone (evidence.sh, the tests) meets a C: form.
    [A-Za-z]:*)
      # shellcheck source=platform-lib.sh
      declare -F canon_path_key >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"
      p="$(canon_path_key "$dir" | tr 'A-Z' 'a-z')"; dir="$p" ;;
    *) p="$(printf '%s' "$dir" | tr 'A-Z' 'a-z')" ;;
  esac
  p="${p%/}"; [[ -n "$p" ]] || p="/"
  case "$p" in
    /|/[a-z]) why="the root of a drive" ;;
    /[a-z]/windows|/[a-z]/windows/*) why="a system folder"; tree=1 ;;
    "/"[a-z]"/program files"|"/"[a-z]"/program files (x86)"|/[a-z]/programdata) why="a system folder" ;;
    /usr|/bin|/sbin|/etc|/var|/private/etc|/private/var|/opt|/system|/library|/applications) why="a system folder" ;;
  esac
  [[ -n "$why" ]] || return 0
  d="$dir"
  while :; do
    [[ -e "$d/.git" ]] && return 0
    [[ "$tree" == 1 && "$d" != "/" && "$d" != "$(dirname "$d")" ]] || break
    d="$(dirname "$d")"
  done
  printf '%s\n' "$why"
}

# require_project_folder <tool>: refuse, from main() of tkt, sprint and canon (exit ends the real shell, never a $(...) subshell),
# when the folder canon would use is not a project. Nothing is created.
require_project_folder() {
  local tool="$1" dir why
  dir="$(dirname "$(tickets_dir)")"
  why="$(folder_guard_reason "$dir")"
  [[ -z "$why" ]] && return 0
  # t-5738/t-dec4: say where to go (a first-time user has no project folder yet), in the user's own shell form: on Windows the folder is
  # C:\Users\x (not Git Bash's /c/Users/x) and the example works in PowerShell, cmd and Git Bash. Same words as common.NotAProjectMessage
  # (internal/common/folderguard.go); tests/folder-guard.sh compares them. CANON_HOST_OS is a test hook for uname.
  local shown home_shown demo mk sep=/
  shown="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"; home_shown="${HOME:-~}"; mk="mkdir -p"
  case "${CANON_HOST_OS:-$(uname -s 2>/dev/null)}" in
    MINGW*|MSYS*|CYGWIN*)
      sep='\'; mk='mkdir'
      if command -v cygpath >/dev/null 2>&1; then shown="$(cygpath -w "$shown" 2>/dev/null || printf '%s' "$shown")"; home_shown="$(cygpath -w "$home_shown" 2>/dev/null || printf '%s' "$home_shown")"; fi ;;
  esac
  demo="$home_shown${sep}projects${sep}demo"
  echo "$tool: $shown is not a project ($why with no git repository). Make a folder for your work, for example: $mk \"$demo\", cd into it, run git init, then run $tool again." >&2
  exit 1
}

# copy_ticket_back <id> <ticket.md of that ticket> — t-3abc: a sprint closed in a worktree that holds its OWN copy of the ticket (an
# adopted worktree, .tickets/ gitignored) leaves main's copy 'open' once the worktree is removed. Copy the closed folder to the main
# checkout's .tickets/<id>/: regular files and subfolders only (find -type f never follows a link), never a .cockpit-* marker (main's
# lock and adopt files), and main's per-machine ticket.md lines (github, runs, merged, cloud_status) stay main's. Nothing happens when
# the ticket is already main's (no worktree copy: tkt land, a plain worktree), when .tickets/ is tracked (the merge carries it), or when
# main has no folder for it. A failure prints one warning and returns 0: it never fails the close.
copy_ticket_back() {
  local id="$1" file="$2" own proj common main old k val
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 0
  own="$(dirname "$(dirname "$file")")"; proj="$(dirname "$own")"
  common="$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [[ "$(basename "$common")" == .git ]] || return 0
  main="$(dirname "$common")/.tickets"
  [[ -d "$main/$id" ]] || return 0
  [[ "$(cd "$own" && pwd -P)" != "$(cd "$main" && pwd -P)" ]] || return 0
  git -C "$proj" check-ignore -q .tickets 2>/dev/null || return 0
  # t-f7e6: the source is the worktree's copy, which its branch controls: a linked .tickets or ticket folder there would copy outside files in
  wt_write_ok "$own/$id/ticket.md" || { echo "warning: did not copy $id back to $main/$id" >&2; return 0; }
  old="$(mktemp)" || return 0
  cp "$main/$id/ticket.md" "$old" 2>/dev/null || : > "$old"
  if ! { (cd "$own/$id" && find . -type f ! -name '.cockpit-*' -print0) \
         | while IFS= read -r -d '' f; do mkdir -p "$main/$id/$(dirname "$f")" && cp -p "$own/$id/$f" "$main/$id/$f" || exit 1; done; }; then
    echo "warning: could not copy $id back to $main/$id: a file could not be written there (is the folder writable?)" >&2; rm -f "$old"; return 0
  fi
  for k in github runs merged cloud_status; do
    val="$(grep -m1 "^$k:" "$old" || true)"; [[ -n "$val" ]] || continue
    awk -v key="$k" -v line="$val" 'BEGIN { n = 0; rep = 0 }
      /^---$/ { n++; if (n == 2 && !rep) { print line; rep = 1 } }
      n == 1 && index($0, key ":") == 1 && !rep { print line; rep = 1; next }
      { print }' "$main/$id/ticket.md" > "$main/$id/ticket.md.tmp" && mv "$main/$id/ticket.md.tmp" "$main/$id/ticket.md" \
      || { echo "warning: could not restore main's $k line in $main/$id/ticket.md: the file could not be rewritten" >&2; rm -f "$main/$id/ticket.md.tmp"; }
  done
  rm -f "$old"
  echo "copied $id's closed folder back to $main/$id"
}

# manual_criteria <acceptance.md> <lines|strip|numbered> — t-aa24, t-e790: the one rule for a [manual] criterion: a checkbox bullet (- or *) under
# `## Criteria` whose text starts with [manual] (any case), outside a fenced block. lines: those lines as written; strip: the file without them;
# numbered: "<n>\t<text>" (n counted among all criteria), as `sprint check-evidence` lists them. Reads at most 256 KiB, CRs dropped.
manual_criteria() {
  [[ -f "$1" && ! -L "$1" ]] || return 0
  head -c 262144 -- "$1" | LC_ALL=C tr -d '\r' | LC_ALL=C awk -v mode="$2" '
    /^[[:space:]]*```/ { fence = !fence; if (mode == "strip") print; next }
    fence { if (mode == "strip") print; next }
    /^##[[:space:]]/ { inc = ($0 ~ /^##[[:space:]]+Criteria[[:space:]]*$/); if (mode == "strip") print; next }
    inc && /^[[:space:]]*[-*] \[[ xX]\][[:space:]]+[^[:space:]]/ {
      n++; t = $0; sub(/^[[:space:]]*[-*] \[[ xX]\][[:space:]]+/, "", t)
      if (tolower(substr(t, 1, 8)) == "[manual]") {
        if (mode == "lines") print
        else if (mode == "numbered") { t = substr(t, 9); sub(/^[[:space:]]+/, "", t); print n "\t" substr(t, 1, 100) }
        next
      }
    }
    mode == "strip" { print }'
}

# _canon_setup_edit_only <wroot> <graded> <path> [<have-rev>] — t-52f0 (moved here from tools/sprint by t-e9aa): true when the project-root .gitignore or .gitattributes at <path> is exactly
# what canon's own skill setup makes of the graded file, so _gate_eval_report_fresh (below) can let registration's uncommitted edit
# through (without it a fresh project's first close was refused). It replays the real writers, never a copy of their lines: the graded
# file as git checks it out (`cat-file --filters`), in a scratch repo, through _ensure_mirror_gitignored alone (a project's own
# .claude/agents gets no line), then _ensure_agents_link_gitignored in either order (skills add: mirror first; link_worktree: agents
# first), or through ensure_gitattributes; the working-tree file must match one result line for line, a carriage return at the end of a line aside (t-ae3b: autocrlf). Order, duplicates and a CR inside a line therefore count (break-it found a line-set check too loose). A
# symlink, a deleted file or a failed git call is false. t-e9aa: with <have-rev>, that commit's copy is compared instead of the working
# tree's (a committed canon-only edit); the writers are found next to this file (BASH_SOURCE), not through the caller's SCRIPT_DIR.
_canon_setup_edit_only() (   # a subshell, so its EXIT trap removes the scratch repo on any exit without touching the caller's traps
  wroot="$1" graded="$2" path="$3" name="${3##*/}" haverev="${4:-}"
  case "$name" in
    .gitignore) variants="m ma am" ;;
    .gitattributes) variants="g" ;;
    *) exit 1 ;;
  esac
  if [[ -z "$haverev" ]]; then [[ -f "$wroot/$path" && ! -L "$wroot/$path" ]] || exit 1; fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canon-gate.XXXXXX")" || exit 1   # a template: macOS mktemp -d alone ignores TMPDIR
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q >/dev/null 2>&1 || exit 1
  git -C "$wroot" cat-file --filters "$graded:$path" > "$tmp/prior" 2>/dev/null || exit 1
  for v in $variants; do
    cp "$tmp/prior" "$tmp/$name" || exit 1
    # shellcheck disable=SC2034  # SKILLS_ROOT is read by the skills libs sourced next
    ( SKILLS_ROOT="$(cd "$_CANON_TOOLS/.." && pwd)"
      source "$_CANON_TOOLS/skills/lib.sh" && source "$_CANON_TOOLS/skills/project.sh" && source "$_CANON_TOOLS/skills/prompts.sh" || exit 1
      case "$v" in
        m) _ensure_mirror_gitignored "$tmp" ;;
        ma) _ensure_mirror_gitignored "$tmp" && _ensure_agents_link_gitignored "$tmp" ;;
        am) _ensure_agents_link_gitignored "$tmp" && _ensure_mirror_gitignored "$tmp" ;;
        g) ensure_gitattributes "$tmp" ;;
      esac ) >/dev/null 2>&1 || true   # the byte compare below is the check, not the writer's status
    # Line endings are not what this guards: with core.autocrlf=true the replayed old file comes back CRLF while a project file written
    # by a tool is LF (t-ae3b), so compare with a carriage return at the END of a line removed (one inside a line still differs).
    awk '{ sub(/\r$/, "") } 1' "$tmp/$name" > "$tmp/want.lf"
    if [[ -n "$haverev" ]]; then git -C "$wroot" cat-file --filters "$haverev:$path" 2>/dev/null | awk '{ sub(/\r$/, "") } 1' > "$tmp/have.lf" || exit 1
    else awk '{ sub(/\r$/, "") } 1' "$wroot/$path" > "$tmp/have.lf"; fi
    cmp -s "$tmp/want.lf" "$tmp/have.lf" && exit 0
    diff "$tmp/want.lf" "$tmp/have.lf" > "$tmp/d.$v" 2>/dev/null || true
  done
  # No variant matched: say how the file differs from canon's own edit (the closest variant's diff), so a refusal is not a bare "changed" (t-ae3b).
  echo "note: $path differs from canon's own setup edit (closest diff, canon's edit vs the file):"
  local best="" bn=999999 n d
  for d in "$tmp"/d.*; do
    [ -f "$d" ] || continue
    n="$(wc -l < "$d" | tr -d ' ')"
    if [ "$n" -lt "$bn" ]; then bn="$n"; best="$d"; fi
  done
  [ -z "$best" ] || sed -n '1,4p' "$best" | cat -v | cut -c1-120 | sed 's/^/  /'
  exit 1
)

# canon_drop_setup_edits <root> <from-rev> [<to-rev>] — t-e9aa: reads changed paths (one per line) on stdin and prints those canon's own
# setup edit does not explain: a repo-root .gitignore or .gitattributes whose copy at <to-rev> (the working tree when absent) is exactly
# what canon's writers make of <from-rev>'s copy is dropped. One predicate for the evidence stamp, check's freshness and the manual-QA
# record; the helper's notes never reach the caller's output.
canon_drop_setup_edits() {
  local root="$1" from="$2" to="${3:-}" p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ "$p" == .gitignore || "$p" == .gitattributes ]] && _canon_setup_edit_only "$root" "$from" "$p" ${to:+"$to"} >/dev/null 2>&1; then continue; fi
    printf '%s\n' "$p"
  done
}
