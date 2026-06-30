#!/usr/bin/env bash
set -euo pipefail
# handoff-inject.sh — Inject HANDOFF.md into Claude's context at session start.
# Called by the Claude Code UserPromptSubmit hook. Fires once per 4-hour window
# per project — not on every prompt — to keep token overhead minimal.
# Warns if HANDOFF.md exceeds 80 lines so the user knows to prune.

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
GIT_ROOT="${GIT_ROOT:-$(pwd)}"
HANDOFF_FILE="$GIT_ROOT/HANDOFF.md"
[ -f "$HANDOFF_FILE" ] || exit 0

PROJ_SLUG=$(basename "$GIT_ROOT" | tr -cd '[:alnum:]-')
SESSION_FILE="/tmp/handoff_session_${PROJ_SLUG}"
STALE_SECONDS=$((60 * 60 * 4))
MAX_LINES=80

should_inject=0

if [ ! -f "$SESSION_FILE" ]; then
  should_inject=1
else
  if stat -f %m "$SESSION_FILE" &>/dev/null; then
    MTIME=$(stat -f %m "$SESSION_FILE")
  else
    MTIME=$(stat -c %Y "$SESSION_FILE")
  fi
  NOW=$(date +%s)
  if [ $(( NOW - MTIME )) -gt $STALE_SECONDS ]; then
    should_inject=1
  fi
fi

if [ "$should_inject" = "1" ]; then
  touch "$SESSION_FILE"

  LINE_COUNT=$(wc -l < "$HANDOFF_FILE")
  if [ "$LINE_COUNT" -gt "$MAX_LINES" ]; then
    echo "[handoff] Warning: HANDOFF.md is ${LINE_COUNT} lines (limit: ${MAX_LINES}). Consider pruning stale entries."
  fi

  echo "[handoff] Resuming — context from last session:"
  echo "---"
  cat "$HANDOFF_FILE"
  echo "---"
  echo "[handoff] Read the above before doing anything else."
fi
