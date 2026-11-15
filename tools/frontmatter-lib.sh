#!/usr/bin/env bash
# frontmatter-lib.sh — shared YAML-style frontmatter field read/write, used by
# both tkt and sprint (extracted from tkt's original get_field/set_field to
# close a DRY gap — repo-audit 07-12-2026, t-2f2a). Byte-identical logic to
# what tkt carried inline before this extraction.
# Convention: route all frontmatter field mutations through these helpers
# (get_field / set_field / set_or_add_field / remove_field) — never re-inline
# the insert-before-second-`---` or strip-line awk in tkt/sprint (t-59e8).
# t-f7e6: wt_write_ok (the worktree link check every writer makes) lives in platform-lib.sh; a caller that sources only this file gets it.
# shellcheck source=platform-lib.sh
declare -F wt_write_ok >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

# get_field <file> <field> — read a frontmatter field's value. CRLF-tolerant:
# the leading `sub(/\r$/, "")` strips a trailing CR from each line before the
# `---` delimiter match and the value capture, so a CRLF-saved ticket.md (e.g.
# hand-edited on Windows) still parses and the returned value has no trailing
# `\r`. It is a strict no-op on LF files. NOTE: set_field/remove_field below
# still assume LF on their write path (stripping `\r` there could silently
# rewrite line endings) — only the read path is hardened here (t-4fca).
get_field() {
  local file="$1" field="$2"
  awk -v f="$field" '
    { sub(/\r$/, "") }
    /^---$/ { fm++; next }
    fm == 1 && match($0, "^" f ": ") { print substr($0, RSTART+RLENGTH); exit }
  ' "$file"
}

# t-f7e6: each writer below checks the file and its .tmp first (a planted link in a worktree must not carry the write out).
set_field() {
  local file="$1" field="$2" value="$3"
  wt_write_ok "$file" "${file}.tmp" || return 1
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
    wt_write_ok "$file" "${file}.tmp" || return 1
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
  wt_write_ok "$file" "${file}.tmp" || return 1
  awk -v f="$field" '
    /^---$/ { fm++; print; next }
    fm == 1 && match($0, "^" f ": ") { next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}
