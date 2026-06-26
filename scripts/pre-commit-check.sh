#!/usr/bin/env bash
# pre-commit-check.sh — Before git commit: run the test suite (any repo that
# provides scripts/test.sh), remind Claude to close in-progress tickets, and
# confirm wrapup has been run. PreToolUse[Bash] hook. Blocks on test failure.

CANON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TKT_BIN="$CANON_ROOT/tools/tkt"
[ -f "$TKT_BIN" ] || TKT_BIN=$(command -v tkt 2>/dev/null || command -v tk 2>/dev/null || true)

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null)

# Only fire on git commit commands
echo "$CMD" | grep -qE '(^| )git commit' || exit 0

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# ── Direct ticket status edit detection ─────────────────────────────────────
# Block commits that flip a ticket directly to closed — that bypasses sprint complete.
DIRECT_CLOSE=""
DIRECT_OPEN=""
while IFS= read -r ticket_file; do
  ticket_diff=$(git diff --cached -- "$ticket_file" 2>/dev/null)
  echo "$ticket_diff" | grep -q "^+status: closed"      && DIRECT_CLOSE=1
  echo "$ticket_diff" | grep -q "^+status: in_progress" && DIRECT_OPEN=1
done < <(git diff --cached --name-only 2>/dev/null | grep "^\.tickets/")

if [ -n "$DIRECT_CLOSE" ]; then
  echo ""
  echo "[pre-commit] BLOCKED — ticket closed by direct file edit."
  echo "  Use 'sprint complete' instead of editing status: closed manually."
  exit 1
fi
if [ -n "$DIRECT_OPEN" ]; then
  echo ""
  echo "[pre-commit] WARNING — ticket set to in_progress by direct file edit."
  echo "  Prefer 'sprint start' to open a sprint properly."
fi

# ── Active tickets (open + in_progress) ─────────────────────────────────────
TICKETS=""
if [ -n "$TKT_BIN" ]; then
  TICKETS=$(
    { "$TKT_BIN" ls --status=in_progress 2>/dev/null || true;
      "$TKT_BIN" ls --status=open        2>/dev/null || true; } \
    | grep -v "^No tickets" | head -5
  )
fi

# ── High-risk Sign-off gate ──────────────────────────────────────────────────
# Block commits when the active sprint is high-risk and Sign-off is unchecked.
_signoff_section() {
  awk '/^## Sign-off[[:space:]]*$/{f=1;next} /^## /{f=0} f' "$1"
}
ACTIVE_ID=$(cat "$GIT_ROOT/.tickets/ACTIVE" 2>/dev/null | tr -d '[:space:]')
if [ -n "$ACTIVE_ID" ]; then
  ACTIVE_PLAN="$GIT_ROOT/.tickets/$ACTIVE_ID/plan.md"
  if [ -f "$ACTIVE_PLAN" ] && grep -qiE 'tier[[:space:]]*:?[[:space:]]*\*{0,2}high-risk' "$ACTIVE_PLAN"; then
    if _signoff_section "$ACTIVE_PLAN" | grep -qE '^[[:space:]]*[-*] \[ \]'; then
      echo ""
      echo "[pre-commit] BLOCKED — high-risk sprint $ACTIVE_ID has unchecked Sign-off."
      echo "  Check the approval box in .tickets/$ACTIVE_ID/plan.md ## Sign-off before committing."
      exit 1
    fi
  fi
fi

# ── Test suite ───────────────────────────────────────────────────────────────
TEST_RUNNER="$GIT_ROOT/scripts/test.sh"
if [[ -x "$TEST_RUNNER" ]]; then
  echo "[pre-commit] Running test suite..."
  if ! test_output="$(bash "$TEST_RUNNER" 2>&1)"; then
    echo "[pre-commit] BLOCKED — test suite failed:"
    echo "$test_output"
    exit 1
  fi
  echo "[pre-commit] Tests passed."
fi

# ── Wrapup and ticket reminders ──────────────────────────────────────────────
CLAUDE_MD="$GIT_ROOT/CLAUDE.md"
WRAPUP_REGISTERED=0
if [ -f "$CLAUDE_MD" ] && grep -qF "wrapup" "$CLAUDE_MD" 2>/dev/null; then
  WRAPUP_REGISTERED=1
fi

[ -n "$TICKETS" ] || [ "$WRAPUP_REGISTERED" = "1" ] || exit 0

echo ""
echo "[pre-commit] Before committing, verify:"
N=0
if [ -n "$TICKETS" ]; then
  N=$(( N + 1 ))
  echo "  $N. Open/in-progress tickets — should any be closed first?"
  echo "$TICKETS" | sed 's/^/     /'
fi
if [ "$WRAPUP_REGISTERED" = "1" ]; then
  N=$(( N + 1 ))
  echo "  $N. Run /wrapup if not already done for these changes."
fi

# Block when wrapup is registered AND tickets are still open
if [ "$WRAPUP_REGISTERED" = "1" ] && [ -n "$TICKETS" ]; then
  echo ""
  echo "[pre-commit] BLOCKED — open tickets exist and wrapup is registered."
  echo "  Run /wrapup, then 'sprint complete' to close the ticket before committing."
  exit 1
fi

exit 0
