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

# set_or_add_field <file> <field> <value> — rewrite the existing "<field>: "
# line if present, else insert "<field>: <value>" as the last frontmatter field
# (immediately before the second "---"). Tickets created before a field existed
# have no line to rewrite, so set_field alone would be a silent no-op there.
set_or_add_field() {
  local file="$1" field="$2" value="$3"
  if grep -qE "^${field}: " "$file"; then
    set_field "$file" "$field" "$value"
  else
    awk -v f="$field" -v v="$value" '
      /^---$/ { c++; if (c == 2) { print f ": " v } print; next }
      { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

# remove_field <file> <field> — delete the "<field>: " line inside the
# frontmatter block if present; a content no-op when absent. Used for
# fields whose default state is represented by the line's absence.
remove_field() {
  local file="$1" field="$2"
  awk -v f="$field" '
    /^---$/ { fm++; print; next }
    fm == 1 && match($0, "^" f ": ") { next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}
