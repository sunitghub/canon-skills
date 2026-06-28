#!/usr/bin/env bash
# tools/skills/lib.sh — shared utilities and environment for skills commands

set -euo pipefail

# We assume this script is sourced by tools/skills.sh or other sub-scripts in tools/skills/
# and that the caller has set up the appropriate paths.

# shellcheck source=tools/hooks-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../hooks-lib.sh"
# shellcheck source=tools/skill-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../skill-lib.sh"

# If sourced from tools/skills.sh, BASH_SOURCE[0] is tools/skills.sh
# If sourced from tools/skills/lib.sh, BASH_SOURCE[0] is tools/skills/lib.sh
# We want SKILLS_ROOT to be the root of the repo.

if [ -z "${SKILLS_ROOT:-}" ]; then
    # lib.sh is at tools/skills/lib.sh, so ../.. is the repo root
    SKILLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

SEARCH_DIRS=("$SKILLS_ROOT/standards" "$SKILLS_ROOT/tools" "$SKILLS_ROOT/skills")
PROJECTS_FILE="$HOME/.config/canon/projects"

# Extract a single frontmatter field value from a file
registered_skill_rows() {
  local agents_file="$1"
  [ -f "$agents_file" ] || return 0
  sed -n '/AI-SKILLS:BEGIN/,/AI-SKILLS:END/p' "$agents_file" \
    | grep "^| " | grep -v "^| Skill" || true
}

skill_row_name() {
  awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}' <<< "$1"
}

skill_row_path() {
  awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); print $4}' <<< "$1"
}

registered_skill_names() {
  local agents_file="$1" line name
  while IFS= read -r line; do
    name="$(skill_row_name "$line")"
    [ -n "$name" ] && printf '%s\n' "$name"
  done < <(registered_skill_rows "$agents_file")
}

covered_deps_for_skills() {
  local skill sf dep
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    sf=$(find_skill "$skill" 2>/dev/null) || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] && printf '%s\n' "$dep"
    done < <(resolve_deps "$sf")
  done
}

is_canon_project_import_line() {
  local line="$1" import_path base
  [[ "$line" == @* ]] || return 1
  import_path="${line#@}"

  [[ "$import_path" == "$SKILLS_ROOT"/* ]] && return 0

  base="$(basename "$import_path")"
  case "$import_path" in
    */standards/*.md)
      return 0
      ;;
    */skills/*/SKILL.md)
      local slug; slug=$(basename "$(dirname "$import_path")")
      [ -f "$SKILLS_ROOT/skills/$slug/SKILL.md" ] && return 0
      ;;
    */tools/*.md)
      [ -f "$SKILLS_ROOT/tools/$base" ] && return 0
      ;;
  esac

  return 1
}

strip_canon_project_imports() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp=$(mktemp)
  while IFS= read -r line; do
    is_canon_project_import_line "$line" && continue
    printf '%s\n' "$line"
  done < "$file" > "$tmp" && mv "$tmp" "$file"
}
