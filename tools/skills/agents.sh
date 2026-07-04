#!/usr/bin/env bash
# tools/skills/agents.sh — AGENTS.md and CLAUDE.md manipulation

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

skills_table_upsert() {
  local agents_file="$1" name="$2" skill_row="$3"
  local block_begin="<!-- AI-SKILLS:BEGIN -->"
  local block_end="<!-- AI-SKILLS:END -->"

  if [ ! -f "$agents_file" ] || ! grep -qF "$block_begin" "$agents_file"; then
    {
      echo ""
      echo "$block_begin"
      echo "## Active canon skills"
      echo "> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Source: $SKILLS_ROOT"
      echo ""
      echo "| Skill | Category | Source |"
      echo "|-------|----------|--------|"
      echo "$skill_row"
      echo "$block_end"
    } >> "$agents_file"
    echo "  [AGENTS.md]  created skill block"
  elif grep -qF "| $name |" "$agents_file"; then
    if grep -qF "$skill_row" "$agents_file"; then
      :
    else
      awk -v name="| $name |" -v row="$skill_row" \
        'index($0, name) { print row; next } { print }' \
        "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
      echo "  [AGENTS.md]  updated stale row path"
    fi
  else
    awk -v row="$skill_row" -v end="$block_end" \
      '$0 == end { print row } { print }' \
      "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
    echo "  [AGENTS.md]  added row to skill block"
  fi
}

# Strip the whole AI-SKILLS block (plus its leading separator blank line) once
# its last data row is gone, so add/remove round-trips back to the original file.
skills_table_prune_if_empty() {
  local agents_file="$1"
  [ -f "$agents_file" ] || return 0
  grep -qF "<!-- AI-SKILLS:BEGIN -->" "$agents_file" 2>/dev/null || return 0
  [ -n "$(registered_skill_rows "$agents_file")" ] && return 0
  awk '
    {
      if (/<!-- AI-SKILLS:BEGIN -->/) {
        if (have) { if (held != "") print held; have = 0 }
        flag = 1
        next
      }
      if (flag == 1 && /<!-- AI-SKILLS:END -->/) { flag = 0; next }
      if (flag == 1) { next }
      if (have) print held
      have = 1
      held = $0
    }
    END { if (have) print held }
  ' "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
  echo "  [AGENTS.md]  removed empty skill block"
}

