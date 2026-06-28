#!/usr/bin/env bash
# tools/skills/display.sh — UI/Display logic for skills commands

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
