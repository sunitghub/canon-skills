#!/usr/bin/env bash
# t-ff14: `sprint start` / `sprint continue` warn when canon's gate agents are not loaded in this Claude Code session, and
# sprint.started carries gate_agents. Prod path: sprint start, the first thing a new user runs before their first close.
# A fixture Claude config holds this session's transcript, whose first "cwd" and "timestamp" are the start folder and time.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # sprint.started goes through the board binary

W="$(cd "$(mktemp -d)" && pwd -P)"
CFG="$W/cfg"; SID="11111111-2222-3333-4444-555555555555"
newp() { P="$(make_project)"; P="$(cd "$P" && pwd -P)"; }   # one active sprint per project, so a project per case
OTHER="$W/other"; mkdir -p "$OTHER"
export CLAUDECODE=1 CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$CFG"
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
at() { touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)" "$1"; }
session() { # <start folder> <start epoch>: this session's transcript, filed (as Claude Code does) under its CURRENT folder's slug
  rm -rf "$CFG/projects"; mkdir -p "$CFG/projects/-current-folder"
  printf '{"type":"mode","sessionId":"%s"}\n{"cwd":"%s","timestamp":"%s","type":"user"}\n{"cwd":"%s","timestamp":"%s"}\n' \
    "$SID" "$1" "$(iso "$2")" "$P" "$(iso "$(( $2 + 60 ))")" > "$CFG/projects/-current-folder/$SID.jsonl"
}
agents() { # <folder> <epoch>: canon's gate agents linked there at that time
  mkdir -p "$1/.claude/agents"; printf -- '<!-- canon:agent -->\n' > "$1/.claude/agents/canon-evaluator.md"
  at "$1/.claude/agents/canon-evaluator.md" "$2"; at "$1/.claude/agents" "$2"
}
start() { (cd "$P" && "$ROOT/tools/sprint" start "gate agents $1" 2>&1); }
last_started() { cat "$CANON_HOME"/events/*.jsonl 2>/dev/null | grep -F '"kind":"sprint.started"' | tail -1 || true; }
now="$(date +%s)"

# 1. started in the project, agents linked a day before: no warning, gate_agents=ok
newp; agents "$P" $(( now - 86400 )); session "$P" $(( now - 3600 ))
out="$(start ok)"; [[ "$out" != *"WARNING: canon's gate agents"* ]] || fail "warned with the agents loaded: $out"
assert_contains "$(last_started)" '"gate_agents":"ok"'
# 2. started in another folder with no agents (the transcript's own folder is the project's: that must not count)
newp; agents "$P" $(( now - 86400 )); session "$OTHER" $(( now - 3600 ))
out="$(start elsewhere)"
assert_contains "$out" "WARNING: canon's gate agents are not loaded in this Claude Code session: it started in $OTHER"
assert_contains "$out" "start Claude Code again in $P."   # the project, not the outside start folder (t-21f7); no refresh hint: $P has the agents
assert_contains "$(last_started)" '"gate_agents":"missing"'
# 3. ...but the user's own agents folder counts
newp; mkdir -p "$CFG/agents"; printf -- '<!-- canon:agent -->\n' > "$CFG/agents/canon-evaluator.md"; at "$CFG/agents" $(( now - 86400 ))
session "$OTHER" $(( now - 3600 ))
out="$(start useragents)"; [[ "$out" != *"WARNING: canon's gate agents"* ]] || fail "warned with canon-evaluator in the user's agents: $out"
rm -rf "$CFG/agents"
# 4. agents linked after the session started (skills.sh add inside a running session)
newp; agents "$P" "$now"; session "$P" $(( now - 3600 ))
out="$(start late)"; assert_contains "$out" "canon's gate agents were added after it started"
[[ "$out" != *"skills.sh refresh"* ]] || fail "refresh hint shown though the start folder has the agents: $out"
# 5. started outside, the project has no agents at all: the fix names the project and says to refresh first
newp; session "$OTHER" $(( now - 3600 ))
out="$(start noagents)"; assert_contains "$out" "start Claude Code again in $P (run 'skills.sh refresh' there first"
# 5b. started in a worktree with no agents: the fix line names that worktree, not the project
newp; git -C "$P" commit -q --allow-empty -m init; WT="$W/wt"; git -C "$P" worktree add -q "$WT"
agents "$P" $(( now - 86400 )); session "$WT" $(( now - 3600 ))
out="$(start worktree)"; assert_contains "$out" "start Claude Code again in $WT (run"
# 5c. a transcript with no "cwd" line: silent, no gate_agents field
newp; rm -rf "$CFG/projects"; mkdir -p "$CFG/projects/-x"
printf '{"type":"mode","sessionId":"%s"}\n{"timestamp":"%s","type":"user"}\n' "$SID" "$(iso "$now")" > "$CFG/projects/-x/$SID.jsonl"
out="$(start nocwd)"; [[ "$out" != *"WARNING: canon's gate agents"* ]] || fail "warned with no cwd line: $out"
[[ "$(last_started)" != *gate_agents* ]] || fail "gate_agents written with no cwd line"
session "$P" $(( now - 3600 ))
# 6. sprint continue warns the same way
id="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
out="$(cd "$P" && "$ROOT/tools/sprint" continue "$id" 2>&1)"; assert_contains "$out" "WARNING: canon's gate agents"
# 7. silent, and no gate_agents field, outside Claude Code or when the transcript is not found
newp; out="$(CLAUDECODE= start notcc)"; [[ "$out" != *"WARNING: canon's gate agents"* ]] || fail "warned outside Claude Code: $out"
[[ "$(last_started)" != *gate_agents* ]] || fail "gate_agents written outside Claude Code"
newp; out="$(CLAUDE_CODE_SESSION_ID=nope start notranscript)"; [[ "$out" != *"WARNING: canon's gate agents"* ]] || fail "warned with no transcript: $out"

rm -rf "$W"
echo "sprint-gate-agents: ok (no warning with agents in the start folder or the user's; warns when started elsewhere, when agents came after the start, and with no agents (refresh hint); sprint continue too; gate_agents ok/missing; silent outside Claude Code or without a transcript)"
