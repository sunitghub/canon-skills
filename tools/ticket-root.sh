#!/usr/bin/env bash

tickets_dir() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -d "$dir/.tickets" ]] && echo "$dir/.tickets" && return 0
    [[ -d "$dir/.git" ]] && echo "$dir/.tickets" && return 0
    # t-cd06: a git-worktree checkout's .git is a FILE ("gitdir: <repo>/.git/
    # worktrees/<name>"), not a directory — the check above never matches it,
    # so a session running inside a worktree used to fall off the walk
    # entirely and find no .tickets at all (live-reproduced: "tkt ls shows no
    # tickets at all" from inside a real worktree). .tickets lives only in the
    # MAIN checkout, never per-worktree, so resolve the gitdir pointer back to
    # the real repo root instead of treating the worktree itself as one.
    if [[ -f "$dir/.git" ]]; then
      local gitdir
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
        */worktrees/*)
          echo "$(dirname "${gitdir%/worktrees/*}")/.tickets"
          return 0
          ;;
      esac
    fi
    dir="$(dirname "$dir")"
  done
  echo "$PWD/.tickets"
}

project_root() {
  dirname "$(tickets_dir)"
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

# Late docs written after the evaluator grades that a merge may carry unreviewed (t-fdb1): records no agent obeys. One owner:
# tools/sprint's stale-eval gate (t-1b74) builds its wider list from this one; merge-pr and import-results use it as is. The
# agent-read late docs (AGENTS.md, CLAUDE.md, PROMOTED.md, HANDOFF.md, DECISIONS.md) are not here: a cloud branch's unreviewed
# edit to them would be instructions in main.
MERGE_SAFE_LATE_ALT='\.tickets/|LEARNINGS\.md$|LEARNINGS-archive\.md$'

# late_docs_delta <git-dir> <graded> <head> — t-fdb1: prints the files changed from graded to head, one per line. Returns 0 when
# head descends from graded and every file is a merge-safe late doc (an empty delta included), 1 when a file is not (they are the
# ones printed), 2 when graded is not an ancestor of head or git cannot tell (prints the reason). A rename counts both paths.
late_docs_delta() {
  local dir="$1" graded="$2" head="$3" files other
  git -C "$dir" merge-base --is-ancestor "$graded" "$head" 2>/dev/null \
    || { echo "graded-head ${graded:0:7} is not an ancestor of ${head:0:7}"; return 2; }
  files="$(git -C "$dir" -c core.quotepath=off diff --no-renames --name-only "$graded" "$head" 2>&1)" \
    || { echo "git could not list the files from ${graded:0:7} to ${head:0:7}: $files"; return 2; }
  other="$(printf '%s\n' "$files" | grep . | grep -vE "^($MERGE_SAFE_LATE_ALT)" || true)"
  if [[ -n "$other" ]]; then printf '%s\n' "$other"; return 1; fi
  printf '%s\n' "$files" | grep . || true
}
