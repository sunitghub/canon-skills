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
AGENT_ID="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_id',''))" 2>/dev/null || true)"
AGENT_TYPE="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_type',''))" 2>/dev/null || true)"
TRANSCRIPT="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || true)"
SESSION_ID="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)"

[[ -z "$AGENT_ID" ]] && exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","session_id":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s"}\n' \
  "$TS" "$SESSION_ID" "$AGENT_ID" "$AGENT_TYPE" "$TRANSCRIPT" >> "$LOG"
