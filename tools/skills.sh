#!/usr/bin/env bash
# skills.sh — canon skill catalog and project registration tool
#
# Usage:
#   skills.sh list                         List all available skills
#   skills.sh add <skill> [project-dir]    Register a skill into a project
#   skills.sh status [project-dir]         Show registered skills in a project
#   skills.sh check                        Probe external tool dependencies
#   skills.sh remove <skill> [project-dir] Unregister a skill from a project

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
SEARCH_DIRS=("$SKILLS_ROOT/standards" "$SKILLS_ROOT/tools" "$SKILLS_ROOT/skills")

# Extract a single frontmatter field value from a file
fm_field() {
  local file="$1" field="$2"
  awk -v key="$field" '
    BEGIN { in_fm=0 }
    /^---$/ { in_fm=!in_fm; next }
    in_fm && substr($0, 1, length(key)+1) == key":" {
      val = substr($0, length(key)+2); sub(/^ +/, "", val); print val; exit
    }
  ' "$file"
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

# Emit a skill file's declared dependency names, one per line.
resolve_deps() {
  local file="$1" dep_str
  dep_str=$(fm_field "$file" depends)
  [ -z "$dep_str" ] && return 0
  echo "$dep_str" | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -v '^$' || true
}

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

# skills_table_upsert <agents_file> <skill_name> <skill_row>
# Creates the AI-SKILLS block if absent; updates a stale row or inserts a new one.
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
      : # already registered — silent
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

cmd_list() {
  local cols skill_w cat_w indent_w desc_w
  cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}
  skill_w=20; cat_w=11
  indent_w=$(( skill_w + 2 + cat_w + 2 ))
  desc_w=$(( cols - indent_w ))
  (( desc_w < 35 )) && desc_w=35

  local bold='\033[1m' dim='\033[2m' cyan='\033[36m' reset='\033[0m'
  local indent_str
  indent_str=$(printf '%*s' "$indent_w" '')

  local sep_skill sep_cat sep_desc
  sep_skill=$(printf '%*s' "$skill_w" '' | tr ' ' '─')
  sep_cat=$(printf '%*s' "$cat_w" '' | tr ' ' '─')
  sep_desc=$(printf '%*s' "$desc_w" '' | tr ' ' '─')

  printf "${bold}%-${skill_w}s  %-${cat_w}s  %s${reset}\n" "SKILL" "CATEGORY" "DESCRIPTION"
  printf "${dim}%s  %s  %s${reset}\n" "$sep_skill" "$sep_cat" "$sep_desc"

  # Build the set of all dep names across every skill — deps are never catalog entries
  local all_dep_names=()
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      while IFS= read -r dep; do
        [ -n "$dep" ] && all_dep_names+=("$dep")
      done < <(resolve_deps "$f")
    done < <(find "$dir" -type f -name "*.md" 2>/dev/null)
  done

  local prev_cat=""
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # tools/ items that are deps of other skills are filtered below — no blanket skip
    while IFS= read -r f; do
      local name desc category summary
      name=$(fm_field "$f" name)
      [ -z "$name" ] && continue
      [ "$(fm_field "$f" hidden)" = "true" ] && continue
      # Skills that are deps of other skills are not standalone catalog entries
      local is_dep=0
      for dep in "${all_dep_names[@]+"${all_dep_names[@]}"}"; do
        [ "$dep" = "$name" ] && is_dep=1 && break
      done
      [ "$is_dep" -eq 1 ] && continue
      summary=$(fm_field "$f" summary)
      desc="${summary:-$(fm_field "$f" description)}"
      category=$(fm_field "$f" category)

      [ "$category" != "$prev_cat" ] && [ -n "$prev_cat" ] && echo ""
      prev_cat="$category"

      # Word-wrap description; indent continuation lines to align under DESCRIPTION
      local first rest
      if (( ${#desc} > desc_w )); then
        first=$(printf '%s' "$desc" | fold -s -w "$desc_w" | head -1)
        rest=$(printf '%s' "$desc" | fold -s -w "$desc_w" | tail -n +2)
      else
        first="$desc"; rest=""
      fi

      printf "${cyan}%-${skill_w}s${reset}  ${dim}%-${cat_w}s${reset}  %s\n" \
        "$name" "$category" "$first"
      [ -n "$rest" ] && while IFS= read -r line; do
        printf "%s%s\n" "$indent_str" "$line"
      done <<< "$rest"

    done < <(find "$dir" -type f -name "*.md" 2>/dev/null | sort)
  done
  echo ""
  printf "${dim}To uninstall: skills.sh uninstall && rm -rf ~/.canon${reset}\n"
}

upsert_at_import() {
  local file="$1" import_line="$2" skill_basename="$3" label="$4"
  if grep -qF "$import_line" "$file" 2>/dev/null; then
    : # already registered — silent
  elif grep -qE "^@.+/$skill_basename$" "$file" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    awk -v import_line="$import_line" -v base="$skill_basename" '
      index($0, "@") == 1 && $0 ~ "^@.*/" base "$" { print import_line; next }
      { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    echo "  [$label]  updated stale @-import path"
  else
    echo "$import_line" >> "$file"
    echo "  [$label]  added @-import"
  fi
}


offer_tkt_path() {
  local tools_dir="$SKILLS_ROOT/tools"

  # Detect rc file
  local rc_file="$HOME/.zshrc"
  [[ "${SHELL:-}" == */bash ]] && rc_file="$HOME/.bashrc"

  # Skip if the tools dir is already on PATH or already in the rc file
  if grep -qF "$tools_dir" "$rc_file" 2>/dev/null; then return 0; fi
  if echo "$PATH" | tr ':' '\n' | grep -qxF "$tools_dir"; then return 0; fi

  if ! { : <> /dev/tty; } 2>/dev/null; then
    echo ""
    echo "canon/tools (sprint, tkt, sprint-check) is not on your PATH."
    printf "  Add it with: echo 'export PATH=\"\$PATH:%s\"' >> %s\n" "$tools_dir" "$rc_file"
    printf "  Then run: source %s\n" "$rc_file"
    return 0
  fi

  echo "" > /dev/tty
  printf "canon/tools (sprint, tkt, sprint-check) is not on your PATH.\n" > /dev/tty
  printf "Add %s to PATH in %s? [y/N] " "$tools_dir" "$rc_file" > /dev/tty
  read -r answer </dev/tty
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    printf '\n# canon tools\nexport PATH="$PATH:%s"\n' "$tools_dir" >> "$rc_file"
    echo "  Added. Run: source $rc_file" > /dev/tty
  fi
}

ensure_sprint_project_marker() {
  local project_dir="$1"
  mkdir -p "$project_dir/.tickets"
  echo "  [sprint]  ensured project-local .tickets/"
}

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

  local name desc category depends skill_basename
  name=$(fm_field "$skill_file" name)
  desc=$(fm_field "$skill_file" description)
  category=$(fm_field "$skill_file" category)
  depends=$(fm_field "$skill_file" depends)
  skill_basename=$(basename "$skill_file")
  local import_line="@$skill_file"

  # Hidden skills are internal-only — block direct registration
  if [ -z "$as_dep" ] && [ "$(fm_field "$skill_file" hidden)" = "true" ]; then
    echo "Error: '$skill' is an internal skill and cannot be registered directly."
    echo "It is loaded automatically when a parent skill (e.g. wrapup) is registered."
    exit 1
  fi

  # Resolve dependencies first — register their @-imports silently, no table row
  while IFS= read -r dep; do
    [ -n "$dep" ] && cmd_add "$dep" "$project_dir" "dep"
  done < <(resolve_deps "$skill_file")

  # Deps are loaded transitively via @-imports inside the parent skill file.
  # Don't add them to target files — keep CLAUDE.md and AGENTS.md clean.
  [ -n "$as_dep" ] && return 0
  echo "Registering: $name ($category)"

  # Auto-inject only the always-on project standard into registered projects.
  # Both CLAUDE.md and AGENTS.md get @-imports — clean references, no inlining.
  local _std
  for _std in "$SKILLS_ROOT/standards/"*.md; do
    [ -f "$_std" ] || continue
    [ "$(basename "$_std")" = "efficiency.md" ] || continue
    local _std_basename _std_import
    _std_basename=$(basename "$_std")
    _std_import="@$_std"
    upsert_at_import "$project_dir/CLAUDE.md" "$_std_import" "$_std_basename" "CLAUDE.md (std)"
    upsert_at_import "$project_dir/AGENTS.md" "$_std_import" "$_std_basename" "AGENTS.md (std)"
  done

  local claude_file="$project_dir/CLAUDE.md"
  local agents_file="$project_dir/AGENTS.md"
  local skill_row="| $name | $category | $skill_file |"

  upsert_at_import "$claude_file" "$import_line" "$skill_basename" "CLAUDE.md"
  skills_table_upsert "$agents_file" "$name" "$skill_row"
  upsert_at_import "$agents_file" "$import_line" "$skill_basename" "AGENTS.md"

  echo ""
  echo "Done. $desc"

  if [[ "$name" == "ticket" || "$name" == "sprint-check" || "$name" == "sprint" ]]; then
    if [[ "$name" == "sprint" ]]; then
      ensure_sprint_project_marker "$project_dir"
    fi
    offer_tkt_path
  fi

  # Remove explicitly-registered skills that are now covered transitively by this one
  if [ -n "$depends" ]; then
    local redundant=()
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      grep -qF "| $dep |" "$agents_file" 2>/dev/null && redundant+=("$dep")
    done < <(resolve_deps "$skill_file")
    if [ ${#redundant[@]} -gt 0 ]; then
      for dep in "${redundant[@]}"; do
        cmd_remove "$dep" "$project_dir" > /dev/null || true
      done
      local dep_list
      dep_list=$(printf '%s, ' "${redundant[@]}")
      dep_list="${dep_list%, }"
      echo ""
      echo "Removed: ${dep_list} — now included in ${name} transitively."
    fi
  fi
}

cmd_status() {
  local project_dir="${1:-$(pwd)}"
  local claude_file="$project_dir/CLAUDE.md"
  local agents_file="$project_dir/AGENTS.md"
  local issues=0

  echo "canon skills in: $project_dir"
  echo ""

  # ── Registered skills ────────────────────────────────────────────────────
  local skill_names=()
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    echo "Skills:"
    while IFS= read -r line; do
      local sname spath
      sname=$(skill_row_name "$line")
      spath=$(skill_row_path "$line")
      [ -z "$sname" ] && continue
      skill_names+=("$sname")

      local tag="ok"
      [ ! -f "$spath" ] && tag="broken ref" && (( issues++ )) || true

      local canon_file
      canon_file=$(find_skill "$sname" 2>/dev/null || true)
      if [ -n "$canon_file" ] && [ "$canon_file" != "$spath" ]; then
        tag="stale path"
        (( issues++ )) || true
      fi

      local suffix=""
      if [[ "$sname" == "ticket" ]]; then
        if command -v tkt &>/dev/null; then
          suffix="  (tkt on PATH)"
        else
          suffix="  (tkt not on PATH)"
        fi
      fi

      printf "  %-25s %s%s\n" "$sname" "[$tag]" "$suffix"
    done < <(registered_skill_rows "$agents_file")
  else
    echo "Skills: none"
  fi

  # ── upgrade suggestions ───────────────────────────────────────────────────
  local _has_wrapup=false _has_sprint=false _has_ticket=false
  for _s in "${skill_names[@]+"${skill_names[@]}"}"; do
    [[ "$_s" == "wrapup" ]] && _has_wrapup=true
    [[ "$_s" == "sprint" ]] && _has_sprint=true
    [[ "$_s" == "ticket" ]] && _has_ticket=true
  done
  if $_has_wrapup && ! $_has_sprint; then
    echo ""
    echo "Tip: wrapup + capture are now part of the sprint skill."
    printf "  Upgrade: %s add sprint %s\n" "$(basename "$0")" "$project_dir"
  fi

  # ── @-imports in CLAUDE.md and AGENTS.md ────────────────────────────────
  echo ""
  for check_file in "$claude_file" "$agents_file"; do
    local label
    label=$(basename "$check_file")
    [ -f "$check_file" ] || continue
    local broken=()
    while IFS= read -r imp; do
      local path="${imp#@}"
      [ ! -f "$path" ] && broken+=("$imp")
    done < <(grep "^@" "$check_file" 2>/dev/null || true)
    if [ ${#broken[@]} -gt 0 ]; then
      echo "Broken @-imports ($label):"
      printf '  %s\n' "${broken[@]}"
      (( issues += ${#broken[@]} )) || true
      echo ""
    fi
  done

  # ── Claude Code hook check ───────────────────────────────────────────────
  local hook_issues=0
  if [ ${#skill_names[@]} -gt 0 ] && command -v claude &>/dev/null; then
    local settings="$HOME/.claude/settings.json"
    if [ ! -f "$settings" ]; then
      hook_issues=3
    else
      for hook_script in auto-handoff.sh handoff-inject.sh pre-commit-check.sh; do
        grep -qF "$hook_script" "$settings" 2>/dev/null || (( hook_issues++ )) || true
      done
    fi
    echo ""
    if [ "$hook_issues" -eq 0 ]; then
      echo "Claude hooks: [ok]"
    else
      echo "Claude hooks: [not configured] ($hook_issues missing)"
      echo "  Run: skills.sh init"
    fi
  fi

  # pre-check sprint tools so issue count is correct before summary prints
  if $_has_sprint; then
    command -v sprint &>/dev/null || (( issues++ )) || true
    command -v sprint-check &>/dev/null || (( issues++ )) || true
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  echo ""
  if [ "$issues" -eq 0 ] && [ "$hook_issues" -eq 0 ]; then
    echo "All up to date."
  else
    [ "$issues" -gt 0 ] && echo "$issues issue(s) found. Run: $(basename "$0") refresh $project_dir"
    [ "$hook_issues" -gt 0 ] && echo "Agent hooks not wired. Run: $SKILLS_ROOT/skills.sh init"
  fi

  if $_has_sprint; then
    local _tools_dir="$SKILLS_ROOT/tools"
    local _rc_file="$HOME/.zshrc"
    [[ "${SHELL:-}" == */bash ]] && _rc_file="$HOME/.bashrc"
    echo ""
    echo "Tools:"
    if command -v sprint &>/dev/null; then
      printf "  %-20s %s\n" "sprint" "[ok]  — workflow CLI ready"
    elif grep -qF "$_tools_dir" "$_rc_file" 2>/dev/null; then
      printf "  %-20s %s\n" "sprint" "[not on PATH]  — run: source $_rc_file"
    else
      printf "  %-20s %s\n" "sprint" "[not on PATH]  — run: $(basename "$0") refresh to fix"
    fi
    if command -v sprint-check &>/dev/null; then
      printf "  %-20s %s\n" "sprint-check" "[ok]  — kanban board ready"
    elif grep -qF "$_tools_dir" "$_rc_file" 2>/dev/null; then
      printf "  %-20s %s\n" "sprint-check" "[not on PATH]  — run: source $_rc_file"
    else
      printf "  %-20s %s\n" "sprint-check" "[not on PATH]  — run: $(basename "$0") refresh to fix"
    fi
  fi

  # ── sprint / sprint-check / tkt PATH check ──────────────────────────────
  if { $_has_sprint && { ! command -v sprint &>/dev/null || ! command -v tkt &>/dev/null || ! command -v sprint-check &>/dev/null; }; } \
     || { $_has_ticket && ! command -v tkt &>/dev/null; }; then
    local _tools_dir="$SKILLS_ROOT/tools"
    local _rc_file="$HOME/.zshrc"
    [[ "${SHELL:-}" == */bash ]] && _rc_file="$HOME/.bashrc"
    if ! grep -qF "$_tools_dir" "$_rc_file" 2>/dev/null; then
      echo ""
      echo "Action needed: sprint tools (sprint, tkt, sprint-check) are not on your PATH."
      printf "  Run: echo 'export PATH=\"\$PATH:%s\"' >> %s\n" "$_tools_dir" "$_rc_file"
      printf "  Then: source %s\n" "$_rc_file"
      echo "  Or:  $(basename "$0") refresh  — to be prompted interactively"
    fi
  fi
}

cmd_refresh() {
  local project_dir="${1:-$(pwd)}"
  local claude_file="$project_dir/CLAUDE.md"
  local agents_file="$project_dir/AGENTS.md"

  if ! grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    echo "No canon skills registered in: $project_dir"
    echo "Run: $(basename "$0") add <skill> $project_dir"
    exit 1
  fi

  # ── Prune stale canon @-imports from CLAUDE.md and AGENTS.md ────────────
  # Remove any @-import pointing inside SKILLS_ROOT to a file that no longer exists.
  # Also strip any legacy CANON-STD inline blocks (replaced by @-imports).
  for prune_file in "$claude_file" "$agents_file"; do
    [ -f "$prune_file" ] || continue
    local tmp
    tmp=$(mktemp)
    # Pass 1: strip artifact lines, stale @-imports, and hidden-skill @-imports
    while IFS= read -r line; do
      [[ "$line" == *"[pruned]"* ]] && continue
      if [[ "$line" == @"$SKILLS_ROOT"/* ]]; then
        local path="${line#@}"
        if [ ! -f "$path" ]; then
          echo "  [pruned]  stale: $line" >&2
          continue
        fi
        if [[ "$path" == "$SKILLS_ROOT"/standards/* ]] && [ "$(basename "$path")" != "efficiency.md" ]; then
          echo "  [pruned]  non-default standard: $line" >&2
          continue
        fi
        if [ "$(fm_field "$path" hidden)" = "true" ]; then
          echo "  [pruned]  hidden dep: $line" >&2
          continue
        fi
      fi
      printf '%s\n' "$line"
    done < "$prune_file" > "$tmp" && mv "$tmp" "$prune_file"
    # Pass 2: strip legacy CANON-STD inline blocks
    if grep -qF "<!-- CANON-STD:" "$prune_file" 2>/dev/null; then
      tmp=$(mktemp)
      awk '
        /<!-- CANON-STD:[^:]+:BEGIN -->/ { skip=1; next }
        /<!-- CANON-STD:[^:]+:END -->/   { skip=0; next }
        !skip { print }
      ' "$prune_file" > "$tmp" && mv "$tmp" "$prune_file"
      echo "  [pruned]  legacy CANON-STD blocks from $(basename "$prune_file")" >&2
    fi
  done

  echo ""

  # ── Purge hidden and standard skills from AI-SKILLS table ───────────────
  # Hidden skills and standards don't belong in the table — they're either
  # loaded as deps or auto-injected. Their @-imports are left intact.
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      if [[ "$line" == "| "* ]] && [[ "$line" != "| Skill"* ]]; then
        local sname spath
        sname=$(skill_row_name "$line")
        spath=$(skill_row_path "$line")
        if [ -f "$spath" ] && [ "$(fm_field "$spath" hidden)" = "true" ]; then
          echo "  [pruned]  hidden skill from table: $sname" >&2
          continue
        fi
        if [[ "$spath" == */standards/* ]]; then
          echo "  [pruned]  standard from table: $sname" >&2
          continue
        fi
      fi
      printf '%s\n' "$line"
    done < "$agents_file" > "$tmp" && mv "$tmp" "$agents_file"
  fi

  # ── Prune skills covered by another registered skill's dep chain ─────────
  # If skill A is in the depends list of registered skill B, A is loaded
  # transitively via B's @-imports — the explicit registration is redundant.
  local skills_in_table covered_deps=()
  skills_in_table=$(registered_skill_names "$agents_file")

  while IFS= read -r dep; do
    [ -n "$dep" ] && covered_deps+=("$dep")
  done < <(covered_deps_for_skills <<< "$skills_in_table")

  if [ ${#covered_deps[@]} -gt 0 ]; then
    # Pre-compute file paths for each covered dep so we can filter @-imports inline
    local covered_dep_files=" "
    for dep in "${covered_deps[@]}"; do
      local dep_file
      dep_file=$(find_skill "$dep" 2>/dev/null) || true
      if [ -n "$dep_file" ]; then
        covered_dep_files="$covered_dep_files$dep_file "
        # Remove from CLAUDE.md now (not read in the loop below)
        grep -vF "@$dep_file" "$claude_file" > "$claude_file.tmp" \
          && mv "$claude_file.tmp" "$claude_file" || true
      fi
    done

    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      if [[ "$line" == "| "* ]] && [[ "$line" != "| Skill"* ]]; then
        local sname
        sname=$(skill_row_name "$line")
        for dep in "${covered_deps[@]}"; do
          if [ "$sname" = "$dep" ]; then
            echo "  [pruned]  covered by parent dep: $sname" >&2
            sname=""
            break
          fi
        done
        [ -z "$sname" ] && continue
      elif [[ "$line" == @"$SKILLS_ROOT"/* ]]; then
        # Filter out @-imports for covered deps in the same pass
        local import_path="${line#@}"
        [[ "$covered_dep_files" == *" $import_path "* ]] && continue
      fi
      printf '%s\n' "$line"
    done < "$agents_file" > "$tmp" && mv "$tmp" "$agents_file"
  fi

  # ── Re-register all remaining skills ─────────────────────────────────────
  local skills
  skills=$(registered_skill_names "$agents_file")

  echo "Refreshing skills in: $project_dir"
  echo ""

  local any_updated=false
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    local output
    output=$( (cmd_add "$skill" "$project_dir") 2>&1 ) || {
      printf "  %-22s  [not found — skipping]\n" "$skill"
      continue
    }
    local changes
    changes=$(printf '%s\n' "$output" | grep -E "added|updated|created" || true)
    if [ -n "$changes" ]; then
      printf "  %-22s  [updated]\n" "$skill"
      printf '%s\n' "$changes" | sed 's/^/    /'
      any_updated=true
    else
      printf "  %-22s  [ok]\n" "$skill"
    fi
  done <<< "$skills"

  # ── upgrade suggestion ───────────────────────────────────────────────────
  local _refresh_has_wrapup=false _refresh_has_sprint=false
  while IFS= read -r sname; do
    [[ "$sname" == "wrapup" ]] && _refresh_has_wrapup=true
    [[ "$sname" == "sprint" ]] && _refresh_has_sprint=true
  done < <(registered_skill_names "$agents_file")

  echo ""
  if $any_updated; then echo "Done."; else echo "All up to date."; fi

  if $_refresh_has_wrapup && ! $_refresh_has_sprint; then
    echo ""
    echo "Tip: wrapup + capture are now part of the sprint skill."
    printf "  Upgrade: %s add sprint %s\n" "$(basename "$0")" "$project_dir"
  fi

  if $_refresh_has_sprint; then
    offer_tkt_path
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

  # Remove row and @-import from AGENTS.md
  local agents_file="$project_dir/AGENTS.md"
  if [ -f "$agents_file" ]; then
    if grep -qF "| $skill |" "$agents_file" || grep -qF "$import_line" "$agents_file"; then
      grep -vF "| $skill |" "$agents_file" | grep -vF "$import_line" > "$agents_file.tmp" && mv "$agents_file.tmp" "$agents_file"
      echo "  [AGENTS.md]  removed"
    fi
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

  local name desc summary category tags depends
  name=$(fm_field "$skill_file" name)
  desc=$(fm_field "$skill_file" description)
  summary=$(fm_field "$skill_file" summary)
  category=$(fm_field "$skill_file" category)
  tags=$(fm_field "$skill_file" tags | tr -d '[]' | sed 's/, */  /g')
  depends=$(fm_field "$skill_file" depends | tr -d '[]' | sed 's/, */  /g')

  local W=60
  local divider; divider=$(printf '\x1b[2m%*s\x1b[0m\n' "$W" '' | tr ' ' '─')

  printf '\n\x1b[1;96m%s\x1b[0m' "$name"
  [ -n "$category" ] && printf '  \x1b[2m[%s]\x1b[0m' "$category"
  printf '\n%s\n' "$divider"

  [ -n "$desc"    ] && printf '\x1b[1m%s\x1b[0m\n'    "$desc"
  [ -n "$summary" ] && printf '\n\x1b[2m%s\x1b[0m\n'  "$summary"
  [ -n "$tags"    ] && printf '\n\x1b[2mTags:\x1b[0m    %s\n' "$tags"
  [ -n "$depends" ] && printf '\x1b[2mDepends:\x1b[0m %s\n'   "$depends"

  printf '\n%s\n\n' "$divider"
}

_init_claude() {
  local scripts="$SKILLS_ROOT/scripts"
  local settings="$HOME/.claude/settings.json"

  if ! command -v claude &>/dev/null; then
    echo "  [skip]  claude not installed"
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    echo "  [fail]  python3 required for settings.json merge"
    return 1
  fi

  local py_script
  py_script=$(cat << 'PYEOF'
import json, sys, os
settings_path = sys.argv[1]
scripts_path  = sys.argv[2]
try:
    with open(settings_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
hooks = config.setdefault("hooks", {})
desired = [
    ("Stop",            "",     f"{scripts_path}/auto-handoff.sh"),
    ("UserPromptSubmit","",     f"{scripts_path}/handoff-inject.sh"),
    ("UserPromptSubmit","",     f"{scripts_path}/sprint-inject.sh"),
    ("PreToolUse",      "Bash", f"{scripts_path}/pre-commit-check.sh"),
]
stale = {
    f"{scripts_path}/auto-polish-trigger.sh",
    f"{scripts_path}/guard-managed-files.sh",
}
for event, entries in list(hooks.items()):
    for entry in entries:
        entry["hooks"] = [
            h for h in entry.get("hooks", [])
            if os.path.expanduser(h.get("command", "")) not in stale
        ]
for event, matcher, command in desired:
    event_list = hooks.setdefault(event, [])
    entry = next((e for e in event_list if e.get("matcher") == matcher), None)
    if entry is None:
        entry = {"matcher": matcher, "hooks": []}
        event_list.append(entry)
    entry_hooks = entry.setdefault("hooks", [])
    if any(os.path.expanduser(h.get("command", "")) == command for h in entry_hooks):
        print(f"exists\t{event}\t{os.path.basename(command)}")
    else:
        entry_hooks.append({"type": "command", "command": command})
        print(f"added\t{event}\t{os.path.basename(command)}")
# Prune entries left with no hooks (e.g. after stale removal) and empty events,
# so dead matchers don't linger in settings.json.
for event in list(hooks.keys()):
    hooks[event] = [e for e in hooks[event] if e.get("hooks")]
    if not hooks[event]:
        del hooks[event]
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
)

  local hook_output added=0
  hook_output=$(python3 - "$settings" "$scripts" <<< "$py_script")
  while IFS=$'\t' read -r status event script; do
    if [ "$status" = "added" ]; then
      echo "  [added]  $event → $script"
      (( added++ )) || true
    else
      echo "  [ok]     $event → $script"
    fi
  done <<< "$hook_output"

}

_init_pi() {
  local ext_src="$SKILLS_ROOT/extensions/pi/handoff.ts"
  local ext_dst="$HOME/.pi/agent/extensions/handoff.ts"
  if [ ! -d "$HOME/.pi" ]; then
    echo "  [skip]  pi not installed"
    return 0
  fi
  if [ ! -f "$ext_src" ]; then
    echo "  [fail]  extension not found: $ext_src"
    return 1
  fi
  mkdir -p "$(dirname "$ext_dst")"
  if [ -f "$ext_dst" ] && cmp -s "$ext_src" "$ext_dst"; then
    echo "  [ok]     handoff extension already installed"
  else
    cp "$ext_src" "$ext_dst"
    echo "  [added]  handoff.ts → $ext_dst"
    echo "           Run /reload in Pi to activate"
  fi
}

_uninstall_claude() {
  local settings="$HOME/.claude/settings.json"

  if [ ! -f "$settings" ]; then
    echo "  [skip]  ~/.claude/settings.json not found"
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    echo "  [fail]  python3 required for settings.json cleanup"
    return 1
  fi

  local py_script
  py_script=$(cat << 'PYEOF'
import json, os, sys
settings_path = sys.argv[1]
skills_root = os.path.realpath(sys.argv[2])
scripts_path = os.path.join(skills_root, "scripts")
commands = {
    os.path.realpath(os.path.join(scripts_path, name))
    for name in (
        "auto-handoff.sh",
        "handoff-inject.sh",
        "sprint-inject.sh",
        "pre-commit-check.sh",
        "auto-polish-trigger.sh",
        "guard-managed-files.sh",
    )
}
try:
    with open(settings_path) as f:
        config = json.load(f)
except json.JSONDecodeError:
    print("invalid")
    sys.exit(0)
hooks = config.get("hooks")
if not isinstance(hooks, dict):
    print("removed\t0")
    sys.exit(0)
removed = 0
for event in list(hooks.keys()):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    kept_entries = []
    for entry in entries:
        entry_hooks = entry.get("hooks", []) if isinstance(entry, dict) else []
        kept_hooks = []
        for hook in entry_hooks:
            command = os.path.realpath(os.path.expanduser(hook.get("command", "")))
            if command in commands:
                removed += 1
            else:
                kept_hooks.append(hook)
        if kept_hooks:
            entry["hooks"] = kept_hooks
            kept_entries.append(entry)
    if kept_entries:
        hooks[event] = kept_entries
    else:
        del hooks[event]
if not hooks:
    config.pop("hooks", None)
with open(settings_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print(f"removed\t{removed}")
PYEOF
)

  local result status count
  result=$(python3 - "$settings" "$SKILLS_ROOT" <<< "$py_script")
  status="${result%%$'\t'*}"
  count="${result#*$'\t'}"
  if [ "$status" = "invalid" ]; then
    echo "  [warn]  ~/.claude/settings.json is invalid JSON; skipped"
  elif [ "${count:-0}" -gt 0 ]; then
    echo "  [removed]  $count Claude hook(s)"
  else
    echo "  [ok]     no canon Claude hooks found"
  fi
}

_uninstall_codex() {
  local agents="$HOME/.codex/AGENTS.md"
  local rtk_ref="@${HOME}/.codex/RTK.md"
  if [ ! -f "$agents" ]; then
    echo "  [skip]  ~/.codex/AGENTS.md not found"
    return 0
  fi
  if grep -Fxq "$rtk_ref" "$agents"; then
    grep -Fxv "$rtk_ref" "$agents" > "${agents}.tmp" && mv "${agents}.tmp" "$agents"
    echo "  [removed]  Codex RTK import"
  else
    echo "  [ok]     no canon Codex import found"
  fi
}

_uninstall_pi() {
  local ext_dst="$HOME/.pi/agent/extensions/handoff.ts"
  if [ ! -f "$ext_dst" ]; then
    echo "  [skip]  Pi handoff extension not found"
    return 0
  fi
  if grep -q 'install_path' "$ext_dst" && grep -q 'auto-handoff.sh' "$ext_dst"; then
    rm -f "$ext_dst"
    echo "  [removed]  Pi handoff extension"
  else
    echo "  [warn]  Pi handoff extension did not look canon-managed; skipped"
  fi
}

_uninstall_install_path() {
  local config="$HOME/.config/canon/install_path"
  if [ ! -f "$config" ]; then
    echo "  [skip]  ~/.config/canon/install_path not found"
    return 0
  fi
  local installed
  installed="$(cat "$config")"
  if [ "$installed" = "$SKILLS_ROOT" ]; then
    rm -f "$config"
    rmdir "$HOME/.config/canon" 2>/dev/null || true
    echo "  [removed]  install_path"
  else
    echo "  [warn]  install_path points at $installed; expected $SKILLS_ROOT"
  fi
}

cmd_init() {
  echo "canon init — wiring agent hooks from: $SKILLS_ROOT"
  echo ""

  # Write install path so extensions (e.g. Pi handoff.ts) can locate canon
  # without hardcoding a path that may differ per user.
  mkdir -p "$HOME/.config/canon"
  echo "$SKILLS_ROOT" > "$HOME/.config/canon/install_path"

  local any_fail=0

  echo "Claude Code:"
  _init_claude || any_fail=1

  echo ""
  echo "Pi:"
  _init_pi || any_fail=1

  echo ""
  if [ "$any_fail" -eq 0 ]; then
    echo "Setup complete."
  else
    echo "Setup finished with errors — check items marked [fail] above."
  fi

  echo ""
  echo "Next — register skills in your projects:"
  echo ""
  printf "  %s\n    %s\n" "skills.sh add sprint [dir]" "Full dev lifecycle (plan → build → ship)"
  printf "  %s\n    %s\n" "skills.sh addall [dir]"     "All available skills (recommended)"
  printf "  %s\n    %s\n" "skills.sh status [dir]"     "Check registration and hook health"
  printf "  %s\n    %s\n" "skills.sh refresh [dir]"    "Re-register + heal stale paths"
  printf "  %s\n    %s\n" "skills.sh list"             "Browse all available skills"
  echo ""
  echo "Default project dir is cwd — or pass a path explicitly."
  echo ""
  echo "Before deleting this install, remove canon hooks with:"
  echo "  skills.sh uninstall"
}

cmd_uninstall() {
  echo "canon uninstall — removing agent hooks for: $SKILLS_ROOT"
  echo ""

  local any_fail=0

  echo "Claude Code:"
  _uninstall_claude || any_fail=1

  echo ""
  echo "Codex:"
  _uninstall_codex || any_fail=1

  echo ""
  echo "Pi:"
  _uninstall_pi || any_fail=1

  echo ""
  echo "Install path:"
  _uninstall_install_path || any_fail=1

  echo ""
  if [ "$any_fail" -eq 0 ]; then
    echo "Uninstall cleanup complete."
  else
    echo "Uninstall cleanup finished with errors — check items marked [fail] above."
  fi
  echo "You can now delete this install directory if desired:"
  echo "  rm -rf \"$SKILLS_ROOT\""
}

cmd_addall() {
  local project_dir="${1:-$(pwd)}"
  local names=()
  local seen=()
  local backed_up=()

  # Back up any existing config files that will be modified
  for config_file in "CLAUDE.md" "AGENTS.md"; do
    local full_path="$project_dir/$config_file"
    if [ -f "$full_path" ]; then
      local bak="$full_path.bak"
      cp "$full_path" "$bak"
      backed_up+=("$config_file")
    fi
  done

  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # tools/ and standards/ are auto-injected infrastructure — exclude from bulk install
    [[ "$dir" == */tools ]] && continue
    [[ "$dir" == */standards ]] && continue
    while IFS= read -r f; do
      local name already=0
      name=$(fm_field "$f" name)
      [ -z "$name" ] && continue
      [ "$(fm_field "$f" hidden)" = "true" ] && continue
      for s in "${seen[@]+"${seen[@]}"}"; do [ "$s" = "$name" ] && already=1 && break; done
      [ "$already" -eq 0 ] && names+=("$name") && seen+=("$name")
    done < <(find "$dir" -type f -name "*.md" 2>/dev/null | sort)
  done

  [ ${#names[@]} -eq 0 ] && { echo "No skills found."; exit 1; }

  # Collect all dep names so we can skip skills already covered transitively
  local all_deps=" "
  for name in "${names[@]}"; do
    local sf
    sf=$(find_skill "$name" 2>/dev/null) || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] && all_deps="$all_deps$dep "
    done < <(resolve_deps "$sf")
  done

  # Only register top-level skills — skip those covered as deps of another skill
  local top_level=()
  for name in "${names[@]}"; do
    if [[ "$all_deps" == *" $name "* ]]; then
      echo "  skip $name — included transitively by a higher-level skill"
    else
      top_level+=("$name")
    fi
  done

  echo "Registering ${#top_level[@]} skill(s) into: $project_dir"
  echo ""
  for name in "${top_level[@]}"; do
    cmd_add "$name" "$project_dir"
  done

  if [ ${#backed_up[@]} -gt 0 ]; then
    echo ""
    echo "Backups created (originals before this run):"
    for f in "${backed_up[@]}"; do
      echo "  $project_dir/$f.bak"
    done
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

  # Regenerate CATALOG.md through the structured generator
  cmd_catalog >/dev/null

  echo ""
  echo "Deleted: $skill"
  echo "CATALOG.md updated."
  echo "Note: any projects with this skill registered will have a dangling reference — run 'skills.sh remove $skill' in those projects."
}

cmd_catalog() {
  python3 - "$SKILLS_ROOT" <<'PYEOF'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
dirs = [root / "standards", root / "tools", root / "skills"]

def fm(path):
    text = path.read_text(errors="replace")
    m = re.match(r"---\n(.*?)\n---", text, re.S)
    data = {}
    if not m:
        return data
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip()
    return data

items = []
for d in dirs:
    if not d.exists():
        continue
    for p in sorted(d.glob("*.md")):
        data = fm(p)
        if data.get("name"):
            data["path"] = p
            items.append(data)

deps = {}
for item in items:
    for dep in item.get("depends", "").strip("[]").split(","):
        dep = dep.strip()
        if dep:
            deps.setdefault(dep, []).append(item["name"])

def is_standard(item):
    return item["path"].parent.name == "standards"

standards  = [i for i in items if is_standard(i) and i.get("hidden") != "true"]
standalone = [
    i for i in items
    if not is_standard(i) and i.get("hidden") != "true" and i["name"] not in deps
]
subskills = [i for i in items if not is_standard(i) and i["name"] in deps]

lines = [
    "# canon Catalog",
    "",
    "> Static snapshot - run `skills.sh list` for live output.",
    "",
    "## Standalone Skills",
    "",
    "Register these directly into a project with `skills.sh add <name>`.",
    "",
    "| Skill | Category | Description |",
    "|---|---|---|",
]
for item in standalone:
    desc = item.get("summary") or item.get("description", "")
    lines.append(f"| `{item['name']}` | {item.get('category', '')} | {desc} |")

lines += [
    "",
    "## Standards",
    "",
    "Auto-injected / contributor reference — not registered directly.",
    "",
    "| Standard | Category | Description |",
    "|---|---|---|",
]
for item in standards:
    desc = item.get("summary") or item.get("description", "")
    lines.append(f"| `{item['name']}` | {item.get('category', '')} | {desc} |")

lines += [
    "",
    "## Sub-skills",
    "",
    "Imported automatically by the skills above. Do not register directly.",
    "",
    "| Skill | Imported by |",
    "|---|---|",
]
for item in subskills:
    imported_by = ", ".join(sorted(deps.get(item["name"], []))) or "-"
    lines.append(f"| `{item['name']}` | {imported_by} |")

(root / "CATALOG.md").write_text("\n".join(lines) + "\n")
PYEOF
  echo "CATALOG.md updated."
}

# ── check ───────────────────────────────────────────────────────────────────

cmd_check() {
  local settings="$HOME/.claude/settings.json"

  echo "canon check — probing external tool dependencies"
  echo ""

  if [ ! -f "$settings" ]; then
    echo "~/.claude/settings.json not found — no hooks to check"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    echo "python3 required for settings.json parsing"
    return 1
  fi

  local py_out
  py_out=$(python3 - "$settings" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        config = json.load(f)
except Exception as e:
    print(f"error: {e}", file=sys.stderr); sys.exit(1)
for event, entries in config.get("hooks", {}).items():
    for entry in entries:
        matcher = entry.get("matcher", "")
        for hook in entry.get("hooks", []):
            cmd = hook.get("command", "")
            if cmd:
                print(f"hook|{event}|{matcher}|{cmd}")
sl_cmd = config.get("statusLine", {}).get("command", "")
if sl_cmd:
    print(f"statusLine|||{sl_cmd}")
PYEOF
) || { echo "Failed to parse ~/.claude/settings.json"; return 1; }

  # Builtins always present — skip them
  local skip_bins=" bash sh zsh python3 node echo true false cat grep awk sed find ls pwd "
  local checked=" " issues=0

  while IFS='|' read -r source event matcher command; do
    [ -z "$command" ] && continue
    local binary="${command%% *}"
    binary="${binary/#\~/$HOME}"

    [[ "$checked" == *" ${binary} "* ]] && continue
    checked="${checked}${binary} "

    local stem="${binary##*/}"
    [[ "$skip_bins" == *" $stem "* ]] && continue

    local location
    if [ "$source" = "hook" ]; then
      location="hooks.${event} (matcher: ${matcher:-any})"
    else
      location="statusLine"
    fi

    local is_path=0 present=1
    [[ "$binary" == /* || "$binary" == "$HOME"* ]] && is_path=1 || true
    if (( is_path )); then
      [ -f "$binary" ] || present=0
    else
      command -v "$binary" &>/dev/null || present=0
    fi

    if (( present )); then
      printf "  ok       %s\n" "$stem"
    else
      printf "  MISSING  %s\n" "$stem"
      (( is_path )) && printf "    path:     %s\n" "$binary"
      printf "    location: %s in ~/.claude/settings.json\n" "$location"
      issues=$(( issues + 1 ))
    fi
  done <<< "$py_out"

  echo ""
  if [ "$issues" -eq 0 ]; then
    echo "All dependencies present."
    return 0
  else
    echo "$issues missing. Remove the referencing hook(s) from ~/.claude/settings.json"
    return 1
  fi
}

# ── lint ────────────────────────────────────────────────────────────────────

# Validate every skill in skills/ against skill-setup-std conventions.
cmd_lint() {
  local skills_dir="${1:-$SKILLS_ROOT/skills}" errors=0
  local valid_categories="dev agent-ops ops"

  err() { printf 'skills/%s: %s\n' "$1" "$2"; errors=$((errors + 1)); }

  # Flat location — no skills nested in subdirectories.
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    printf '%s: skill must live flat under skills/, not in a subdirectory\n' "${nested#"$SKILLS_ROOT"/}"
    errors=$((errors + 1))
  done < <(find "$skills_dir" -mindepth 2 -name '*.md' -type f 2>/dev/null)

  local f base stem name desc category tags deps imp sib dep
  for f in "$skills_dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f"); stem="${base%.md}"

    # Naming: lowercase, hyphenated, <= 20 chars.
    printf '%s' "$stem" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' \
      || err "$base" "filename must be lowercase and hyphenated"
    [ "${#stem}" -le 20 ] || err "$base" "name exceeds 20 characters (${#stem})"

    # Required frontmatter.
    name=$(fm_field "$f" name)
    desc=$(fm_field "$f" description)
    category=$(fm_field "$f" category)
    tags=$(fm_field "$f" tags)
    [ -n "$name" ]     || err "$base" "missing required field 'name'"
    [ -n "$desc" ]     || err "$base" "missing required field 'description'"
    [ -n "$category" ] || err "$base" "missing required field 'category'"
    { [ -n "$tags" ] && [ "$tags" != "[]" ]; } || err "$base" "missing required field 'tags'"

    # name must match filename.
    [ -z "$name" ] || [ "$name" = "$stem" ] || err "$base" "name '$name' does not match filename"

    # Category enum.
    if [ -n "$category" ] && ! printf ' %s ' "$valid_categories" | grep -q " $category "; then
      err "$base" "category '$category' not in {dev, agent-ops, ops}"
    fi

    # Imports resolve.
    while IFS= read -r imp; do
      [ -n "$imp" ] || continue
      [ -f "$skills_dir/$imp" ] || err "$base" "import '@$imp' does not resolve"
    done < <(grep -oE '^@[^[:space:]]+' "$f" | sed 's/^@//')

    # depends graph: sibling imports must be declared; declared deps must resolve.
    deps=$(resolve_deps "$f")
    while IFS= read -r sib; do
      [ -n "$sib" ] || continue
      printf '%s\n' "$deps" | grep -qx "$sib" \
        || err "$base" "imports '@./$sib.md' but '$sib' is not in depends"
    done < <(grep -oE '^@\./[^[:space:]]+\.md' "$f" | sed -E 's#^@\./(.*)\.md#\1#')
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      find_skill "$dep" >/dev/null 2>&1 \
        || err "$base" "depends entry '$dep' does not resolve to a known skill"
    done < <(printf '%s\n' "$deps")

    # One job: a leaf skill chains actions if its description says "and then".
    # Orchestrators compose children, declared via depends:, and are exempt.
    if [ -z "$deps" ] && printf '%s' "$desc" | grep -qiE '(^|[^[:alpha:]])and then([^[:alpha:]]|$)'; then
      err "$base" "description chains actions ('and then') — split into one job, or compose children via depends:"
    fi

    # Vague description: too short to convey what it does and when to use it.
    if [ -n "$desc" ] && [ "${#desc}" -lt 20 ]; then
      err "$base" "description too short (${#desc} chars) — state what it does and when to use it"
    fi
  done

  if [ "$errors" -eq 0 ]; then
    echo "skills lint: clean"
    return 0
  fi
  printf '\n%d issue(s) found.\n' "$errors"
  return 1
}

# ── dispatch ────────────────────────────────────────────────────────────────

# Handle: skills.sh --scan [dir]  or  skills.sh [dir] --scan
_scan_dir=""
_remaining_args=()
for _arg in "$@"; do
  if [ "$_arg" = "--scan" ]; then
    _scan_dir="${_scan_dir:-__pending__}"
  elif [ -z "$_scan_dir" ] || [ "$_scan_dir" = "__pending__" ]; then
    if [ "$_scan_dir" = "__pending__" ] && [ -d "$_arg" ]; then
      _scan_dir="$_arg"
    else
      _remaining_args+=("$_arg")
    fi
  else
    _remaining_args+=("$_arg")
  fi
done

if [ -n "$_scan_dir" ]; then
  _scan_dir="${_scan_dir/__pending__/$(pwd)}"
  set -- "${_remaining_args[@]+"${_remaining_args[@]}"}"
  cmd_status "$_scan_dir"
  exit $?
fi

cmd="${1:-list}"
shift || true

# Handle: skills <skill-name> --h / -h / --help
case "${1:-}" in
  --h|--help|-h) cmd_help "$cmd"; exit 0 ;;
esac

case "$cmd" in
  list)    cmd_list    "$@" ;;
  add)     cmd_add     "$@" ;;
  addall)  cmd_addall  "$@" ;;
  refresh) cmd_refresh "$@" ;;
  status)  cmd_status  "$@" ;;
  remove)  cmd_remove  "$@" ;;
  delete)  cmd_delete  "$@" ;;
  catalog) cmd_catalog "$@" ;;
  check)   cmd_check   "$@" ;;
  lint)    cmd_lint    "$@" ;;
  help)    cmd_help    "$@" ;;
  init)    cmd_init    "$@" ;;
  uninstall|remove-canon) cmd_uninstall "$@" ;;
  *)
    echo "Usage: skills.sh <list|add|addall|refresh|status|check|remove|delete|catalog|lint|help|init|uninstall> [skill] [project-dir]"
    echo ""
    echo "  list                    Show all available skills"
    echo "  add <skill> [dir]       Register a skill into a project (default: cwd)"
    echo "  addall [dir]            Register all available skills into a project (default: cwd)"
    echo "  refresh [dir]           Re-register all skills and update standards (default: cwd)"
    echo "  status [dir]            Show registered skills and detect issues (default: cwd)"
    echo "  check                   Probe external tool dependencies in hooks and config"
    echo "  remove <skill> [dir]    Unregister a skill from a project (default: cwd)"
    echo "  delete <skill>          Permanently remove a skill from canon"
    echo "  catalog                 Regenerate CATALOG.md snapshot"
    echo "  lint                    Check skills/ against skill-setup-std conventions"
    echo "  help <skill>            Show full documentation for a skill"
    echo "  init                    Wire agent hooks for this install location"
    echo "  uninstall               Remove canon hooks/config for this install"
    echo "  remove-canon            Alias for uninstall"
    echo "  <skill> --h             Same as: skills.sh help <skill>"
    echo "  --scan [dir]            Show skills registered in a project (default: cwd)"
    exit 1
    ;;
esac
