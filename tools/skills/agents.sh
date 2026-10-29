#!/usr/bin/env bash
# tools/skills/agents.sh — AGENTS.md and CLAUDE.md manipulation

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The block's note names no install path (t-97e2): an absolute one differs on every machine.
SKILLS_TABLE_NOTE="> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Paths are relative to the canon install."
# t-5c4b: every session loads AGENTS.md (Claude Code through CLAUDE.md, Codex, pi, cloud sessions), so this one line is how
# each of them knows the platform rule; the details stay in standards/efficiency-notes.md, read on demand.
PLATFORMS_NOTE="> Platforms: on Windows canon's commands run in Git Bash, never PowerShell or cmd. Details: standards/efficiency-notes.md › Platforms (canon install)."

skills_table_upsert() {
  local agents_file="$1" name="$2" skill_row="$3"
  local block_begin="<!-- AI-SKILLS:BEGIN -->"
  local block_end="<!-- AI-SKILLS:END -->"

  # t-97e2: an older block's note ends in "Source: <absolute install path>"; rewrite it once.
  if [ -f "$agents_file" ] && grep -q '^> Managed by `skills.sh`.*Source: /' "$agents_file"; then
    awk -v note="$SKILLS_TABLE_NOTE" '/^> Managed by `skills.sh`.*Source: \// { print note; next } { print }' \
      "$agents_file" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
    echo "  [AGENTS.md]  made the skill block's note portable"
  fi

  # t-5c4b: a block without the current platforms line gains it once, under its note (an older wording is replaced).
  # Only lines inside the block are touched: a "> Platforms:" line of the user's own outside it stays.
  # A CRLF file (Git for Windows) is compared without its \r and gets the line with one.
  if [ -f "$agents_file" ] && grep -qF "$block_begin" "$agents_file" && [ "$(tr -d '\r' < "$agents_file" | grep -cxF "$PLATFORMS_NOTE")" -eq 0 ]; then
    awk -v pn="$PLATFORMS_NOTE" -v b="$block_begin" -v e="$block_end" '
      { l = $0; cr = sub(/\r$/, "", l) ? "\r" : "" }
      l == b { inblk = 1 }
      inblk && l ~ /^> Platforms:/ { next }
      inblk && l == e && !done { print pn cr; done = 1 }
      { print }
      inblk && l ~ /^> Managed by `skills.sh`/ && !done { print pn cr; done = 1 }
      l == e { inblk = 0 }' \
      "$agents_file" > "$agents_file.tmp"
    if cmp -s "$agents_file.tmp" "$agents_file"; then
      rm -f "$agents_file.tmp"
    else
      mv "$agents_file.tmp" "$agents_file"
      echo "  [AGENTS.md]  added the platforms line to the skill block"
    fi
  fi

  if [ ! -f "$agents_file" ] || ! grep -qF "$block_begin" "$agents_file"; then
    ensure_blank_sep "$agents_file"
    {
      echo "$block_begin"
      echo "## Active canon skills"
      echo "$SKILLS_TABLE_NOTE"
      echo "$PLATFORMS_NOTE"
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

  if _prompt_or_auto_yes "CLAUDE.md exists but doesn't import AGENTS.md — Claude Code won't see canon skills otherwise. Add '@AGENTS.md'?"; then
    { echo ""; echo "$import_line"; } >> "$claude_file"
    echo "  [CLAUDE.md]  added @AGENTS.md import"
  else
    echo "  [CLAUDE.md]  exists without @AGENTS.md — Claude Code won't see canon skill instructions until you add it: echo '$import_line' >> $claude_file"
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

