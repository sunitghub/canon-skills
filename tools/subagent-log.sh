#!/usr/bin/env bash
# Logs a subagent run to .claude/subagent-runs.jsonl for the eval audit trail
# checked by `tools/sprint complete` (see _gate_eval_report).
#
# Primary usage — explicit CLI call, made by the orchestrating agent right after
# a reviewer/evaluator subagent completes (see skills/sprint/reference/complete.md):
#   tools/subagent-log.sh --agent-id <id> [--agent-type reviewer|evaluator]
#     [--tokens N --minutes M --tool-uses K] [--ticket <id>] [--tier <tier>] [--outcome pass|fail|budget] [--model <id>]
# The cost fields (t-5ef3) come from the harness's hand-back for that run; each is written only when given,
# so a row without them keeps the old shape. `sprint gate-cost` summarizes the rows that carry them.
# --model (t-3a14) records the model the orchestrator resolved and dispatched, not one verified from the transcript;
# leave it out when the model is unknown.
#
# Legacy usage — Claude Code SubagentStop hook payload on stdin (no longer
# registered by `skills.sh add`/`init`, kept for any pre-existing install that
# hasn't been migrated yet):
#   echo '{"agent_id":"...","agent_type":"..."}' | tools/subagent-log.sh

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR points to the real file location.
_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
  _SOURCE="$(readlink "$_SOURCE")"
  [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
source "$SCRIPT_DIR/ticket-root.sh"

AGENT_ID=""
AGENT_TYPE=""
SESSION_ID=""
TRANSCRIPT=""
TOKENS=""
MINUTES=""
TOOL_USES=""
TICKET=""
TIER=""
OUTCOME=""
MODEL=""
MODEL_SET=0

usage() {
  cat >&2 <<'EOF'
Usage: subagent-log.sh --agent-id <id> [--agent-type reviewer|evaluator] [--session-id <id>] [--transcript-path <path>]
                       [--tokens N] [--minutes M] [--tool-uses K] [--ticket <id>] [--tier <tier>] [--outcome pass|fail|budget]
                       [--model <id>]
       echo '{"agent_id":"...","agent_type":"..."}' | subagent-log.sh   (legacy hook payload)
EOF
}

if [[ $# -gt 0 ]]; then
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
  fi
  # A t-5ef3 flag with no value is an error, not "not given": the hand-back totals must land or fail.
  _need() { [[ $1 -ge 2 ]] || { echo "subagent-log.sh: $2 needs a value" >&2; usage; exit 1; }; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent-id) AGENT_ID="${2:-}"; shift; shift 2>/dev/null || true ;;
      --agent-type) AGENT_TYPE="${2:-}"; shift; shift 2>/dev/null || true ;;
      --session-id) SESSION_ID="${2:-}"; shift; shift 2>/dev/null || true ;;
      --transcript-path) TRANSCRIPT="${2:-}"; shift; shift 2>/dev/null || true ;;
      --tokens) _need $# "$1"; TOKENS="$2"; shift 2 ;;
      --minutes) _need $# "$1"; MINUTES="$2"; shift 2 ;;
      --tool-uses) _need $# "$1"; TOOL_USES="$2"; shift 2 ;;
      --ticket) _need $# "$1"; TICKET="$2"; shift 2 ;;
      --tier) _need $# "$1"; TIER="$2"; shift 2 ;;
      --outcome) _need $# "$1"; OUTCOME="$2"; shift 2 ;;
      --model) _need $# "$1"; MODEL="$2"; MODEL_SET=1; shift 2 ;;
      *) echo "subagent-log.sh: unrecognized argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  if [[ -z "$AGENT_ID" ]]; then
    echo "subagent-log.sh: --agent-id is required" >&2
    usage
    exit 1
  fi
  _bad() { echo "subagent-log.sh: $1" >&2; usage; exit 1; }
  [[ -z "$TOKENS" || "$TOKENS" =~ ^[0-9]+$ ]] || _bad "--tokens must be a whole number, got '$TOKENS'"
  [[ -z "$TOOL_USES" || "$TOOL_USES" =~ ^[0-9]+$ ]] || _bad "--tool-uses must be a whole number, got '$TOOL_USES'"
  [[ -z "$MINUTES" || "$MINUTES" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] || _bad "--minutes must be a number, got '$MINUTES'"
  [[ -z "$OUTCOME" || "$OUTCOME" =~ ^(pass|fail|budget)$ ]] || _bad "--outcome must be pass, fail or budget, got '$OUTCOME'"
  [[ -z "$TICKET" || "$TICKET" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || _bad "--ticket takes a ticket id, got '$TICKET'"
  [[ -z "$TIER" || "$TIER" =~ ^[A-Za-z]+$ ]] || _bad "--tier takes one word, got '$TIER'"
  # Given means non-empty: the id goes into the JSON line, so it must not carry a quote, space or brace.
  [[ $MODEL_SET -eq 0 || ( "$MODEL" =~ ^[A-Za-z0-9._:/-]+$ && ${#MODEL} -le 80 ) ]] || _bad "--model takes a model id ([A-Za-z0-9._:/-], at most 80 chars), got '$MODEL'"
  REPO_ROOT="$(project_root)"
  # Tier is recorded now, not read later: a ticket's dir goes away on export.
  if [[ -z "$TIER" && -n "$TICKET" && -f "$REPO_ROOT/.tickets/$TICKET/plan.md" ]]; then
    TIER="$(sed 's/\*//g' "$REPO_ROOT/.tickets/$TICKET/plan.md" | sed -nE 's/^[[:space:]]*[Tt]ier[[:space:]]*:[[:space:]]*([A-Za-z]+).*/\1/p' | head -1)"
  fi
  TIER="$(printf '%s' "$TIER" | tr '[:upper:]' '[:lower:]')"   # one spelling per tier, so gate-cost groups them
else
  # Hook payload arrives on stdin as JSON
  INPUT="$(cat)"
  _json_str() { printf '%s' "$2" | { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" || true; } | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' | head -1; }
  AGENT_ID="$(_json_str agent_id "$INPUT")"
  AGENT_TYPE="$(_json_str agent_type "$INPUT")"
  TRANSCRIPT="$(_json_str transcript_path "$INPUT")"
  SESSION_ID="$(_json_str session_id "$INPUT")"
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
fi

[[ -z "$REPO_ROOT" ]] && exit 0
[[ -z "$AGENT_ID" ]] && exit 0

LOG="$REPO_ROOT/.claude/subagent-runs.jsonl"
mkdir -p "$(dirname "$LOG")"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXTRA=""
[[ -n "$TOKENS" ]] && EXTRA+=",\"tokens\":$((10#$TOKENS))"
[[ -n "$MINUTES" ]] && EXTRA+=",\"minutes\":$MINUTES"
[[ -n "$TOOL_USES" ]] && EXTRA+=",\"tool_uses\":$((10#$TOOL_USES))"
[[ -n "$TICKET" ]] && EXTRA+=",\"ticket\":\"$TICKET\""
[[ -n "$TIER" ]] && EXTRA+=",\"tier\":\"$TIER\""
[[ -n "$OUTCOME" ]] && EXTRA+=",\"outcome\":\"$OUTCOME\""
[[ -n "$MODEL" ]] && EXTRA+=",\"model\":\"$MODEL\""
printf '{"ts":"%s","session_id":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s"%s}\n' \
  "$TS" "$SESSION_ID" "$AGENT_ID" "$AGENT_TYPE" "$TRANSCRIPT" "$EXTRA" >> "$LOG"

# Prune to last 500 lines (~75KB cap)
if [[ "$(wc -l < "$LOG")" -gt 500 ]]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
