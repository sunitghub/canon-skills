#!/usr/bin/env bash
# skills.sh — canon skill catalog and project registration tool
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
      local dep_str
      dep_str=$(fm_field "$f" depends)
      [ -z "$dep_str" ] && continue
      while IFS= read -r dep; do
        dep=$(echo "$dep" | tr -d ' ')
        [ -n "$dep" ] && all_dep_names+=("$dep")
      done <<< "$(echo "$dep_str" | tr -d '[]' | tr ',' '\n')"
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
}

upsert_at_import() {
  local file="$1" import_line="$2" skill_basename="$3" label="$4"
  if grep -qF "$import_line" "$file" 2>/dev/null; then
    : # already registered — silent
  elif grep -qE "^@.+/$skill_basename$" "$file" 2>/dev/null; then
    sed -i '' "s|^@.*/$skill_basename$|$import_line|" "$file"
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

  echo "" > /dev/tty
  printf "canon/tools (tkt, sprint-check) is not on your PATH.\n" > /dev/tty
  printf "Add %s to PATH in %s? [y/N] " "$tools_dir" "$rc_file" > /dev/tty
  read -r answer </dev/tty
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    printf '\n# canon tools\nexport PATH="$PATH:%s"\n' "$tools_dir" >> "$rc_file"
    echo "  Added. Run: source $rc_file" > /dev/tty
  fi
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

  # Resolve dependencies first — register their @-imports silently, no table row
  if [ -n "$depends" ]; then
    local deps
    deps=$(echo "$depends" | tr -d '[]' | tr ',' '\n' | tr -d ' ')
    while IFS= read -r dep; do
      [ -n "$dep" ] && cmd_add "$dep" "$project_dir" "dep"
    done <<< "$deps"
  fi

  # Deps are loaded transitively via @-imports inside the parent skill file.
  # Don't add them to target files — keep CLAUDE.md and AGENTS.md clean.
  [ -n "$as_dep" ] && return 0
  echo "Registering: $name ($category)"

  # Auto-inject all standards into every project that registers any skill.
  # Both CLAUDE.md and AGENTS.md get @-imports — clean references, no inlining.
  local _std
  for _std in "$SKILLS_ROOT/standards/"*.md; do
    [ -f "$_std" ] || continue
    local _std_basename _std_import
    _std_basename=$(basename "$_std")
    _std_import="@$_std"
    upsert_at_import "$project_dir/CLAUDE.md" "$_std_import" "$_std_basename" "CLAUDE.md (std)"
    upsert_at_import "$project_dir/AGENTS.md" "$_std_import" "$_std_basename" "AGENTS.md (std)"
  done

  local claude_file="$project_dir/CLAUDE.md"
  local agents_file="$project_dir/AGENTS.md"
  local block_begin="<!-- AI-SKILLS:BEGIN -->"
  local block_end="<!-- AI-SKILLS:END -->"
  local skill_row="| $name | $category | $skill_file |"

  upsert_at_import "$claude_file" "$import_line" "$skill_basename" "CLAUDE.md"

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

  upsert_at_import "$agents_file" "$import_line" "$skill_basename" "AGENTS.md"

  echo ""
  echo "Done. $desc"

  if [[ "$name" == "ticket" || "$name" == "sprint-check" || "$name" == "sprint" ]]; then
    offer_tkt_path
  fi

  # Remove explicitly-registered skills that are now covered transitively by this one
  if [ -n "$depends" ]; then
    local redundant=()
    while IFS= read -r dep; do
      dep=$(echo "$dep" | tr -d ' ')
      [ -z "$dep" ] && continue
      grep -qF "| $dep |" "$agents_file" 2>/dev/null && redundant+=("$dep")
    done <<< "$(echo "$depends" | tr -d '[]' | tr ',' '\n')"
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
      sname=$(echo "$line" | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}')
      spath=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); print $4}')
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
    done < <(sed -n '/AI-SKILLS:BEGIN/,/AI-SKILLS:END/p' "$agents_file" \
               | grep "^| " | grep -v "^| Skill")
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
  if command -v claude &>/dev/null; then
    local settings="$HOME/.claude/settings.json"
    if [ ! -f "$settings" ]; then
      hook_issues=4
    else
      for hook_script in auto-handoff.sh handoff-inject.sh auto-polish-trigger.sh pre-commit-check.sh; do
        grep -qF "$hook_script" "$settings" 2>/dev/null || (( hook_issues++ )) || true
      done
    fi
    echo ""
    if [ "$hook_issues" -eq 0 ]; then
      echo "Claude hooks: [ok]"
    else
      echo "Claude hooks: [not configured] ($hook_issues missing)"
      echo "  Run: $SKILLS_ROOT/init-agent.sh claude"
    fi
  fi

  # pre-check sprint-check so issue count is correct before summary prints
  if $_has_sprint && ! command -v sprint-check &>/dev/null; then
    (( issues++ )) || true
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  echo ""
  if [ "$issues" -eq 0 ] && [ "$hook_issues" -eq 0 ]; then
    echo "All up to date."
  else
    [ "$issues" -gt 0 ] && echo "$issues issue(s) found. Run: $(basename "$0") refresh $project_dir"
    [ "$hook_issues" -gt 0 ] && echo "Agent hooks not wired. Run: $SKILLS_ROOT/init-agent.sh claude"
  fi

  # ── optional tooling hints ───────────────────────────────────────────────
  echo ""
  echo "Optional tools:"
  if command -v ast-grep &>/dev/null; then
    printf "  %-20s %s\n" "ast-grep" "[ok]  — security pre-scan active"
  else
    printf "  %-20s %s\n" "ast-grep" "[not installed]  — structural pre-scan unavailable (brew install ast-grep)"
  fi
  if command -v rtk &>/dev/null; then
    printf "  %-20s %s\n" "rtk" "[ok]  — token filtering active"
  else
    printf "  %-20s %s\n" "rtk" "[not installed]  — token savings unavailable (brew install rtk)"
  fi
  if $_has_sprint; then
    if command -v sprint-check &>/dev/null; then
      printf "  %-20s %s\n" "sprint-check" "[ok]  — kanban board ready"
    else
      printf "  %-20s %s\n" "sprint-check" "[not on PATH]  — run: $(basename "$0") refresh to fix"
    fi
  fi

  # ── sprint-check / tkt PATH check ────────────────────────────────────────
  if ( $_has_sprint || $_has_ticket ) && ! command -v tkt &>/dev/null; then
    local _tools_dir="$SKILLS_ROOT/tools"
    local _rc_file="$HOME/.zshrc"
    [[ "${SHELL:-}" == */bash ]] && _rc_file="$HOME/.bashrc"
    if ! grep -qF "$_tools_dir" "$_rc_file" 2>/dev/null; then
      echo ""
      echo "Action needed: sprint tools (tkt, sprint-check) are not on your PATH."
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
        sname=$(echo "$line" | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}')
        spath=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); print $4}')
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
  skills_in_table=$(sed -n '/AI-SKILLS:BEGIN/,/AI-SKILLS:END/p' "$agents_file" \
    | grep "^| " | grep -v "^| Skill" \
    | awk -F'|' '{gsub(/[[:space:]]/, "", $2); print $2}')

  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    local sf dep_str
    sf=$(find_skill "$skill" 2>/dev/null) || continue
    dep_str=$(fm_field "$sf" depends)
    [ -z "$dep_str" ] && continue
    while IFS= read -r dep; do
      dep=$(echo "$dep" | tr -d ' ')
      [ -n "$dep" ] && covered_deps+=("$dep")
    done <<< "$(echo "$dep_str" | tr -d '[]' | tr ',' '\n')"
  done <<< "$skills_in_table"

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
        sname=$(echo "$line" | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}')
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
  skills=$(sed -n '/AI-SKILLS:BEGIN/,/AI-SKILLS:END/p' "$agents_file" \
    | grep "^| " | grep -v "^| Skill" \
    | awk -F'|' '{gsub(/[[:space:]]/, "", $2); print $2}')

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
  while IFS= read -r line; do
    local sname
    sname=$(echo "$line" | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}')
    [[ "$sname" == "wrapup" ]] && _refresh_has_wrapup=true
    [[ "$sname" == "sprint" ]] && _refresh_has_sprint=true
  done < <(sed -n '/AI-SKILLS:BEGIN/,/AI-SKILLS:END/p' "$agents_file" \
             | grep "^| " | grep -v "^| Skill")

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

  # Strip YAML frontmatter and @-import lines, print body
  local body
  body=$(awk 'BEGIN{fm=0;done=0} /^---$/{if(fm)done=1; fm=1; next} done && /^@/{next} done{print}' "$skill_file")

  if command -v bat &>/dev/null; then
    echo "$body" | bat -l md --plain
  else
    echo "$body"
  fi
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
    ("PostToolUse",     "Bash", f"{scripts_path}/auto-polish-trigger.sh"),
    ("PreToolUse",      "Bash", f"{scripts_path}/pre-commit-check.sh"),
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

  if [ "$added" -gt 0 ] && command -v rtk &>/dev/null; then
    rtk init -g --auto-patch > /dev/null 2>&1 && echo "  [ok]     RTK hook wired" || echo "  [ok]     RTK hook already present"
  fi
}

