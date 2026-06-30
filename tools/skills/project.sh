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
    [ -d "$link" ] && cmd.exe /c rmdir "$(cygpath -w "$link")" > /dev/null 2>&1 || true
    cmd.exe /c mklink /J "$(cygpath -w "$link")" "$(cygpath -w "$target")" > /dev/null
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
    cmd.exe /c rmdir "$(cygpath -w "$link")" > /dev/null 2>&1
  else
    rm "$link"
  fi
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
