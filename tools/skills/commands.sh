#!/usr/bin/env bash
# tools/skills/commands.sh — implementation of skills commands

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/skills/project.sh
source "$(dirname "${BASH_SOURCE[0]}")/project.sh"
# shellcheck source=tools/skills/agents.sh
source "$(dirname "${BASH_SOURCE[0]}")/agents.sh"
# shellcheck source=tools/skills/display.sh
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

offer_tkt_path() {
  local tools_dir="$SKILLS_ROOT/tools"
  local rc_file="$HOME/.zshrc"
  [[ "${SHELL:-}" == */bash ]] && rc_file="$HOME/.bashrc"
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

_post_register_prompts() {
  local name="$1" project_dir="$2"
  [[ "$name" == "ticket" || "$name" == "sprint-check" || "$name" == "sprint" ]] || return 0
  [[ "$name" == "sprint" ]] && ensure_sprint_project_marker "$project_dir"
  offer_tkt_path
}

_prune_redundant_deps() {
  local skill_file="$1" project_dir="$2" name="$3"
  local depends; depends=$(fm_field "$skill_file" depends)
  [ -z "$depends" ] && return 0
  local agents_file="$project_dir/AGENTS.md"
  local redundant=()
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    grep -qF "| $dep |" "$agents_file" 2>/dev/null && redundant+=("$dep")
  done < <(resolve_deps "$skill_file")
  [ ${#redundant[@]} -eq 0 ] && return 0
  for dep in "${redundant[@]}"; do
    cmd_remove "$dep" "$project_dir" > /dev/null || true
  done
  local dep_list
  dep_list=$(printf '%s, ' "${redundant[@]}")
  echo ""
  echo "Removed: ${dep_list%, } — now included in ${name} transitively."
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

  # Inject-style skills: write @-import to AGENTS.md only (not CLAUDE.md — avoid leakage)
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
    register_project "$project_dir"
    echo ""
    echo "Done. $desc"
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
  _init_claude "$project_dir/.claude/settings.json" 2>/dev/null | grep -E '^\s+\[added\]' || true

  echo ""
  echo "Done. $desc"

  _post_register_prompts "$name" "$project_dir"
  _prune_redundant_deps "$skill_file" "$project_dir" "$name"

  register_project "$project_dir"
  upsert_skills_symlinks "$project_dir" "$skill_file"
}

cmd_status() {
  local project_dir="${1:-$(pwd)}"
  local claude_file="$project_dir/CLAUDE.md"
  local agents_file="$project_dir/AGENTS.md"
  local issues=0

  echo "canon skills in: $project_dir"
  echo ""

  # ── Pre-collect skill names and flags ────────────────────────────────────
  local skill_names=() _has_wrapup=false _has_sprint=false _has_ticket=false
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    while IFS= read -r line; do
      local pre_name
      pre_name=$(skill_row_name "$line")
      [ -z "$pre_name" ] && continue
      skill_names+=("$pre_name")
      [[ "$pre_name" == "wrapup" ]] && _has_wrapup=true
      [[ "$pre_name" == "sprint" ]] && _has_sprint=true
      [[ "$pre_name" == "ticket" ]] && _has_ticket=true
    done < <(registered_skill_rows "$agents_file")
  fi

  # ── Compute hook status once — used for upgrade tip and display ──────────────
  local hook_issues=0
  local _hook_names=() _hook_tags=()
  if [ ${#skill_names[@]} -gt 0 ]; then
    local _hs="$project_dir/.claude/settings.json"
    for _h in auto-handoff.sh handoff-inject.sh sprint-inject.sh pre-commit-check.sh subagent-log.sh; do
      _hook_names+=("$_h")
      local _hook_path="$SKILLS_ROOT/scripts/$_h"
      [[ "$_h" == "subagent-log.sh" ]] && _hook_path="$SKILLS_ROOT/tools/$_h"
      if grep -qF "$_h" "$_hs" 2>/dev/null && [ -f "$_hook_path" ]; then
        _hook_tags+=("ok")
      else
        _hook_tags+=("not wired")
        (( hook_issues++ )) || true
      fi
    done
  fi

  # ── Registered skills ────────────────────────────────────────────────────
  local _printed_skills_header=false
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    echo "Skills:"
    _printed_skills_header=true
    while IFS= read -r line; do
      local sname spath
      sname=$(skill_row_name "$line")
      spath=$(skill_row_path "$line")
      [ -z "$sname" ] && continue

      local tag="ok"
      [ ! -f "$spath" ] && tag="broken ref" && (( issues++ )) || true

      local canon_file
      canon_file=$(find_skill "$sname" 2>/dev/null || true)
      if [ -n "$canon_file" ] && [ "$canon_file" != "$spath" ]; then
        tag="stale path"
        (( issues++ )) || true
      fi

      if [[ "$sname" == "wrapup" ]] && ! $_has_sprint && [ "$tag" = "ok" ]; then
        tag="upgrade available → sprint"
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
  fi

  # Also show inject-style @-imports (sit outside the AI-SKILLS block)
  if [ -f "$agents_file" ]; then
    while IFS= read -r imp; do
      local ipath="${imp#@}"
      local iname; iname=$(basename "$ipath" .md)
      local itag="ok"
      [ ! -f "$ipath" ] && itag="broken ref" && (( issues++ )) || true
      if ! $_printed_skills_header; then
        echo "Skills:"
        _printed_skills_header=true
      fi
      printf "  %-25s %s\n" "$iname" "[$itag]"
    done < <(awk '/AI-SKILLS:BEGIN/{skip=1} /AI-SKILLS:END/{skip=0; next} !skip && /^@/' "$agents_file" 2>/dev/null || true)
  fi

  if ! $_printed_skills_header; then
    echo "Skills: none"
  fi

  # ── Upgrade tip (merged with hook fix when both apply) ────────────────────
  local _upgrade_fix_shown=false
  if $_has_wrapup && ! $_has_sprint; then
    echo ""
    if [ "$hook_issues" -gt 0 ]; then
      printf "Fix both: %s add sprint %s\n" "$(basename "$0")" "$project_dir"
      _upgrade_fix_shown=true
    else
      echo "Tip: wrapup + capture are now part of the sprint skill."
      printf "  Upgrade: %s add sprint %s\n" "$(basename "$0")" "$project_dir"
    fi
  fi

  # ── @-imports in CLAUDE.md and AGENTS.md ────────────────────────────────
  echo ""
  for check_file in "$claude_file" "$agents_file"; do
    [ -f "$check_file" ] || continue
    local broken=()
    while IFS= read -r imp; do
      local path="${imp#@}"
      [ ! -f "$path" ] && broken+=("$imp")
    done < <(grep "^@" "$check_file" 2>/dev/null || true)
    if [ ${#broken[@]} -gt 0 ]; then
      echo "Broken @-imports ($(basename "$check_file")):"
      printf '  %s\n' "${broken[@]}"
      (( issues += ${#broken[@]} )) || true
      echo ""
    fi
  done

  # ── Claude Code hook display (uses pre-computed _hook_names/_hook_tags) ─────
  if [ ${#_hook_names[@]} -gt 0 ]; then
    echo ""
    echo "Claude hooks:"
    local _i
    for (( _i=0; _i<${#_hook_names[@]}; _i++ )); do
      printf "  %-25s [%s]\n" "${_hook_names[$_i]}" "${_hook_tags[$_i]}"
    done
    if [ "$hook_issues" -gt 0 ] && ! $_upgrade_fix_shown; then
      printf "  Run: %s add <skill> %s\n" "$(basename "$0")" "$project_dir"
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
    if [ "$hook_issues" -gt 0 ] && ! $_upgrade_fix_shown; then
      printf "Agent hooks not wired. Run: %s add <skill> %s\n" "$(basename "$0")" "$project_dir"
    fi
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
  for prune_file in "$claude_file" "$agents_file"; do
    [ -f "$prune_file" ] || continue
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      [[ "$line" == *"[pruned]"* ]] && continue
      if [[ "$line" == @"$SKILLS_ROOT"/* ]]; then
        echo "  [pruned]  legacy @-import: $line" >&2
        continue
      fi
      printf '%s\n' "$line"
    done < "$prune_file" > "$tmp" && mv "$tmp" "$prune_file"
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

  if [ -f "$claude_file" ] && [ -f "$agents_file" ]; then
    local agents_imports tmp
    agents_imports=$(grep "^@" "$agents_file" 2>/dev/null || true)
    if [ -n "$agents_imports" ]; then
      tmp=$(mktemp)
      while IFS= read -r line; do
        if [[ "$line" == @* ]] && grep -qxF "$line" <<< "$agents_imports"; then
          echo "  [pruned]  duplicate @-import in CLAUDE.md: $line" >&2
        else
          printf '%s\n' "$line"
        fi
      done < "$claude_file" > "$tmp" && mv "$tmp" "$claude_file"
    fi
  fi

  echo ""

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

  local skills_in_table covered_deps=()
  skills_in_table=$(registered_skill_names "$agents_file")

  while IFS= read -r dep; do
    [ -n "$dep" ] && covered_deps+=("$dep")
  done < <(covered_deps_for_skills <<< "$skills_in_table")

  if [ ${#covered_deps[@]} -gt 0 ]; then
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
      fi
      printf '%s\n' "$line"
    done < "$agents_file" > "$tmp" && mv "$tmp" "$agents_file"
  fi

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
  fi

  echo "Unregistered: $skill"

  remove_skills_symlinks "$project_dir" "$skill_file"

  if [ -z "$(registered_skill_names "$agents_file" 2>/dev/null)" ]; then
    deregister_project "$project_dir"
    remove_skills_symlinks "$project_dir"
  fi
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
  [ -n "$depends" ] && printf '\n\x1b[2mDepends:\x1b[0m %s\n'   "$depends"

  printf '\n%s\n\n' "$divider"
}

_print_usage() {
  echo "Usage: skills.sh <command> [skill] [project-dir]"
  echo ""
  echo "  list                    Show all available skills"
  echo "  add <skill> [dir]       Register a skill into a project (default: cwd)"
  echo "  addall [dir]            Register all available skills into a project (default: cwd)"
  echo "  refresh [dir]           Prune stale @-imports and sync standards (default: cwd)"
  echo "  status [dir]            Show registered skills and detect issues (default: cwd)"
  echo "  remove <skill> [dir]    Unregister a skill from a project (default: cwd)"
  echo "  help <skill>            Show full documentation for a skill (alias: <skill> --h)"
  echo "  init                    Set up this canon install: wire project hooks,"
  echo "                          migrate stale global hooks, install Pi extension,"
  echo "                          record install path"
  echo "  uninstall               Remove canon hooks/config for this install"
  echo ""
  echo "Contributor commands (canon repo only): canon-dev.sh catalog|lint|delete"
}

cmd_init() {
  echo "canon init — wiring agent hooks from: $SKILLS_ROOT"
  echo ""

  mkdir -p "$HOME/.config/canon"
  echo "$SKILLS_ROOT" > "$HOME/.config/canon/install_path"

  local any_fail=0

  echo "Claude Code (canon project hooks):"
  _init_claude "$SKILLS_ROOT/.claude/settings.json" || any_fail=1

  echo ""
  echo "Claude Code (migrate stale global hooks):"
  _uninstall_claude "$HOME/.claude/settings.json" || any_fail=1

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
  echo "Git hooks:"
  bash "$SKILLS_ROOT/scripts/install-hooks.sh" || any_fail=1

  offer_tkt_path

  echo ""
  _print_usage
  echo ""
  echo "Before deleting this install, remove canon hooks with:"
  echo "  skills.sh uninstall"
}

cmd_uninstall() {
  echo "canon uninstall — removing agent hooks for: $SKILLS_ROOT"
  echo ""

  local any_fail=0

  echo "Registered projects:"
  if [ ! -f "$PROJECTS_FILE" ] || [ ! -s "$PROJECTS_FILE" ]; then
    echo "  [skip]  no registered projects"
  else
    local proj
    while IFS= read -r proj; do
      printf '  %s\n' "$proj"
    done < "$PROJECTS_FILE"
    echo ""
    while IFS= read -r proj; do
      if [ ! -d "$proj" ]; then
        echo "  [skip]  not found: $proj"
        continue
      fi
      for f in "$proj/CLAUDE.md" "$proj/AGENTS.md"; do
        strip_canon_project_imports "$f"
      done
      if [ -f "$proj/AGENTS.md" ] && grep -qF "AI-SKILLS:BEGIN" "$proj/AGENTS.md" 2>/dev/null; then
        awk '
          /<!-- AI-SKILLS:BEGIN -->/ { skip=1; next }
          /<!-- AI-SKILLS:END -->/   { skip=0; next }
          !skip                       { print }
        ' "$proj/AGENTS.md" > "$proj/AGENTS.md.tmp" && mv "$proj/AGENTS.md.tmp" "$proj/AGENTS.md"
      fi
      remove_skills_symlinks "$proj"
      _uninstall_claude "$proj/.claude/settings.json" 2>&1 | sed 's/^/  /' || true
      echo "  [cleaned]  $proj"
    done < "$PROJECTS_FILE"
  fi

  echo ""
  echo "Claude Code (canon project hooks):"
  _uninstall_claude "$SKILLS_ROOT/.claude/settings.json" || any_fail=1

  echo ""
  echo "Claude Code (stale global hooks):"
  _uninstall_claude "$HOME/.claude/settings.json" || any_fail=1

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
    [[ "$dir" == */tools ]] && continue
    [[ "$dir" == */standards ]] && continue
    while IFS= read -r f; do
      local name already=0
      name=$(fm_field "$f" name)
      [ -z "$name" ] && continue
      [ "$(fm_field "$f" hidden)" = "true" ] && continue
      for s in "${seen[@]+"${seen[@]}"}"; do [ "$s" = "$name" ] && already=1 && break; done
      [ "$already" -eq 0 ] && names+=("$name") && seen+=("$name")
    done < <(skill_files_in_dir "$dir" | sort)
  done

  [ ${#names[@]} -eq 0 ] && { echo "No skills found."; exit 1; }

  local all_deps=" "
  for name in "${names[@]}"; do
    local sf
    sf=$(find_skill "$name" 2>/dev/null) || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] && all_deps="$all_deps$dep "
    done < <(resolve_deps "$sf")
  done

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
