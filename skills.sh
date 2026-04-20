#!/usr/bin/env bash
# skills.sh — AI-Skills catalog and project registration tool
#
# Usage:
#   skills.sh list                         List all available skills
#   skills.sh add <skill> [project-dir]    Register a skill into a project
#   skills.sh status [project-dir]         Show registered skills in a project
#   skills.sh remove <skill> [project-dir] Unregister a skill from a project

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")" && pwd)"
SEARCH_DIRS=("$SKILLS_ROOT/standards" "$SKILLS_ROOT/tools" "$SKILLS_ROOT/skills")

# Extract a single frontmatter field value from a file
fm_field() {
  local file="$1" field="$2"
  awk 'BEGIN{in_fm=0} /^---$/{in_fm=!in_fm; next} in_fm && /^'"$field"': /{sub(/^'"$field"': */,""); print; exit}' "$file"
}

# Find a skill file by its frontmatter name field
find_skill() {
  local name="$1"
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ "$(fm_field "$f" name)" = "$name" ] && echo "$f" && return 0
    done < <(find "$dir" -name "*.md" -type f 2>/dev/null)
  done
  return 1
}

cmd_list() {
  local output
  output=$(
    printf "%-25s %-12s %s\n" "SKILL" "CATEGORY" "DESCRIPTION"
    printf "%-25s %-12s %s\n" "─────────────────────────" "────────────" "───────────────────────────────────────"
    for dir in "${SEARCH_DIRS[@]}"; do
      [ -d "$dir" ] || continue
      while IFS= read -r f; do
        name=$(fm_field "$f" name)
        [ -z "$name" ] && continue
        summary=$(fm_field "$f" summary)
        desc="${summary:-$(fm_field "$f" description)}"
        category=$(fm_field "$f" category)
        printf "%-25s %-12s %s\n" "$name" "$category" "$desc"
      done < <(find "$dir" -name "SKILL.md" -o -name "*.md" -type f 2>/dev/null | sort)
    done
  )
  if command -v bat &>/dev/null; then
    echo "$output" | bat -l md --plain
  else
    echo "$output"
  fi
}

cmd_add() {
  local skill="${1:-}"
  local project_dir="${2:-$(pwd)}"

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
  local import_line="@$skill_file"

  echo "Registering: $name ($category)"

  # --- CLAUDE.md: append @-import ---
  local claude_file="$project_dir/CLAUDE.md"
  if grep -qF "$import_line" "$claude_file" 2>/dev/null; then
    echo "  [CLAUDE.md]  already registered"
  else
    echo "$import_line" >> "$claude_file"
    echo "  [CLAUDE.md]  added @-import"
  fi

  # --- AGENTS.md: managed block with skill table ---
  local agents_file="$project_dir/AGENTS.md"
  local block_begin="<!-- AI-SKILLS:BEGIN -->"
  local block_end="<!-- AI-SKILLS:END -->"
  local skill_row="| $name | $category | $skill_file |"

  if [ ! -f "$agents_file" ] || ! grep -qF "$block_begin" "$agents_file"; then
    # Create or append the managed block
    {
      echo ""
      echo "$block_begin"
      echo "## Active AI-Skills"
      echo "> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Source: $SKILLS_ROOT"
      echo ""
      echo "| Skill | Category | Source |"
      echo "|-------|----------|--------|"
      echo "$skill_row"
      echo "$block_end"
    } >> "$agents_file"
    echo "  [AGENTS.md]  created skill block"
  elif grep -qF "| $name |" "$agents_file"; then
    echo "  [AGENTS.md]  already registered"
  else
    # Insert new row before the end marker
    awk -v row="$skill_row" -v end="$block_end" \
      '$0 == end { print row } { print }' \
      "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
    echo "  [AGENTS.md]  added row to skill block"
  fi

  echo ""
  echo "Done. $desc"
}

cmd_status() {
  local project_dir="${1:-$(pwd)}"
  echo "AI-Skills registered in: $project_dir"
  echo ""

  local claude_file="$project_dir/CLAUDE.md"
  if [ -f "$claude_file" ] && grep -qF "$SKILLS_ROOT" "$claude_file" 2>/dev/null; then
    echo "CLAUDE.md (@-imports):"
    grep "$SKILLS_ROOT" "$claude_file" | sed "s|@$SKILLS_ROOT/|  |"
  else
    echo "CLAUDE.md: none"
  fi

  echo ""
  local agents_file="$project_dir/AGENTS.md"
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    echo "AGENTS.md (skill block):"
    sed -n '/AI-SKILLS:BEGIN/,/AI-SKILLS:END/p' "$agents_file" \
      | grep "^| " | grep -v "^| Skill" \
      | awk -F'|' '{printf "  %-25s %s\n", $2, $3}'
  else
    echo "AGENTS.md: none"
  fi
}

