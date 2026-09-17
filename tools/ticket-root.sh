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
      [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
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
