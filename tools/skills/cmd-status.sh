#!/usr/bin/env bash
# tools/skills/cmd-status.sh — skills.sh status

cmd_status() {
  if [ "${1:-}" = "--json" ]; then shift; _status_json "${1:-$(pwd)}"; return; fi
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
  local _printed_skills_header=false _skills_moved=false
  render_skill_status_list
  if $_skills_moved; then
    echo ""
    echo "  The skill paths or links point somewhere else: this project was moved or copied, or canon was installed again."
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

# _status_json <dir> — t-6541: the registered skills' problems as JSON for the board's Projects card (internal/board runs this; it
# never re-implements the check): {"skills":[{"name":"sprint","problems":["missing link .claude/skills"]}],"issues":1}.
_status_json() {
  local project_dir agents_file line sname spath probs p out="" sep="" n=0 ps psep
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || { echo "skills.sh status --json: no such folder: $1" >&2; return 1; }
  agents_file="$project_dir/AGENTS.md"
  _jq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"; }
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    while IFS= read -r line; do
      sname=$(skill_row_name "$line"); spath=$(skill_row_path "$line")
      [ -z "$sname" ] && continue
      probs="$(skill_problems "$sname" "$spath")"
      ps=""; psep=""
      while IFS= read -r p; do [ -n "$p" ] || continue; ps="$ps$psep$(_jq "$p")"; psep=","; n=$((n + 1)); done <<< "$probs"
      out="$out$sep{\"name\":$(_jq "$sname"),\"problems\":[$ps]}"; sep=","
    done < <(registered_skill_rows "$agents_file")
  fi
  printf '{"skills":[%s],"issues":%d}\n' "$out" "$n"
}