cmd_remove() {
  local skill="${1:-}"
  local project_dir="${2:-$(pwd)}"

  [ -z "$skill" ] && { echo "Usage: skills.sh remove <skill-name> [project-dir]"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found."
    exit 1
  }

  local import_line="@$skill_file"

  # Remove from CLAUDE.md
  local claude_file="$project_dir/CLAUDE.md"
  if [ -f "$claude_file" ] && grep -qF "$import_line" "$claude_file"; then
    grep -vF "$import_line" "$claude_file" > "$claude_file.tmp" && mv "$claude_file.tmp" "$claude_file"
    echo "  [CLAUDE.md]  removed"
  fi

  # Remove row from AGENTS.md skill block
  local agents_file="$project_dir/AGENTS.md"
  if [ -f "$agents_file" ] && grep -qF "| $skill |" "$agents_file"; then
    grep -vF "| $skill |" "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
    echo "  [AGENTS.md]  removed"
  fi

  echo "Unregistered: $skill"
}

cmd_help() {
  local skill="${1:-}"
  [ -z "$skill" ] && { echo "Usage: skills.sh help <skill-name>"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found. Run 'skills.sh list' to see available skills."
    exit 1
  }

  # Strip YAML frontmatter, print body
  local body
  body=$(awk 'BEGIN{fm=0;done=0} /^---$/{if(fm)done=1; fm=1; next} done{print}' "$skill_file")

  if command -v bat &>/dev/null; then
    echo "$body" | bat -l md --plain
  else
    echo "$body"
  fi
}

cmd_delete() {
  local skill="${1:-}"
  [ -z "$skill" ] && { echo "Usage: skills.sh delete <skill-name>"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found. Run 'skills.sh list' to see available skills."
    exit 1
  }

  # For skills/ dir entries, remove the whole directory; otherwise just the file
  local skill_dir
  skill_dir=$(dirname "$skill_file")
  local rel_dir="${skill_dir#$SKILLS_ROOT/}"

  if [[ "$rel_dir" == skills/* ]]; then
    echo "Deleting skill directory: $rel_dir"
    rm -rf "$skill_dir"
  else
    echo "Deleting skill file: ${skill_file#$SKILLS_ROOT/}"
    rm "$skill_file"
  fi

  # Regenerate CATALOG.md
  {
    echo "# AI-Skills Catalog"
    echo ""
    echo "> Auto-generated snapshot. Run \`skills.sh list\` for live output."
    echo ""
    echo "\`\`\`"
    "$SKILLS_ROOT/skills.sh" list
    echo "\`\`\`"
  } > "$SKILLS_ROOT/CATALOG.md"

  echo ""
  echo "Deleted: $skill"
  echo "CATALOG.md updated."
  echo "Note: any projects with this skill registered will have a dangling reference — run 'skills.sh remove $skill' in those projects."
}

# ── dispatch ────────────────────────────────────────────────────────────────
cmd="${1:-list}"
shift || true

# Handle: skills <skill-name> --h / -h / --help
case "${1:-}" in
  --h|--help|-h) cmd_help "$cmd"; exit 0 ;;
esac

case "$cmd" in
  list)   cmd_list   "$@" ;;
  add)    cmd_add    "$@" ;;
  status) cmd_status "$@" ;;
  remove) cmd_remove "$@" ;;
  delete) cmd_delete "$@" ;;
  help)   cmd_help   "$@" ;;
  *)
    echo "Usage: skills.sh <list|add|status|remove|delete|help> [skill] [project-dir]"
    echo ""
    echo "  list                    Show all available skills"
    echo "  add <skill> [dir]       Register a skill into a project (default: cwd)"
    echo "  status [dir]            Show registered skills (default: cwd)"
    echo "  remove <skill> [dir]    Unregister a skill from a project (default: cwd)"
    echo "  delete <skill>          Permanently remove a skill from AI-Skills"
    echo "  help <skill>            Show full documentation for a skill"
    echo "  <skill> --h             Same as: skills.sh help <skill>"
    exit 1
    ;;
esac
