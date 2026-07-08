#!/usr/bin/env bash
# tools/skills/cmd-refresh.sh — skills.sh refresh

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
