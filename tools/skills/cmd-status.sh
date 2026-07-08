#!/usr/bin/env bash
# tools/skills/cmd-status.sh — skills.sh status

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
  compute_hook_status

  # ── Registered skills ────────────────────────────────────────────────────
  local _printed_skills_header=false
  render_skill_status_list

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
