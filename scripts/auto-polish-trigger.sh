#!/usr/bin/env bash
# auto-polish-trigger.sh — Trigger /polish after a ticket is closed.
# PostToolUse[Bash] hook. Fires when `tk close` completes and polish is
# registered in the current project. Outputs an instruction Claude acts on.

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null)

# Only trigger on ticket close commands (handles rtk-rewritten form too)
echo "$CMD" | grep -qE '^(rtk )?tk close' || exit 0

# Only trigger if the command succeeded
EXIT_OK=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('tool_response', {})
    # exit_code 0 = success; if absent, assume success
    code = r.get('exit_code', r.get('exitCode', 0))
    print('yes' if str(code) == '0' else 'no')
except Exception:
    print('yes')
" 2>/dev/null)
[ "${EXIT_OK:-yes}" = "yes" ] || exit 0

# Only trigger if polish is registered in this project
POLISH_PATH=~/Developer/AI-Skills/skills/polish.md
CLAUDE_MD="$(pwd)/CLAUDE.md"
[ -f "$CLAUDE_MD" ] || exit 0
grep -qF "polish" "$CLAUDE_MD" 2>/dev/null || exit 0

echo ""
echo "[auto-polish] Ticket closed. Run /polish now — simplify, review, and security-check all"
echo "modified files before committing. Do not skip or defer this step."
