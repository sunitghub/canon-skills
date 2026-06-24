#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  status)
    cat <<'EOF'
SKILL                 SOURCE
sprint                /Users/example/.canon/skills/sprint
context-check         /Users/example/.canon/skills/context-check
fetch-and-summarize   .claude/skills/fetch-and-summarize
be-helpful            .claude/skills/be-helpful
EOF
    ;;
  *)
    echo "fixture skills.sh supports only: status" >&2
    exit 2
    ;;
esac
