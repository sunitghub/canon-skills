#!/usr/bin/env bash
# pre-commit-check.sh — Before git commit, remind Claude to close any
# in-progress tickets and confirm wrapup has been run.
# PreToolUse[Bash] hook. Outputs context Claude acts on; never blocks.

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null)

# Only fire on git commit commands (handles rtk-rewritten form too)
echo "$CMD" | grep -qE '(^| )(git|rtk git) commit' || exit 0

TICKETS=""
if command -v tk &>/dev/null; then
  TICKETS=$(tk ls --status=in_progress 2>/dev/null | head -5 || true)
fi

CLAUDE_MD="$(pwd)/CLAUDE.md"
WRAPUP_REGISTERED=0
if [ -f "$CLAUDE_MD" ] && grep -qF "wrapup" "$CLAUDE_MD" 2>/dev/null; then
  WRAPUP_REGISTERED=1
fi

# Only output if there's something to check
[ -n "$TICKETS" ] || [ "$WRAPUP_REGISTERED" = "1" ] || exit 0

echo ""
echo "[pre-commit] Before committing, verify:"
if [ -n "$TICKETS" ]; then
  echo "  1. In-progress tickets — should any be closed for this commit?"
  echo "$TICKETS" | sed 's/^/     /'
fi
if [ "$WRAPUP_REGISTERED" = "1" ]; then
  [ -n "$TICKETS" ] && N=2 || N=1
  echo "  $N. Run /wrapup if not already done for these changes."
fi

exit 0
