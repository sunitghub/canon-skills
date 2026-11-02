#!/usr/bin/env bash
# tools/skills/display.sh — UI/Display logic for skills commands

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Reads: project_dir, _has_sprint, _has_ticket (caller locals, shared via bash's
# dynamic scoping). Sets: hook_issues, _hook_names, _hook_tags.
compute_hook_status() {
  hook_issues=0
  _hook_names=() _hook_tags=()
  # canon installs no Claude Code hooks (settings.json) anymore — only a git-native
  # pre-commit hook for sprint/ticket projects. Anything legacy in settings.json is
  # migrated away by `add`/`init`, not reported here as an "issue."
  if $_has_sprint || $_has_ticket; then
    _hook_names+=("pre-commit (git)")
    local _pc_hooks _pc_hook
    _pc_hooks="$(_git_hooks_dir "$project_dir")"   # a linked worktree's hooks live in the common git dir (t-80fc)
    _pc_hook="$_pc_hooks/pre-commit"
    if [ -f "$_pc_hook" ] && grep -qF "canon-managed-pre-commit-hook" "$_pc_hook" 2>/dev/null; then
      _hook_tags+=("ok")
    elif [ ! -d "$_pc_hooks" ]; then
      _hook_tags+=("skipped — not a git repo")
    else
      _hook_tags+=("not wired")
      (( hook_issues++ )) || true
    fi
  fi
}

# skill_problems <name> <row path> — t-6541: one line per problem with a registered skill (the one owner of this check: status and
# status --json, and through it the board's Projects card): "broken ref" (the AGENTS.md row's file is missing), "stale path" (the
# row names another copy than this install's), "missing link .claude/skills" / ".agents/skills" (the folder agents load the skill
# from has no <name>/SKILL.md) and "stale link …" (it resolves to another copy). Reads project_dir. Prints nothing when healthy.
skill_problems() {
  local name="$1" spath="$2" canon_file real link f
  canon_file="$(find_skill "$name" 2>/dev/null || true)"
  [ -f "$spath" ] || echo "broken ref"
  [ -n "$canon_file" ] && [ "$canon_file" != "$spath" ] && echo "stale path"
  [ -n "$canon_file" ] || return 0
  # review: only a skill folder (skills/<name>/SKILL.md) is loaded through the links; a row such as efficiency's
  # (standards/efficiency.md) has no folder to link, so it is checked by its row alone
  [ "$(basename "$canon_file")" = SKILL.md ] && [ "$(basename "$(dirname "$canon_file")")" = "$name" ] || return 0
  real="$(cd -P "$(dirname "$canon_file")" 2>/dev/null && pwd -P)" || return 0
  for link in .claude/skills .agents/skills; do
    f="$project_dir/$link/$name/SKILL.md"
    if [ ! -f "$f" ]; then echo "missing link $link"
    elif [ "$(cd -P "$(dirname "$(_resolve_file "$f")")" 2>/dev/null && pwd -P)" != "$real" ]; then echo "stale link $link"; fi
  done
}

# _resolve_file <path> — the file a path ends at, following a symlinked file (a per-skill folder's SKILL.md link) once per hop.
_resolve_file() {
  local f="$1" t n=0
  while [ -L "$f" ] && [ $n -lt 8 ]; do
    t="$(readlink "$f")"; case "$t" in /*|[A-Za-z]:*) f="$t" ;; *) f="$(dirname "$f")/$t" ;; esac; n=$((n + 1))
  done
  printf '%s\n' "$f"
}

# Reads: agents_file, _has_sprint, _has_wrapup (caller locals). Prints the
# "Skills:" list. Updates caller locals: issues, _printed_skills_header.
render_skill_status_list() {
  _printed_skills_header=false
  if [ -f "$agents_file" ] && grep -qF "AI-SKILLS:BEGIN" "$agents_file" 2>/dev/null; then
    echo "Skills:"
    _printed_skills_header=true
    while IFS= read -r line; do
      local sname spath
      sname=$(skill_row_name "$line")
      spath=$(skill_row_path "$line")
      [ -z "$sname" ] && continue

      # t-6541: every problem is named, never one tag over another (a broken row was also counted as stale, then hidden)
      local probs tag
      probs="$(skill_problems "$sname" "$spath")"
      if [ -n "$probs" ]; then
        tag="$(printf '%s' "$probs" | paste -sd, - | sed 's/,/, /g')"
        (( issues += $(printf '%s\n' "$probs" | grep -c .) )) || true
        _skills_moved=true
      else
        tag="ok"
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

  if ! $_printed_skills_header; then
    echo "Skills: none"
  fi
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
    done < <(skill_files_in_dir "$dir")
  done

  # Collect all valid entries across all dirs, then sort by category then name
  local entries=()
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      local name category
      name=$(fm_field "$f" name)
      [ -z "$name" ] && continue
      [ "$(fm_field "$f" hidden)" = "true" ] && continue
      local is_dep=0
      for dep in "${all_dep_names[@]+"${all_dep_names[@]}"}"; do
        [ "$dep" = "$name" ] && is_dep=1 && break
      done
      [ "$is_dep" -eq 1 ] && continue
      category=$(fm_field "$f" category)
      entries+=("${category}"$'\t'"${name}"$'\t'"${f}")
    done < <(skill_files_in_dir "$dir")
  done

  local prev_cat=""
  while IFS=$'\t' read -r category name f; do
    local desc
    desc=$(fm_field "$f" description)

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

  done < <(printf '%s\n' "${entries[@]+"${entries[@]}"}" | sort -t$'\t' -k1,1 -k2,2)
  echo ""
  printf "${dim}To uninstall: %s uninstall && rm -rf ~/.canon${reset}\n" "$(basename "$0")"
}
