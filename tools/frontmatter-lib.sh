#!/usr/bin/env bash
# frontmatter-lib.sh — shared YAML-style frontmatter field read/write, used by
# both tkt and sprint (extracted from tkt's original get_field/set_field to
# close a DRY gap — repo-audit 07-12-2026, t-2f2a). Byte-identical logic to
# what tkt carried inline before this extraction.

get_field() {
  local file="$1" field="$2"
  awk -v f="$field" '
    /^---$/ { fm++; next }
    fm == 1 && match($0, "^" f ": ") { print substr($0, RSTART+RLENGTH); exit }
  ' "$file"
}

set_field() {
  local file="$1" field="$2" value="$3"
  awk -v f="$field" -v v="$value" '
    /^---$/ { fm++; print; next }
    fm == 1 && match($0, "^" f ": ") { print f ": " v; next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}
