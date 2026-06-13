#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

home="$(mktemp -d)"
# Clean up both the temp home AND any project-local settings written to $ROOT
trap 'rm -rf "$home" "$ROOT/.claude/settings.json"' EXIT

mkdir -p "$home/.claude" "$home/.codex" "$home/.pi/agent/extensions" "$home/.config/canon"

# Hooks now live in <SKILLS_ROOT>/.claude/settings.json (project-local).
# Seed it with the 4 canon hooks so uninstall has something to remove.
mkdir -p "$ROOT/.claude"
cat > "$ROOT/.claude/settings.json" <<EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$ROOT/scripts/auto-handoff.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$ROOT/scripts/handoff-inject.sh"
          },
          {
            "type": "command",
            "command": "$ROOT/scripts/sprint-inject.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$ROOT/scripts/pre-commit-check.sh"
          }
        ]
      }
    ]
  }
}
EOF

# Also seed the global settings with a stale canon hook + unrelated content,
# to verify the migration path cleans it up while preserving the rest.
cat > "$home/.claude/settings.json" <<EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$ROOT/scripts/auto-handoff.sh"
          },
          {
            "type": "command",
            "command": "/usr/local/bin/user-stop"
          }
        ]
      }
    ]
  },
  "theme": "dark"
}
EOF

cat > "$home/.codex/AGENTS.md" <<EOF
# Codex

@$home/.codex/RTK.md

Keep this user content.
EOF

cat > "$home/.pi/agent/extensions/handoff.ts" <<'EOF'
const configPath = join(homedir(), ".config", "canon", "install_path");
const script = join(canonRoot, "scripts", "auto-handoff.sh");
EOF

printf '%s\n' "$ROOT" > "$home/.config/canon/install_path"

# ── Project registry setup ────────────────────────────────────────────────
# One valid project with canon @-imports and AI-SKILLS block
canon_project="$(mktemp -d)"
trap 'rm -rf "$home" "$ROOT/.claude/settings.json" "$canon_project"' EXIT

cat > "$canon_project/CLAUDE.md" <<EOF
@$ROOT/standards/efficiency.md
@$ROOT/skills/sprint.md
User content preserved.
EOF

cat > "$canon_project/AGENTS.md" <<EOF
@$ROOT/standards/efficiency.md
@$ROOT/skills/sprint.md

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Source: $ROOT

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | $ROOT/skills/sprint.md |
<!-- AI-SKILLS:END -->
User AGENTS content preserved.
EOF

# One stale entry pointing to a non-existent path
stale_path="/tmp/canon-uninstall-test-nonexistent-$$"

{
  printf '%s\n' "$canon_project"
  printf '%s\n' "$stale_path"
} > "$home/.config/canon/projects"

output="$(HOME="$home" "$SKILLS" uninstall)"
assert_contains "$output" "[removed]  4 Claude hook(s)"   # from project-local settings
assert_contains "$output" "[removed]  1 Claude hook(s)"   # stale global migration
assert_contains "$output" "[removed]  Codex RTK import"
assert_contains "$output" "[removed]  Pi handoff extension"
assert_contains "$output" "[removed]  install_path"
assert_contains "$output" "[removed]  projects"
assert_contains "$output" "[skip]  not found: $stale_path"
assert_contains "$output" "[cleaned]  $canon_project"

# Project-local settings: all canon hooks gone
assert_count 0 "$ROOT/scripts/auto-handoff.sh"    "$ROOT/.claude/settings.json"
assert_count 0 "$ROOT/scripts/handoff-inject.sh"  "$ROOT/.claude/settings.json"
assert_count 0 "$ROOT/scripts/sprint-inject.sh"   "$ROOT/.claude/settings.json"
assert_count 0 "$ROOT/scripts/pre-commit-check.sh" "$ROOT/.claude/settings.json"

# Global settings: canon hook gone, unrelated content preserved
assert_count 0 "$ROOT/scripts/auto-handoff.sh" "$home/.claude/settings.json"
assert_count 1 "/usr/local/bin/user-stop"       "$home/.claude/settings.json"
assert_count 1 '"theme": "dark"'                "$home/.claude/settings.json"

assert_count 0 "@$home/.codex/RTK.md" "$home/.codex/AGENTS.md"
assert_count 1 "Keep this user content." "$home/.codex/AGENTS.md"
[[ ! -f "$home/.pi/agent/extensions/handoff.ts" ]] || fail "expected Pi extension to be removed"
[[ ! -f "$home/.config/canon/install_path" ]] || fail "expected install_path to be removed"
[[ ! -f "$home/.config/canon/projects" ]] || fail "expected projects file to be removed"

# Registered project: @-imports stripped, AI-SKILLS block removed, user content preserved
assert_count 0 "@$ROOT/" "$canon_project/CLAUDE.md"
assert_count 1 "User content preserved." "$canon_project/CLAUDE.md"
assert_count 0 "@$ROOT/" "$canon_project/AGENTS.md"
assert_count 0 "AI-SKILLS:BEGIN" "$canon_project/AGENTS.md"
assert_count 0 "sprint | dev" "$canon_project/AGENTS.md"
assert_count 1 "User AGENTS content preserved." "$canon_project/AGENTS.md"

again="$(HOME="$home" "$SKILLS" uninstall)"
assert_contains "$again" "[skip]  no registered projects"
assert_contains "$again" "[ok]     no canon Claude hooks found"
assert_contains "$again" "[ok]     no canon Codex import found"
assert_contains "$again" "[skip]  Pi handoff extension not found"
assert_contains "$again" "[skip]  ~/.config/canon/install_path not found"

printf 'skills-uninstall: ok\n'
