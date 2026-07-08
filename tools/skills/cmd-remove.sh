#!/usr/bin/env bash
# tools/skills/cmd-remove.sh — skills.sh remove

cmd_remove() {
  local skill="${1:-}"
  local project_dir="${2:-$(pwd)}"

  [ -z "$skill" ] && { echo "Usage: skills.sh remove <skill-name> [project-dir]"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found."
    exit 1
  }

  if [ "$(fm_field "$skill_file" inject)" = "true" ]; then
    local inject_line="@$skill_file"
    local claude_file="$project_dir/CLAUDE.md"
    local agents_file="$project_dir/AGENTS.md"
    for f in "$claude_file" "$agents_file"; do
      [ -f "$f" ] || continue
      if grep -qxF "$inject_line" "$f"; then
        awk -v p="$inject_line" '$0 != p' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        echo "  [$(basename "$f")]  removed @-import"
      fi
    done
    if [ -f "$agents_file" ] && grep -qF "| $skill |" "$agents_file"; then
      grep -vF "| $skill |" "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
      echo "  [AGENTS.md]  removed table row"
      skills_table_prune_if_empty "$agents_file"
    fi
    [ "$skill" = "efficiency" ] && offer_remove_model_tiers_note "$project_dir"
    echo "Unregistered: $skill"
    if [ -z "$(registered_skill_names "$agents_file" 2>/dev/null)" ] && \
       ! grep -qF "$SKILLS_ROOT" "$claude_file" 2>/dev/null && \
       ! grep -qF "$SKILLS_ROOT" "$agents_file" 2>/dev/null; then
      deregister_project "$project_dir"
    fi
    return 0
  fi

  local agents_file="$project_dir/AGENTS.md"
  if [ -f "$agents_file" ] && grep -qF "| $skill |" "$agents_file"; then
    grep -vF "| $skill |" "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
    echo "  [AGENTS.md]  removed"
    skills_table_prune_if_empty "$agents_file"
  fi

  echo "Unregistered: $skill"

  remove_skills_symlinks "$project_dir" "$skill_file"

  if [ -z "$(registered_skill_names "$agents_file" 2>/dev/null)" ]; then
    deregister_project "$project_dir"
    remove_skills_symlinks "$project_dir"
  fi
}
