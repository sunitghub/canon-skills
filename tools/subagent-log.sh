#!/usr/bin/env bash
# Logs a subagent run to .claude/subagent-runs.jsonl for the eval audit trail
# checked by `tools/sprint complete` (see _gate_eval_report).
#
# Primary usage — explicit CLI call, made by the orchestrating agent right after
# a reviewer/evaluator subagent completes (see skills/sprint/reference/complete.md):
#   tools/subagent-log.sh --agent-id <id> [--agent-type <a gate role: platform-lib.sh GATE_ROLES, or break-it (a cost row, no gate event)>]
#     [--tokens N --minutes M --tool-uses K] [--ticket <id>] [--tier <tier>] [--outcome pass|fail|budget] [--model <id>]
# The cost fields (t-5ef3) come from the harness's hand-back for that run; each is written only when given,
# so a row without them keeps the old shape. `sprint gate-cost` summarizes the rows that carry them.
# A second call with the same --agent-id replaces that run's row (t-7c89): one row and one gate.finished per agent id.
# --model (t-3a14) records the model the orchestrator resolved and dispatched, not one verified from the transcript;
# leave it out when the model is unknown.

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
source "$SCRIPT_DIR/platform-lib.sh"   # canon_event (t-8854)
"$SCRIPT_DIR/work-beat" touch || true   # t-187e

AGENT_ID=""
AGENT_TYPE=""
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
Usage: subagent-log.sh --agent-id <id> [--agent-type <a gate role: platform-lib.sh GATE_ROLES, or break-it (a cost row, no gate event)>]
                       [--tokens N] [--minutes M] [--tool-uses K] [--ticket <id>] [--tier <tier>] [--outcome pass|fail|budget]
                       [--model <id>]
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
# A t-5ef3 flag with no value is an error, not "not given": the hand-back totals must land or fail.
_need() { [[ $1 -ge 2 ]] || { echo "subagent-log.sh: $2 needs a value" >&2; usage; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-id) AGENT_ID="${2:-}"; shift; shift 2>/dev/null || true ;;
    --agent-type) AGENT_TYPE="${2:-}"; shift; shift 2>/dev/null || true ;;
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
# t-0b61: a gate row logged before Claude Code's <usage> notice arrives has no tokens. Warn, never refuse.
if [[ -z "$TOKENS" && -n "${CLAUDECODE:-}" ]] && gate_role_ok "$AGENT_TYPE"; then
  echo "subagent-log.sh: no --tokens: in Claude Code the totals come in the background task's <usage> notice; wait for it, then log (never guess a number)" >&2
fi
REPO_ROOT="$(project_root)"
# Tier is recorded now, not read later: a ticket's dir goes away on export.
if [[ -z "$TIER" && -n "$TICKET" && -f "$REPO_ROOT/.tickets/$TICKET/plan.md" ]]; then
  TIER="$(sed 's/\*//g' "$REPO_ROOT/.tickets/$TICKET/plan.md" | sed -nE 's/^[[:space:]]*[Tt]ier[[:space:]]*:[[:space:]]*([A-Za-z]+).*/\1/p' | head -1)"
fi
TIER="$(printf '%s' "$TIER" | tr '[:upper:]' '[:lower:]')"   # one spelling per tier, so gate-cost groups them

[[ -z "$REPO_ROOT" ]] && exit 0
[[ -z "$AGENT_ID" ]] && exit 0

LOG="$REPO_ROOT/.claude/subagent-runs.jsonl"
wt_write_ok "$LOG" "${LOG}.tmp" || exit 1   # t-f7e6: a planted .claude or log link in a worktree
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
# t-7c89: one row per agent id. A second call for the same run (the totals arrive after the first log) replaces its row, so the later
# numbers win; the run's gate.finished is then already written (below) and is not written again.
SEEN=0
if [[ -f "$LOG" ]] && grep -qF -e "\"agent_id\":\"$AGENT_ID\"" "$LOG"; then
  SEEN=1
  { grep -vF -e "\"agent_id\":\"$AGENT_ID\"" "$LOG" || true; } > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
printf '{"ts":"%s","agent_id":"%s","agent_type":"%s"%s}\n' "$TS" "$AGENT_ID" "$AGENT_TYPE" "$EXTRA" >> "$LOG"

# Prune to last 500 lines (~75KB cap)
if [[ "$(wc -l < "$LOG")" -gt 500 ]]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

# t-8854: a close gate's run is also a gate.finished event, with the verdict its own report states (unknown if none yet).
# t-9b13: so is the spec check's at sprint start (spec-review.md, READY or GAPS). Observer-only: canon_event never fails and never prints.
if [[ $SEEN -eq 0 && -n "$TICKET" ]] && gate_role_ok "$AGENT_TYPE"; then
  _tdir="$REPO_ROOT/.tickets/$TICKET" _verdict=unknown _rep="$REPO_ROOT/.tickets/$TICKET/$(gate_report "$AGENT_TYPE")"
  [[ -f "$_rep" ]] && _verdict="$(gate_verdict "$AGENT_TYPE" "$_rep")"
  [[ "$_verdict" =~ ^(YES|NO|pass|fail|partial|not-run|READY|GAPS)$ ]] || _verdict=unknown
  # t-ff14: which agent really ran the evaluator (canon-evaluator, or a general-purpose/Plan fallback), from the harness's own
  # transcript holding its run-id (the agent id here), never from what the caller says. Absent when none is found.
  # t-9113: how many Act On items the reviewer raised (an `Act On: none` line is 0; the rule of tools/sprint's review check), so the log can say
  # whether the reviewer changed the outcome. Absent when the report has no Act On line (an evaluator run, or no report).
  _act=""
  if [[ "$AGENT_TYPE" == reviewer && -f "$_tdir/review-notes.md" ]]; then
    _acts="$(grep -E "^[[:space:]]*[-*]?[[:space:]]*Act On:[[:space:]]*[^[:space:]]" "$_tdir/review-notes.md" | sed -E 's/^[[:space:]]*[-*]?[[:space:]]*Act On:[[:space:]]*//; s/\r$//' | tr '[:upper:]' '[:lower:]')" || _acts=""
    [[ -z "$_acts" ]] || _act="$(grep -cvE '^none([^[:alnum:]_]|$)' <<< "$_acts" || true)"
  fi
  _agent=""
  if [[ ( "$AGENT_TYPE" == evaluator || "$AGENT_TYPE" == evaluator2 ) && -n "${CLAUDECODE:-}" ]]; then
    _cfg="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
    _tx="$(find "$_cfg/projects/" -path '*/subagents/agent-*.jsonl' -type f -mmin -180 -exec grep -lF -e "evaluator-run-id: $AGENT_ID" {} + 2>/dev/null | head -1 || true)"   # grep exits 1 on non-matching files
    [[ -n "$_tx" && -f "${_tx%.jsonl}.meta.json" ]] && _agent="$(sed -nE 's/.*"agentType"[[:space:]]*:[[:space:]]*"([A-Za-z0-9-]{1,32})".*/\1/p' "${_tx%.jsonl}.meta.json" | head -1)"
  fi
  canon_event gate.finished subagent-log "$REPO_ROOT" "ticket=$TICKET" "role=$AGENT_TYPE" "verdict=$_verdict" \
    "model=$MODEL" "tokens=$TOKENS" "minutes=$MINUTES" ${_agent:+"agent=$_agent"} ${_act:+"act_on=$_act"}
fi
