#!/usr/bin/env bash
# tools/skills/project.sh — project registration and symlink management

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
    if [ -L "$link" ]; then
      [ "$(readlink "$link")" = "$target" ] && continue
      ln -sfn "$target" "$link"
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
      ln -sfn "$target" "$link"
      echo "  [symlink]  created: $link"
    fi
  done
}

remove_skills_symlinks() {
  local project_dir="$1" skill_file="${2:-}" target="$SKILLS_ROOT/skills"
  local link
  for link in "$project_dir/.claude/skills" "$project_dir/.agents/skills"; do
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
      rm "$link"
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
