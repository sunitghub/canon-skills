#!/usr/bin/env bash
# tools/skills/project.sh — project registration and symlink management

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|CYGWIN*|MSYS*) return 0 ;; esac
  return 1
}

# Create a directory symlink (Unix) or junction (Windows — no elevated rights needed).
_create_dir_link() {
  local target="$1" link="$2"
  if _is_windows; then
    # mklink /J fails if a junction already exists — remove before recreating
    # MSYS_NO_PATHCONV: without it, Git Bash mangles the /c flag into a Windows
    # path, so cmd.exe opens interactively instead of running the command.
    [ -d "$link" ] && MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$(cygpath -w "$link")" > /dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(cygpath -w "$link")" "$(cygpath -w "$target")" > /dev/null
  else
    ln -sfn "$target" "$link"
  fi
}

# Return the target of a directory symlink/junction, or empty string if not one.
_read_dir_link() {
  local link="$1"
  if _is_windows; then
    powershell.exe -NoProfile -Command \
      "\$i=Get-Item -LiteralPath '$(cygpath -w "$link")' -EA SilentlyContinue; if(\$i){\$i.Target}" \
      2>/dev/null | tr -d '\r\n' | cygpath -u -f - 2>/dev/null || true
  else
    readlink "$link"
  fi
}

# True if path is a directory symlink (Unix) or junction (Windows).
_is_dir_link() {
  local link="$1"
  if _is_windows; then
    [ -d "$link" ] && \
      powershell.exe -NoProfile -Command \
        "\$i=Get-Item -LiteralPath '$(cygpath -w "$link")' -EA SilentlyContinue; if(\$i){(\$i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}" \
        2>/dev/null | tr -d '\r\n' | grep -qi "true"
  else
    [ -L "$link" ]
  fi
}

# Remove a directory symlink (Unix) or junction (Windows) without touching contents.
_remove_dir_link() {
  local link="$1"
  if _is_windows; then
    MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$(cygpath -w "$link")" > /dev/null 2>&1
  else
    rm "$link"
  fi
}

# t-f99b: the skill mirror (.claude/skills, .agents/skills) is a LOCAL link to
# canon's skills — it must never be committed. On Windows a junction is
# git-visible (git tracks its CONTENTS as files), so a consumer `git add -A`
# would commit stale copies that a worktree/old checkout then serves (this
# masked t-720c). Ensure the project gitignores the mirror dirs, and untrack the
# mirror if a prior commit already captured it. Only the two mirror dirs, never
# the parent .claude/.agents (which may hold other tracked config). No-op when
# the project isn't a git work tree.
_ensure_mirror_gitignored() {
  local project_dir="$1"
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local gi="$project_dir/.gitignore" entry rel
  for entry in "/.claude/skills/" "/.agents/skills/"; do
    if ! grep -qxF "$entry" "$gi" 2>/dev/null; then
      printf '%s\n' "$entry" >> "$gi"
      echo "  [gitignore] $entry"
    fi
    rel="${entry#/}"; rel="${rel%/}"
    if [ -n "$(git -C "$project_dir" ls-files -- "$rel" 2>/dev/null | head -1)" ]; then
      git -C "$project_dir" rm -r --cached --quiet -- "$rel" >/dev/null 2>&1 || true
      echo "  [gitignore] untracked previously-committed mirror: $rel"
    fi
  done
}

# t-f99b: create the skills link inside a git worktree so it resolves to CURRENT
# canon (never a stale committed copy). Called by the board's createWorktree
# (via `skills.sh link-worktree <path>`) — a git worktree, being gitignored, has
# no mirror of its own otherwise. Skips a real (project-local) skills dir.
link_worktree() {
  local wt_dir target link
  wt_dir="$(cd "${1:-}" 2>/dev/null && pwd)" || { echo "link-worktree: no such dir: ${1:-}" >&2; return 1; }
  target="$SKILLS_ROOT/skills"
  for link in "$wt_dir/.claude/skills" "$wt_dir/.agents/skills"; do
    if _is_dir_link "$link"; then
      [ "$(_read_dir_link "$link")" = "$target" ] && continue
      _create_dir_link "$target" "$link"
    elif [ -e "$link" ]; then
      continue   # a real dir (project-local skills) — leave it alone
    else
      mkdir -p "$(dirname "$link")"
      _create_dir_link "$target" "$link"
    fi
    echo "  [worktree-link] $link -> $target"
  done
  _ensure_mirror_gitignored "$wt_dir"
}

register_project() {
  local project_dir
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [[ "$project_dir" == "$SKILLS_ROOT" ]] && return 0
  mkdir -p "$(dirname "$PROJECTS_FILE")"
  grep -qxF "$project_dir" "$PROJECTS_FILE" 2>/dev/null || echo "$project_dir" >> "$PROJECTS_FILE"
}

deregister_project() {
  local project_dir
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [ -f "$PROJECTS_FILE" ] || return 0
  local tmp
  tmp=$(mktemp)
  grep -vxF "$project_dir" "$PROJECTS_FILE" > "$tmp" || true
  mv "$tmp" "$PROJECTS_FILE"
  [ -s "$PROJECTS_FILE" ] || rm -f "$PROJECTS_FILE"
}

upsert_skills_symlinks() {
  local project_dir="$1" skill_file="${2:-}" target="$SKILLS_ROOT/skills"
  local link
  for link in "$project_dir/.claude/skills" "$project_dir/.agents/skills"; do
    mkdir -p "$(dirname "$link")"
    if _is_dir_link "$link"; then
      [ "$(_read_dir_link "$link")" = "$target" ] && continue
      _create_dir_link "$target" "$link"
      echo "  [symlink]  updated: $link"
    elif [ -d "$link" ]; then
      # Real directory (project has local skills) — create per-skill entry instead
      if [ -n "$skill_file" ]; then
        local skill_name
        skill_name=$(basename "$(dirname "$skill_file")")
        local skill_dir="$link/$skill_name"
        if [ ! -e "$skill_dir" ]; then
          mkdir -p "$skill_dir"
          ln -sfn "$skill_file" "$skill_dir/SKILL.md"
          echo "  [skill-dir]  created: $skill_dir"
        fi
      fi
    else
      _create_dir_link "$target" "$link"
      echo "  [symlink]  created: $link"
    fi
  done
  # t-f99b: never let the (Windows-junction-visible) mirror get committed → stale worktrees.
  _ensure_mirror_gitignored "$project_dir"
}

remove_skills_symlinks() {
  local project_dir="$1" skill_file="${2:-}" target="$SKILLS_ROOT/skills"
  local link
  for link in "$project_dir/.claude/skills" "$project_dir/.agents/skills"; do
    if _is_dir_link "$link"; then
      if [ -z "$skill_file" ] && [ "$(_read_dir_link "$link")" = "$target" ]; then
        _remove_dir_link "$link"
      fi
    elif [ -d "$link" ] && [ -n "$skill_file" ]; then
      # Real directory — remove per-skill entry if it was canon-managed
      local skill_name
      skill_name=$(basename "$(dirname "$skill_file")")
      local skill_dir="$link/$skill_name"
      if [ -d "$skill_dir" ] && [ -L "$skill_dir/SKILL.md" ] && \
         [ "$(readlink "$skill_dir/SKILL.md")" = "$skill_file" ]; then
        rm -rf "$skill_dir"
        echo "  [skill-dir]  removed: $skill_dir"
      fi
    fi
  done
}
