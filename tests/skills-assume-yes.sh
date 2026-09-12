#!/usr/bin/env bash
# tests/skills-assume-yes.sh — t-b47a: SKILLS_SH_ASSUME_YES makes the three
# project-scoped setup prompts (CLAUDE.md<->AGENTS.md bridge, model-tiers
# note, subagent-log.sh permission) apply immediately with no /dev/tty I/O —
# this is what lets Cockpit's register-skill flow (an API/browser-driven
# caller, not a human at a terminal) actually apply them, instead of a
# prompt silently timing out on whatever terminal launched the board.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp_home="$(mktemp -d)"
export HOME="$tmp_home"
trap 'rm -rf "$tmp_home"' EXIT

# --- C1/C2: ensure_claude_bridge (both sprint and efficiency reach it) ------

project="$(make_project)"
trap 'rm -rf "$tmp_home" "$project"' EXIT
printf 'Some hand-authored content.\n' > "$project/CLAUDE.md"

SKILLS_SH_ASSUME_YES=1 "$SKILLS" add sprint "$project" >/dev/null
assert_grep '^@AGENTS\.md$' "$project/CLAUDE.md"
assert_grep 'Some hand-authored content\.' "$project/CLAUDE.md"

# Re-add stays a no-op (idempotent), no duplicate import line.
SKILLS_SH_ASSUME_YES=1 "$SKILLS" add sprint "$project" >/dev/null
assert_count 1 "@AGENTS.md" "$project/CLAUDE.md"

# --- C2: offer_model_tiers_note (efficiency only) ---------------------------

project2="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project2"' EXIT
printf '# Agents\n' > "$project2/AGENTS.md"

SKILLS_SH_ASSUME_YES=1 "$SKILLS" add efficiency "$project2" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project2/AGENTS.md"

# Re-add stays a no-op.
SKILLS_SH_ASSUME_YES=1 "$SKILLS" add efficiency "$project2" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project2/AGENTS.md"

# --- C2: offer_subagent_log_permission (sprint only) ------------------------

project3="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project2" "$project3"' EXIT

SKILLS_SH_ASSUME_YES=1 "$SKILLS" add sprint "$project3" >/dev/null
assert_file_exists "$project3/.claude/settings.json"
assert_count 1 "Bash(subagent-log.sh:*)" "$project3/.claude/settings.json"

# --- C4 regression: offer_tkt_path (PATH edit) is UNAFFECTED ----------------
# It never checks SKILLS_SH_ASSUME_YES — this ticket deliberately leaves it
# on its original /dev/tty-gated behavior (PATH is covered by
# install.sh/install.ps1, not project-scoped like the three above).

project4="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project2" "$project3" "$project4"' EXIT
rc_file="$tmp_home/.bashrc"
export SHELL="/bin/bash"
[ -f "$rc_file" ] || : > "$rc_file"
before_rc="$(cat "$rc_file")"

SKILLS_SH_ASSUME_YES=1 PATH="/usr/bin:/bin" "$SKILLS" add sprint "$project4" >/dev/null
after_rc="$(cat "$rc_file")"
assert_eq "$before_rc" "$after_rc"

printf 'skills-assume-yes: ok\n'
