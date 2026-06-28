#!/usr/bin/env bash
# Logs SubagentStop events to .claude/subagent-runs.jsonl for eval audit trail.
# Registered as a SubagentStop hook in .claude/settings.json.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || echo "")"
[[ -z "$REPO_ROOT" ]] && exit 0

LOG="$REPO_ROOT/.claude/subagent-runs.jsonl"
mkdir -p "$(dirname "$LOG")"

# Hook payload arrives on stdin as JSON
INPUT="$(cat)"
_json_str() { printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' | head -1; }
AGENT_ID="$(_json_str agent_id "$INPUT")"
AGENT_TYPE="$(_json_str agent_type "$INPUT")"
TRANSCRIPT="$(_json_str transcript_path "$INPUT")"
SESSION_ID="$(_json_str session_id "$INPUT")"

[[ -z "$AGENT_ID" ]] && exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","session_id":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s"}\n' \
  "$TS" "$SESSION_ID" "$AGENT_ID" "$AGENT_TYPE" "$TRANSCRIPT" >> "$LOG"

# Prune to last 500 lines (~75KB cap)
if [[ "$(wc -l < "$LOG")" -gt 500 ]]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
