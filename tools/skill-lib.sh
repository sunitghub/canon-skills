#!/usr/bin/env bash
# skill-lib.sh — shared frontmatter helpers for skills.sh and canon-dev.sh
# Sourced after SKILLS_ROOT and SEARCH_DIRS are set. Not a standalone script.

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

resolve_deps() {
  local file="$1" dep_str
  dep_str=$(fm_field "$file" depends)
  [ -z "$dep_str" ] && return 0
  echo "$dep_str" | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -v '^$' || true
}
