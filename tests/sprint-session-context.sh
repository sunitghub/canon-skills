#!/usr/bin/env bash
# t-ec24: `sprint start` and `sprint pre-gate-check` (the close's first command) print the session's context size and the
# cheaper path (/clear, then sprint continue) when this Claude Code session's transcript already holds over 150000 tokens;
# `sprint continue` points at the close checklist. Prod paths: sprint start, sprint pre-gate-check, sprint continue (the
# Cockpit's resume prompt). A fixture Claude config holds this session's transcript.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # sprint.started goes through the board binary

W="$(cd "$(mktemp -d)" && pwd -P)"
CFG="$W/cfg"; SID="11111111-2222-3333-4444-555555555555"
export CLAUDECODE=1 CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$CFG"
newp() { P="$(make_project)"; P="$(cd "$P" && pwd -P)"; }   # one active sprint per project, so a project per case
usage() { # <input> <cache read> <cache write>: one assistant record (Claude Code's shape, nested cache_creation included)
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s}}}}\n' "$1" "$3" "$2" "$3"
}
session() { # <records...>: this session's transcript; a big tool result's subagent usage on a user line must not count
  rm -rf "$CFG/projects"; mkdir -p "$CFG/projects/-p"
  { printf '{"type":"mode","sessionId":"%s"}\n' "$SID"; printf '%s\n' "$@"
    printf '{"type":"user","toolUseResult":{"usage":{"input_tokens":900000}}}\n'; } > "$CFG/projects/-p/$SID.jsonl"
}
start() { (cd "$P" && "$ROOT/tools/sprint" start "session context $1" 2>&1); }
LINE="[sprint] Session context:"

# 1. over the threshold: the last assistant record counts (an earlier, larger one does not); 449500 rounds to 450k
newp; session "$(usage 2 900000 1000)" "$(usage 2 400000 49498)"
out="$(start over)"
assert_contains "$out" "$LINE 450k tokens; every step re-reads it."
id="$(awk '/Sprint started:/ { print $3 }' <<< "$out")"
assert_contains "$out" "  Cheaper: run /clear, then sprint continue $id."
# 2. exactly 150000, and under: nothing
newp; session "$(usage 0 149000 1000)"; out="$(start at)"; [[ "$out" != *"$LINE"* ]] || fail "printed at 150000: $out"
newp; session "$(usage 2 60000 1500)"; out="$(start under)"; [[ "$out" != *"$LINE"* ]] || fail "printed under: $out"
# 150001 prints (the compare is strict, not off by a thousand)
newp; session "$(usage 1 149000 1000)"; out="$(start justover)"; assert_contains "$out" "$LINE 150k tokens"
# a record missing a field (no cache write) still counts, and sprint start does not die on the absent field under set -e
newp; session '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":200000}}}'
out="$(start nofield)"; assert_contains "$out" "$LINE 200k tokens"; assert_contains "$out" "Sprint started:"
# 3. silent with no usage record, no transcript, or outside Claude Code
newp; session; out="$(start nousage)"; [[ "$out" != *"$LINE"* ]] || fail "printed with no assistant usage: $out"
session "$(usage 2 400000 50000)"
newp; out="$(CLAUDE_CODE_SESSION_ID=nope start notranscript)"; [[ "$out" != *"$LINE"* ]] || fail "printed with no transcript: $out"
newp; out="$(CLAUDECODE='' start notcc)"; [[ "$out" != *"$LINE"* ]] || fail "printed outside Claude Code: $out"

# 4. sprint continue points at the close checklist
newp; out="$(start cont)"; id="$(awk '/Sprint started:/ { print $3 }' <<< "$out")"
out="$(cd "$P" && "$ROOT/tools/sprint" continue "$id" 2>&1)"
assert_contains "$out" "skills/sprint/reference/complete-checklist.md"

# 5. pre-gate-check: the line and the close advice, the same exit code as outside Claude Code, and none of it in the stamped log
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
pg() { local rc=0; (cd "$P" && PRE_GATE_BASE=HEAD "$ROOT/tools/sprint" pre-gate-check "$id" 2>&1) || rc=$?; echo "rc=$rc"; }
out="$(pg)"
assert_contains "$out" "$LINE 450k tokens; every step re-reads it."
assert_contains "$out" "  Cheaper: run /clear, then sprint continue $id, then sprint complete."
rc_in="$(tail -1 <<< "$out")"; out2="$(CLAUDECODE='' pg)"
[[ "$out2" != *"$LINE"* ]] || fail "pre-gate printed outside Claude Code: $out2"
[[ "$rc_in" == "$(tail -1 <<< "$out2")" ]] || fail "pre-gate exit changed by the line: $rc_in vs $(tail -1 <<< "$out2")"
log="$P/.tickets/$id/evidence/pre-gate.log"; [[ -f "$log" ]] || fail "no stamped pre-gate log: $out"
! grep -qF "Session context" "$log" || fail "the context line reached the stamped log: $log"

rm -rf "$W"
echo "sprint-session-context: ok (start and pre-gate-check print the size and the cheaper path over 150000 from the last assistant usage record; nothing at or under it, without a usage record or transcript, or outside Claude Code; pre-gate's exit and stamped log unchanged; continue names the close checklist)"
