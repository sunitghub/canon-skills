#!/usr/bin/env bash

tickets_dir() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    # t-5738: a .tickets in a folder the guard refuses (the home folder, a drive root, a system folder) is not a project's: a stray
    # ~/.tickets made every folder under home resolve to home. Skip it and keep walking; a .git there still counts.
    if [[ -d "$dir/.tickets" ]] && [[ -z "$(folder_guard_reason "$dir")" ]]; then echo "$dir/.tickets"; return 0; fi
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

# Late docs written after the evaluator grades that a merge may carry unreviewed (t-fdb1): the learnings sweep's two files, which
# the cloud commits after its gates (complete.md step 8). One owner for these names: tools/sprint's stale-eval gate (t-1b74) builds
# its wider list from them; merge-pr and import-results add only the merged ticket's own folder (late_docs_delta). Residual risk,
# accepted: every sprint start reads LEARNINGS.md (start.md), so an unreviewed row from a cloud branch reaches agents; merge-pr
# names the files before it asks. The always-loaded and start-read docs (AGENTS.md, CLAUDE.md, PROMOTED.md, HANDOFF.md,
# DECISIONS.md) and other tickets' folders are not here.
MERGE_SAFE_LATE_ALT='LEARNINGS\.md$|LEARNINGS-archive\.md$'

# late_docs_delta <git-dir> <graded> <head> <ticket-id> — t-fdb1: prints the files changed from graded to head, one per line.
# Returns 0 when head descends from graded and every file is a merge-safe late doc or sits in .tickets/<ticket-id>/ (no dotfile
# component; an empty delta included), 1 when a file is not, or any changed path becomes a symlink or a submodule (they are the
# ones printed), 2 when graded is not an ancestor of head, the id is not a plain ticket id, or git cannot tell (prints the reason).
# A rename counts both paths.
late_docs_delta() {
  local dir="$1" graded="$2" head="$3" id="$4" files other
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "not a ticket id: $id"; return 2; }
  git -C "$dir" merge-base --is-ancestor "$graded" "$head" 2>/dev/null \
    || { echo "graded-head ${graded:0:7} is not an ancestor of ${head:0:7}"; return 2; }
  files="$(git -C "$dir" -c core.quotepath=off diff --no-renames --name-only "$graded" "$head" 2>&1)" \
    || { echo "git could not list the files from ${graded:0:7} to ${head:0:7}: $files"; return 2; }
  other="$(printf '%s\n' "$files" | grep . | grep -vE "^($MERGE_SAFE_LATE_ALT|\\.tickets/$id/([^./][^/]*/)*[^./][^/]*$)" || true)"
  # A name is not the content: a symlink (120000) or submodule (160000) under an allowed name points somewhere else.
  local raw; raw="$(git -C "$dir" -c core.quotepath=off diff --raw --no-renames "$graded" "$head" 2>&1)" \
    || { echo "git could not list the file modes from ${graded:0:7} to ${head:0:7}: $raw"; return 2; }
  other+="$(printf '%s\n' "$raw" | awk -F'\t' '{ split($1, m, " "); if (m[2] == "120000" || m[2] == "160000") print "\n" $2 " (symlink or submodule)" }')"
  other="$(printf '%s\n' "$other" | grep . || true)"
  if [[ -n "$other" ]]; then printf '%s\n' "$other"; return 1; fi
  printf '%s\n' "$files" | grep . || true
}

# t-b2ff: canon must not treat a system folder, a drive root or the home folder as a project (an Administrator PowerShell opens in
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
  local dir="$1" p why="" tree=0 d h
  case "$dir" in
    [A-Za-z]:*) p="$(printf '%s' "$dir" | tr 'A-Z\\' 'a-z/')"; p="/${p%%:*}${p#*:}"; dir="$p" ;;   # a C:\ form is walked as /c/...
    *) p="$(printf '%s' "$dir" | tr 'A-Z' 'a-z')" ;;
  esac
  p="${p%/}"; [[ -n "$p" ]] || p="/"
  case "$p" in
    /|/[a-z]) why="the root of a drive" ;;
    /[a-z]/windows|/[a-z]/windows/*) why="a system folder"; tree=1 ;;
    "/"[a-z]"/program files"|"/"[a-z]"/program files (x86)"|/[a-z]/programdata) why="a system folder" ;;
    /usr|/bin|/sbin|/etc|/var|/private/etc|/private/var|/opt|/system|/library|/applications) why="a system folder" ;;
    *)
      if [[ -n "${HOME:-}" ]]; then
        h="$(cd "$HOME" 2>/dev/null && pwd -P)" || h=""
        [[ -n "$h" && "$(printf '%s' "$dir" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$h" | tr 'A-Z' 'a-z')" ]] && why="your home folder"
      fi ;;
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
  # t-5738: say where to go (a first-time user has no project folder yet), and when the refused folder holds tickets from an earlier run, how to move them
  local shown demo; shown="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"; demo="${HOME:-~}/projects/demo"
  echo "$tool: $shown is not a project ($why with no git repository). Make a folder for your work, for example: mkdir -p \"$demo\", cd into it, run git init, then run $tool again." >&2
  if [[ "$why" == "your home folder" ]] && compgen -G "$dir/.tickets/*/ticket.md" >/dev/null 2>&1; then
    echo "$tool: $shown has a .tickets folder with tickets in it, left by an earlier run. If they belong to a project, move the folder into it (nothing here moves it for you): mv \"$dir/.tickets\" \"$demo/.tickets\"" >&2
  fi
  exit 1
}