_init_codex() {
  if ! command -v codex &>/dev/null; then
    echo "  [skip]  codex not installed"
    return 0
  fi
  if command -v rtk &>/dev/null; then
    rtk init -g --codex --auto-patch > /dev/null 2>&1 \
      && echo "  [added]  RTK wired into ~/.codex/AGENTS.md" \
      || echo "  [ok]     RTK already in ~/.codex/AGENTS.md"
  else
    echo "  [skip]  rtk not installed (optional)"
  fi
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
  echo "Codex:"
  _init_codex || any_fail=1

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
  printf "  %-30s %s\n" "skills add sprint [dir]"  "Full dev lifecycle (plan → build → ship)"
  printf "  %-30s %s\n" "skills addall [dir]"       "All available skills (recommended)"
  printf "  %-30s %s\n" "skills status [dir]"       "Check registration and hook health"
  printf "  %-30s %s\n" "skills refresh [dir]"      "Re-register + heal stale paths"
  printf "  %-30s %s\n" "skills list"               "Browse all available skills"
  echo ""
  echo "Default project dir is cwd — or pass a path explicitly."
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
    local sf deps
    sf=$(find_skill "$name" 2>/dev/null) || continue
    deps=$(fm_field "$sf" depends | tr -d '[]' | tr ',' '\n')
    while IFS= read -r dep; do
      dep=$(echo "$dep" | tr -d ' ')
      [ -n "$dep" ] && all_deps="$all_deps$dep "
    done <<< "$deps"
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

  # Regenerate CATALOG.md
  {
    echo "# canon Catalog"
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
  help)    cmd_help    "$@" ;;
  init)    cmd_init    "$@" ;;
  *)
    echo "Usage: skills.sh <list|add|addall|refresh|status|remove|delete|help|init> [skill] [project-dir]"
    echo ""
    echo "  list                    Show all available skills"
    echo "  add <skill> [dir]       Register a skill into a project (default: cwd)"
    echo "  addall [dir]            Register all available skills into a project (default: cwd)"
    echo "  refresh [dir]           Re-register all skills and update standards (default: cwd)"
    echo "  status [dir]            Show registered skills and detect issues (default: cwd)"
    echo "  remove <skill> [dir]    Unregister a skill from a project (default: cwd)"
    echo "  delete <skill>          Permanently remove a skill from canon"
    echo "  help <skill>            Show full documentation for a skill"
    echo "  init                    Wire Claude Code hooks for this install location"
    echo "  <skill> --h             Same as: skills.sh help <skill>"
    echo "  --scan [dir]            Show skills registered in a project (default: cwd)"
    exit 1
    ;;
esac
