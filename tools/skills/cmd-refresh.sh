#!/usr/bin/env bash
# tools/skills/cmd-refresh.sh — skills.sh refresh

# t-50f7: once the install is in the versioned layout, an @-import in CLAUDE.md/AGENTS.md that names the old location (<home>/standards/...
# or a package) is re-pointed at <home>/current, or dropped when the current line is already there. Only a line whose new target exists.
_retarget_imports() {
  local f line new tmp cr changed
  for f in "$1/CLAUDE.md" "$1/AGENTS.md"; do
    [ -f "$f" ] && grep -q '^@/' "$f" || continue
    tmp="$(mktemp)"; changed=0
    while IFS= read -r line || [ -n "$line" ]; do
      cr=""; case "$line" in *$'\r') cr=$'\r'; line="${line%$'\r'}" ;; esac
      if [[ "$line" == @/* ]] && new="$(canon_current_path "${line#@}")" && [ -e "$new" ]; then
        changed=1
        if has_line "@$new" "$f"; then echo "  [pruned]  @-import of the old location (current's is there): $line" >&2; continue; fi
        echo "  [updated]  @-import now names current: @$new" >&2; line="@$new"
      fi
      printf '%s%s\n' "$line" "$cr"
    done < "$f" > "$tmp"
    if [ "$changed" = 1 ]; then cat "$tmp" > "$f"; fi
    rm -f "$tmp"
  done
  return 0
}

# t-50f7: a linked worktree of the project whose skills link names the old location gets current's links (link_worktree is idempotent).
_retarget_worktree_links() {
  local pd wt link
  pd="$(cd "$1" && pwd -P)" || return 0
  git -C "$pd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ "$wt" != "$pd" ] && [ -d "$wt" ] || continue
    for link in "$wt/.claude/skills" "$wt/.agents/skills"; do
      if _is_dir_link "$link" && canon_current_path "$(_read_dir_link "$link")" >/dev/null; then link_worktree "$wt"; break; fi
    done
  done < <(git -C "$pd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  return 0
}

# t-351c: a pre-June project carries `@<root>/skills/<name>.md` (skills moved to skills/<name>/SKILL.md, and the code that recognised
# these lines went with the old layout). True only when <root> is a canon root (this install, or a checkout with tools/skills.sh)
# and <name> is a skill there; any other @ line, look-alikes included, is the user's.
_is_old_skill_import() {
  local path="${1%$'\r'}" root name
  [[ "$path" == @*/skills/*.md ]] || return 1
  path="${path#@}"; root="${path%/skills/*}"; name="${path##*/}"; name="${name%.md}"
  [ -n "$root" ] && [ -n "$name" ] && [[ "$name" != */* ]] || return 1
  [ "$root" = "$SKILLS_ROOT" ] || [ -f "$root/tools/skills.sh" ] || return 1
  [ -f "$root/skills/$name/SKILL.md" ]
}

# t-351c: a run of 2+ blank lines is collapsed to one only where canon left it: between a canon line (its @-import, @PROMOTED.md or a
# block's END marker) and the next canon line (an import or a block's BEGIN marker). A blank run in the user's own text stays.
_collapse_canon_blank_runs() {
  local f="$1" tmp
  [ -f "$f" ] || return 0
  tmp="$(mktemp)"
  awk '
    function canon(l) { return l ~ /^@PROMOTED\.md$/ || l ~ /^@.*\/standards\/[^\/]+\.md$/ || l ~ /^@.*\/skills\/[^\/]+\/SKILL\.md$/ }
    function isend(l) { return l ~ /^<!-- (MODEL-TIERS|AI-SKILLS|canon:[a-z-]+):END -->$/ }
    function isbegin(l) { return l ~ /^<!-- (MODEL-TIERS|AI-SKILLS|canon:[a-z-]+):BEGIN -->$/ }
    { l = $0; sub(/\r$/, "", l) }
    l == "" { buf[++n] = $0; next }
    { if (n >= 2 && prev && (canon(l) || isbegin(l))) n = 1
      for (i = 1; i <= n; i++) print buf[i]
      n = 0; print; prev = canon(l) || isend(l) }
    END { for (i = 1; i <= n; i++) print buf[i] }' "$f" > "$tmp"
  if cmp -s "$tmp" "$f"; then rm -f "$tmp"; else cat "$tmp" > "$f"; rm -f "$tmp"; echo "  [AGENTS.md]  collapsed stacked blank lines canon left between its blocks" >&2; fi
  return 0
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

  _retarget_imports "$project_dir"
  _retarget_worktree_links "$project_dir"
  retarget_install_paths

  # A registered inject skill (efficiency, agent-design) owns its @-import in AGENTS.md — not legacy.
  # Pruning it only for cmd_add to re-append it churned every refresh and moved the line (t-bd3e).
  local keep_imports="" sname sfile
  while IFS= read -r sname; do
    [ -z "$sname" ] && continue
    sfile=$(find_skill "$sname" 2>/dev/null) || continue
    if [ "$(fm_field "$sfile" inject)" = "true" ]; then keep_imports+="@$sfile"$'\n'; fi
  done < <(registered_skill_names "$agents_file")

  # ── Prune stale canon @-imports from CLAUDE.md and AGENTS.md ────────────
  for prune_file in "$claude_file" "$agents_file"; do
    [ -f "$prune_file" ] || continue
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      [[ "$line" == *"[pruned]"* ]] && continue
      if [ "$prune_file" = "$agents_file" ] && [ -n "$keep_imports" ] && grep -qxF -- "${line%$'\r'}" <<< "$keep_imports"; then
        printf '%s\n' "$line"
        continue
      fi
      if _is_old_skill_import "$line"; then
        echo "  [pruned]  old skill import (skills moved to skills/<name>/SKILL.md): $line" >&2
        continue
      fi
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

  _collapse_canon_blank_runs "$agents_file"

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
    # "left as is" too: a setup step that declined to act (e.g. a user-owned .claude/agents link, t-c774)
    # must be visible, not filtered out with the no-op noise.
    changes=$(printf '%s\n' "$output" | grep -E "added|updated|created|left as is|\[gitignore\]" || true)
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
