#!/usr/bin/env bash
# tests/skills-not-commands.sh — t-ceec: a SKILL is run through the Skill tool (or by reading its SKILL.md),
# never as a shell command. A doc that shows a skill with an argument inside backticks (`learnings-sweep <id>`,
# `skill-export <name>`) teaches agents to type a command that does not exist ("command not found"), and the
# step it carried silently never runs. Slash forms (`/doc-audit`) and bare mentions of a skill name stay fine.
#
# Skill names come from skills/*/SKILL.md; a name that is also an executable in tools/ (sprint) is a real
# command and is skipped. Derived from the tree, so a skill added later is covered without editing this file.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

cd "$ROOT"

# What follows the skill name inside the backticks, one of: <placeholder>, --flag, a ticket id, $var, [optional].
arg='( <| --| t-[a-z0-9]{4}| \$| \[)'

hits=""
for dir in skills/*/; do
  name="$(basename "$dir")"
  [[ -f "$dir/SKILL.md" ]] || continue
  [[ -x "tools/$name" || -x "tools/$name.sh" ]] && continue
  found="$(grep -rnE --include='*.md' "\`${name}${arg}[^\`]*\`" skills docs standards tools README.md AGENTS.md CLAUDE.md 2>/dev/null || true)"
  [[ -n "$found" ]] && hits+="$found"$'\n'
done

if [[ -n "$hits" ]]; then
  printf '%s' "$hits" >&2
  fail "a doc shows a skill as a shell command (skills run via the Skill tool or by reading their SKILL.md; reword, or use the slash form /<skill>)"
fi

printf 'skills-not-commands: ok\n'
