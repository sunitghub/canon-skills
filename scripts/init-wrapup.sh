#!/usr/bin/env bash
set -euo pipefail
# init-wrapup.sh — Convenience wrapper for registering the wrapup pipeline.
# Dependencies are declared in wrapup.md frontmatter and resolved automatically
# by skills.sh. To add new pipeline skills, update the `depends` field there.
#
# Usage:
#   init-wrapup.sh                    # registers in current directory
#   init-wrapup.sh /path/to/project   # registers in specified project

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"

"$SKILLS_ROOT/skills.sh" add wrapup "${1:-$(pwd)}"
