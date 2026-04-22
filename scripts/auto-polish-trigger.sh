#!/usr/bin/env bash
# auto-polish-trigger.sh — Trigger /wrapup after a ticket is closed.
# PostToolUse[Bash] hook. Fires when `tk close` completes and wrapup is
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

# Only trigger if wrapup is registered in this project
CLAUDE_MD="$(pwd)/CLAUDE.md"
[ -f "$CLAUDE_MD" ] || exit 0
grep -qF "wrapup" "$CLAUDE_MD" 2>/dev/null || exit 0

echo ""
echo "[auto-wrapup] Ticket closed. Run /wrapup now — simplify, review, and security-check all"
echo "modified files before committing. Do not skip or defer this step."
