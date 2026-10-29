#!/usr/bin/env bash
# t-351c: protects `skills.sh add` / `refresh` on a user's AGENTS.md: canon never leaves two blank lines in a row, a second
# refresh changes nothing, a blank run in the user's own text stays, and a pre-June `@<canon root>/skills/<name>.md` import goes.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"; projectb="$(make_project)"; projectc="$(make_project)"
tmp_home="$(mktemp -d)"; fake="$(mktemp -d)"; notcanon="$(mktemp -d)"
trap 'rm -rf "$project" "$projectb" "$projectc" "$tmp_home" "$fake" "$notcanon"' EXIT

touch "$tmp_home/.zshrc"
export HOME="$tmp_home" SHELL="/bin/zsh" SKILLS_SH_NO_TTY=1 PATH="$TOOLS_DIR:$PATH"
mkdir -p "$tmp_home/.config/canon"

# runs_of_blanks <file> — one line per run of blank lines: "<first line>:<length>"
runs_of_blanks() {
  awk '{ sub(/\r$/, "") } $0 == "" { if (!n++) s = NR; next } { if (n) print s ":" n; n = 0 } END { if (n) print s ":" n }' "$1"
}

# A canon checkout elsewhere (tools/skills.sh + skills/sprint/SKILL.md) and a look-alike folder that is not one.
mkdir -p "$fake/tools" "$fake/skills/sprint" "$notcanon/skills/sprint"
: > "$fake/tools/skills.sh"; : > "$fake/skills/sprint/SKILL.md"; : > "$notcanon/skills/sprint/SKILL.md"

# --- pre-0.10 layout: stacked blanks canon left, an old skill import, the user's own blank run and look-alike imports ---
cat > "$project/AGENTS.md" <<EOT
# Agents
User text.



User text after its own blank run.
@$fake/skills/sprint.md
@$fake/skills/nosuch.md
@$notcanon/skills/sprint.md
@/elsewhere/skills/x.md
User note before its own two blank lines.


@PROMOTED.md



<!-- MODEL-TIERS:BEGIN -->
old note
<!-- MODEL-TIERS:END -->


<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Paths are relative to the canon install.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
EOT
printf '%s\n' "$project" > "$tmp_home/.config/canon/projects"

out="$("$SKILLS" refresh "$project" 2>&1)"
assert_contains "$out" "old skill import"                            # names what it removed
assert_contains "$out" "collapsed stacked blank lines"
assert_count 0 "@$fake/skills/sprint.md" "$project/AGENTS.md"       # guard: canon-root old import removed
assert_count 1 "@$fake/skills/nosuch.md" "$project/AGENTS.md"       # guard: only a canon skill name
assert_count 1 "@$notcanon/skills/sprint.md" "$project/AGENTS.md"   # guard: only under a canon root
assert_count 1 "@/elsewhere/skills/x.md" "$project/AGENTS.md"
assert_count 1 "@PROMOTED.md" "$project/AGENTS.md"
# guard: the user's own blank runs are untouched, even the one that ends at a canon line
assert_eq "3 2" "$(runs_of_blanks "$project/AGENTS.md" | awk -F: 'NR <= 2 { printf "%s%s", (NR > 1 ? " " : ""), $2 }')"
stacked="$(runs_of_blanks "$project/AGENTS.md" | awk -F: 'NR > 2 && $2 > 1')"
[[ -z "$stacked" ]] || fail "canon left stacked blank lines: $stacked"

h1="$(md5sum "$project/AGENTS.md" | cut -d' ' -f1)"
"$SKILLS" refresh "$project" >/dev/null 2>&1
"$SKILLS" add sprint "$project" >/dev/null 2>&1
"$SKILLS" refresh "$project" >/dev/null 2>&1
assert_eq "$h1" "$(md5sum "$project/AGENTS.md" | cut -d' ' -f1)"   # guard: refresh and add are idempotent

# --- writers: the MODEL-TIERS and AI-SKILLS blocks add a separator only when the line above is not blank ---
printf '# Agents\n@PROMOTED.md\n\n' > "$projectb/AGENTS.md"
SKILLS_SH_ASSUME_YES=1 "$SKILLS" add efficiency "$projectb" >/dev/null 2>&1
assert_count 1 "MODEL-TIERS:BEGIN" "$projectb/AGENTS.md"
stacked="$(runs_of_blanks "$projectb/AGENTS.md" | awk -F: '$2 > 1')"
[[ -z "$stacked" ]] || fail "a writer stacked blank lines: $stacked"

# The MODEL-TIERS writer alone, after a blank line (the file ends on one).
awk '/<!-- MODEL-TIERS:BEGIN -->/ { skip = 1 } !skip { print } /<!-- MODEL-TIERS:END -->/ { skip = 0 }' "$projectb/AGENTS.md" > "$projectb/a.tmp"
mv "$projectb/a.tmp" "$projectb/AGENTS.md"
SKILLS_SH_ASSUME_YES=1 "$SKILLS" add efficiency "$projectb" >/dev/null 2>&1
assert_count 1 "MODEL-TIERS:BEGIN" "$projectb/AGENTS.md"
stacked="$(runs_of_blanks "$projectb/AGENTS.md" | awk -F: '$2 > 1')"
[[ -z "$stacked" ]] || fail "the MODEL-TIERS writer stacked blank lines: $stacked"

# The AI-SKILLS writer alone: a file that ends on a blank line gets the block without a second one.
printf '# Agents\n\n' > "$projectc/AGENTS.md"
"$SKILLS" add sprint "$projectc" >/dev/null 2>&1
assert_count 1 "AI-SKILLS:BEGIN" "$projectc/AGENTS.md"
stacked="$(runs_of_blanks "$projectc/AGENTS.md" | awk -F: '$2 > 1')"
[[ -z "$stacked" ]] || fail "the AI-SKILLS writer stacked blank lines: $stacked"
