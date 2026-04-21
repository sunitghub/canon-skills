#!/usr/bin/env bash
# init-polish.sh — Convenience wrapper for registering the polish pipeline.
# Dependencies are declared in polish.md frontmatter and resolved automatically
# by skills.sh. To add new pipeline skills, update the `depends` field there.
#
# Usage:
#   init-polish.sh                    # registers in current directory
#   init-polish.sh /path/to/project   # registers in specified project

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"

"$SKILLS_ROOT/skills.sh" add polish "${1:-$(pwd)}"
