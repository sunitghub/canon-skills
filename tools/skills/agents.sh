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

# Claude Code reads CLAUDE.md natively, not AGENTS.md — without this bridge,
# a project that only ever runs `skills.sh add` gets a fully-populated
# AGENTS.md that Claude Code itself never loads. Creating a missing CLAUDE.md
# is silent (mirrors AGENTS.md's own auto-create); appending to an existing
# one prompts first, since that file may carry real hand-authored content.
ensure_claude_bridge() {
  local project_dir="$1"
  local claude_file="$project_dir/CLAUDE.md"
  local import_line="@AGENTS.md"

  if [ ! -f "$claude_file" ]; then
    echo "$import_line" > "$claude_file"
    echo "  [CLAUDE.md]  created with @AGENTS.md import"
    return 0
  fi

  if grep -qxF "$import_line" "$claude_file"; then
    return 0
  fi

  if ! { : <> /dev/tty; } 2>/dev/null; then
    echo "  [CLAUDE.md]  exists without @AGENTS.md — Claude Code won't see canon skill instructions until you add it: echo '$import_line' >> $claude_file"
    return 0
  fi
  printf "CLAUDE.md exists but doesn't import AGENTS.md — Claude Code won't see canon skills otherwise. Add '@AGENTS.md'? [y/N] (auto-skips in 15s) " > /dev/tty
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 0; }
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    { echo ""; echo "$import_line"; } >> "$claude_file"
    echo "  [CLAUDE.md]  added @AGENTS.md import" > /dev/tty
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

