#!/usr/bin/env bash
# tools/skills/cmd-add.sh — skills.sh add

cmd_add() {
  local skill="${1:-}"
  local project_dir="${2:-$(pwd)}"
  local as_dep="${3:-}"  # "dep" when called recursively for a dependency

  [ -z "$skill" ] && { echo "Usage: skills.sh add <skill-name> [project-dir]"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found. Run 'skills.sh list' to see available skills."
    exit 1
  }

  local name desc category
  name=$(fm_field "$skill_file" name)
  desc=$(fm_field "$skill_file" description)
  category=$(fm_field "$skill_file" category)

  # Hidden skills are internal-only — block direct registration
  if [ -z "$as_dep" ] && [ "$(fm_field "$skill_file" hidden)" = "true" ]; then
    echo "Error: '$skill' is an internal skill and cannot be registered directly."
    echo "It is loaded automatically when a parent skill (e.g. wrapup) is registered."
    exit 1
  fi

  # Inject-style skills: write @-import to AGENTS.md (for context injection) AND a
  # table row (for table-only discovery) — both point at the same file.
  if [ "$(fm_field "$skill_file" inject)" = "true" ]; then
    local inject_line="@$skill_file"
    local inject_target="$project_dir/AGENTS.md"
    echo "Registering: $name ($category)"
    if grep -qxF "$inject_line" "$inject_target" 2>/dev/null; then
      echo "  [AGENTS.md]  already present"
    else
      echo "$inject_line" >> "$inject_target"
      echo "  [AGENTS.md]  added @-import"
    fi
    skills_table_upsert "$inject_target" "$name" "| $name | $category | $skill_file |"
    ensure_claude_bridge "$project_dir"
    register_project "$project_dir"
    echo ""
    echo "Done. $desc"
    [ "$name" = "efficiency" ] && offer_model_tiers_note "$project_dir"
    return 0
  fi

  # Resolve dependencies first (no-op for table — deps load via symlink discovery)
  while IFS= read -r dep; do
    [ -n "$dep" ] && cmd_add "$dep" "$project_dir" "dep"
  done < <(resolve_deps "$skill_file")

  [ -n "$as_dep" ] && return 0
  echo "Registering: $name ($category)"

  local agents_file="$project_dir/AGENTS.md"
  local skill_row="| $name | $category | $skill_file |"

  skills_table_upsert "$agents_file" "$name" "$skill_row"
  ensure_claude_bridge "$project_dir"
  _init_claude "$project_dir/.claude/settings.json" 2>/dev/null || true

  echo ""
  echo "Done. $desc"

  _post_register_prompts "$name" "$project_dir" || true
  _prune_redundant_deps "$skill_file" "$project_dir" "$name"

  register_project "$project_dir"
  upsert_skills_symlinks "$project_dir" "$skill_file"
}
