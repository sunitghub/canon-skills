#!/usr/bin/env bash
# Logs a subagent run to .claude/subagent-runs.jsonl for the eval audit trail
# checked by `tools/sprint complete` (see _gate_eval_report).
#
# Primary usage — explicit CLI call, made by the orchestrating agent right after
# a reviewer/evaluator subagent completes (see skills/sprint/reference/complete.md):
#   tools/subagent-log.sh --agent-id <id> [--agent-type reviewer|evaluator]
#
# Legacy usage — Claude Code SubagentStop hook payload on stdin (no longer
# registered by `skills.sh add`/`init`, kept for any pre-existing install that
# hasn't been migrated yet):
#   echo '{"agent_id":"...","agent_type":"..."}' | tools/subagent-log.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ticket-root.sh"

AGENT_ID=""
AGENT_TYPE=""
SESSION_ID=""
TRANSCRIPT=""

usage() {
  cat >&2 <<'EOF'
Usage: subagent-log.sh --agent-id <id> [--agent-type reviewer|evaluator] [--session-id <id>] [--transcript-path <path>]
       echo '{"agent_id":"...","agent_type":"..."}' | subagent-log.sh   (legacy hook payload)
EOF
}

if [[ $# -gt 0 ]]; then
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent-id) AGENT_ID="${2:-}"; shift; shift 2>/dev/null || true ;;
      --agent-type) AGENT_TYPE="${2:-}"; shift; shift 2>/dev/null || true ;;
      --session-id) SESSION_ID="${2:-}"; shift; shift 2>/dev/null || true ;;
      --transcript-path) TRANSCRIPT="${2:-}"; shift; shift 2>/dev/null || true ;;
      *) echo "subagent-log.sh: unrecognized argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  if [[ -z "$AGENT_ID" ]]; then
    echo "subagent-log.sh: --agent-id is required" >&2
    usage
    exit 1
  fi
  REPO_ROOT="$(project_root)"
else
  # Hook payload arrives on stdin as JSON
  INPUT="$(cat)"
  _json_str() { printf '%s' "$2" | { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" || true; } | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' | head -1; }
  AGENT_ID="$(_json_str agent_id "$INPUT")"
  AGENT_TYPE="$(_json_str agent_type "$INPUT")"
  TRANSCRIPT="$(_json_str transcript_path "$INPUT")"
  SESSION_ID="$(_json_str session_id "$INPUT")"
  REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || echo "")"
fi

[[ -z "$REPO_ROOT" ]] && exit 0
[[ -z "$AGENT_ID" ]] && exit 0

LOG="$REPO_ROOT/.claude/subagent-runs.jsonl"
mkdir -p "$(dirname "$LOG")"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","session_id":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s"}\n' \
  "$TS" "$SESSION_ID" "$AGENT_ID" "$AGENT_TYPE" "$TRANSCRIPT" >> "$LOG"

# Prune to last 500 lines (~75KB cap)
if [[ "$(wc -l < "$LOG")" -gt 500 ]]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
