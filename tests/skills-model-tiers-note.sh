#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$project" "$tmp_home"' EXIT

export HOME="$tmp_home"

printf '# Agents\n' > "$project/AGENTS.md"

# Non-interactive (test harness has no tty): prompt must be skipped, no write.
"$SKILLS" add efficiency "$project" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# Re-add stays a no-op the same way.
"$SKILLS" add efficiency "$project" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# If the note is already present (e.g. from a prior interactive Y), re-add
# must not duplicate it and must not prompt/hang.
cat "$ROOT/AGENTS.md" | awk '/<!-- MODEL-TIERS:BEGIN -->/{flag=1} flag; /<!-- MODEL-TIERS:END -->/{flag=0}' >> "$project/AGENTS.md"
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

"$SKILLS" add efficiency "$project" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

printf 'skills-model-tiers-note: ok\n'
