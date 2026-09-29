#!/usr/bin/env bash
# t-3447: sprint depends on wrapup, learnings-sweep and promote-learnings. In a project whose
# .claude/skills / .agents/skills are REAL directories (project-local skills, t-1b2c) `skills.sh add sprint`
# links each dependency individually, `refresh` picks the new ones up for a project set up before, and
# none of them gets an AGENTS.md row. In the common case the whole skills/ dir is one symlink, unchanged.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
common="$(make_project)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$project" "$common" "$tmp_home"' EXIT

touch "$tmp_home/.zshrc"
export HOME="$tmp_home"
export SHELL="/bin/zsh"
export PATH="$TOOLS_DIR:$PATH"

sprint_row="| sprint | dev | $ROOT/skills/sprint/SKILL.md |"
deps=(sprint wrapup learnings-sweep promote-learnings)

assert_linked() {
  local skill link
  for link in "$project/.claude/skills" "$project/.agents/skills"; do
    [[ -d "$link" && ! -L "$link" ]] || fail "$link should stay a real directory"
    [[ -f "$link/local-skill/SKILL.md" ]] || fail "$link/local-skill was disturbed"
    for skill in "$@"; do
      [[ -L "$link/$skill/SKILL.md" ]] || fail "expected $link/$skill/SKILL.md to be a symlink"
      [[ "$(readlink "$link/$skill/SKILL.md")" == "$ROOT/skills/$skill/SKILL.md" ]] \
        || fail "$link/$skill/SKILL.md points at $(readlink "$link/$skill/SKILL.md")"
    done
  done
}

# --- real-directory project ---------------------------------------------------------------
printf '# Claude\n' > "$project/CLAUDE.md"
printf '# Agents\n' > "$project/AGENTS.md"
for d in .claude/skills .agents/skills; do
  mkdir -p "$project/$d/local-skill"
  printf 'local\n' > "$project/$d/local-skill/SKILL.md"
done

"$SKILLS" add sprint "$project" >/dev/null
assert_linked "${deps[@]}"
assert_count 1 "$sprint_row" "$project/AGENTS.md"
for dep in wrapup learnings-sweep promote-learnings; do
  assert_count 0 "| $dep " "$project/AGENTS.md"        # a dependency never gets an AGENTS.md row
done

# --- refresh: a project set up before this change lacks the two new entries --------------------
for d in .claude/skills .agents/skills; do
  rm -rf "$project/$d/learnings-sweep" "$project/$d/promote-learnings"
done
agents_before="$(cat "$project/AGENTS.md")"
"$SKILLS" refresh "$project" >/dev/null 2>&1
assert_linked "${deps[@]}"
assert_eq "$agents_before" "$(cat "$project/AGENTS.md")"      # refresh touched nothing else in the table

snapshot() { find "$project/.claude/skills" "$project/.agents/skills" | sort; cat "$project/AGENTS.md"; }
snap_before="$(snapshot)"
"$SKILLS" refresh "$project" >/dev/null 2>&1
assert_eq "$snap_before" "$(snapshot)"                        # a second refresh is a no-op

# --- a dependency is internal: it cannot be registered directly ---------------------------------
if out="$("$SKILLS" add promote-learnings "$project" 2>&1)"; then fail "add promote-learnings should be refused (internal skill)"; fi
assert_contains "$out" "internal skill and cannot be registered directly"
assert_count 0 "| promote-learnings " "$project/AGENTS.md"

# --- a project that registered one by hand before this change: refresh prunes the row (it is hidden now), the entry stays ---
awk -v row="| promote-learnings | agent-ops | $ROOT/skills/promote-learnings/SKILL.md |" \
  '{ print } /^\| sprint \| dev \|/ { print row }' "$project/AGENTS.md" > "$project/AGENTS.md.new" && mv "$project/AGENTS.md.new" "$project/AGENTS.md"
assert_count 1 "| promote-learnings " "$project/AGENTS.md"
refresh_out="$("$SKILLS" refresh "$project" 2>&1)"
assert_contains "$refresh_out" "[pruned]  hidden skill from table: promote-learnings"
assert_count 0 "| promote-learnings " "$project/AGENTS.md"
assert_count 1 "$sprint_row" "$project/AGENTS.md"
assert_linked "${deps[@]}"

# --- common case: no pre-existing skills dir -> one symlink to skills/, one table row --------------
printf '# Claude\n' > "$common/CLAUDE.md"
printf '# Agents\n' > "$common/AGENTS.md"
"$SKILLS" add sprint "$common" >/dev/null
[[ -L "$common/.claude/skills" && "$(readlink "$common/.claude/skills")" == "$ROOT/skills" ]] || fail "common case: .claude/skills should point at $ROOT/skills"
[[ -L "$common/.agents/skills" && "$(readlink "$common/.agents/skills")" == "$ROOT/skills" ]] || fail "common case: .agents/skills should point at $ROOT/skills"
assert_eq "1" "$(grep -c '^| [a-z-]* | ' "$common/AGENTS.md")"

printf 'skills-sprint-deps: ok\n'
