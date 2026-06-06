#!/usr/bin/env bash
set -euo pipefail
# sprint-inject.sh — Inject active sprint docs into Claude's context at session start.
# Called by the Claude Code UserPromptSubmit hook. Fires once per 4-hour window
# per project when a sprint is active. No-op when no sprint is running.
# Warns if plan.md exceeds 80 lines so the user knows to keep it tight.

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TKT="${CANON_HOME:-$SCRIPT_DIR/..}/tools/tkt"
[ -x "$TKT" ] || exit 0

PROJ_SLUG=$(basename "$GIT_ROOT" | tr -cd '[:alnum:]-')
SESSION_FILE="/tmp/sprint_inject_session_${PROJ_SLUG}"
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

[ "$should_inject" = "1" ] || exit 0

# Resolve active sprint — exit silently if no sprint, warn on conflict
set +e; CURRENT=$("$TKT" current 2>/dev/null); TKT_RC=$?; set -e
if [[ "$TKT_RC" -gt 1 ]]; then
  echo "[sprint] Warning: multiple in-progress tickets — run 'tkt start <id>' to set ACTIVE" >&2
  exit 0
fi
[[ "$TKT_RC" -eq 0 ]] || exit 0
TICKET_ID=$(echo "$CURRENT" | awk '{print $1}')
[ -n "$TICKET_ID" ] || exit 0

TDIR="$GIT_ROOT/.tickets/$TICKET_ID"
PLAN_FILE="$TDIR/plan.md"
ACCEPTANCE_FILE="$TDIR/acceptance.md"

[ -f "$PLAN_FILE" ] || exit 0

touch "$SESSION_FILE"  # mark throttle window as started

TITLE=$(echo "$CURRENT" | awk '{for(i=3;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":"\n")}')
echo "[sprint] Active sprint: $TICKET_ID — $TITLE"
echo "---"

LINE_COUNT=$(wc -l < "$PLAN_FILE")
if [ "$LINE_COUNT" -gt "$MAX_LINES" ]; then
  echo "[sprint] Warning: plan.md is ${LINE_COUNT} lines (limit: ${MAX_LINES}). Consider pruning to keep session-start injection lean."
fi

HAS_RTK=0; command -v rtk &>/dev/null && HAS_RTK=1

if [[ "$HAS_RTK" -eq 1 ]]; then rtk read "$PLAN_FILE"; else cat "$PLAN_FILE"; fi

if [ -f "$ACCEPTANCE_FILE" ]; then
  echo ""
  if [[ "$HAS_RTK" -eq 1 ]]; then rtk read "$ACCEPTANCE_FILE"; else cat "$ACCEPTANCE_FILE"; fi
fi

echo "---"
