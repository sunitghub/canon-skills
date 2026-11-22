#!/usr/bin/env bash
# sprint-relay-report-copilot — t-4084: a close under Copilot CLI. Its gates have no write tool (Copilot maps canon's agent tools to read,
# search and execute), so they return the report as their final message and `sprint relay-report` copies it from Copilot's own session
# record (<COPILOT_HOME>/session-state/<sid>/events.jsonl); `sprint complete` verifies eval-report.md against the same record. Protects
# the relay (byte for byte, only from the canon gate's own task result) and the close check (a hand-written or flipped report refused),
# the fail-open Notes, the old-board refusal, Claude Code winning when both are set, and that Copilot's files are only read.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
use_fresh_board "$W/board"
export HOME="$W/home"; mkdir -p "$HOME"   # case 6b writes the default ~/.copilot: never the user's own (built board kept its real HOME)
export COPILOT_CLI=1 COPILOT_HOME="$W/copilot"
cd "$(make_project)"
mkdir -p .claude
now="$(date +%s)"
assert_gate_notice() { # <output> <file> <evaluator|reviewer>: the same notice tests/sprint.sh checks
  assert_contains "$1" "Never create or edit $2 yourself"
  assert_contains "$1" "subagent_type \"canon-$3\""
}

gate_ticket() { # a sprint with every doc valid except the report; sets gid
  gid="$("$SPRINT" start "copilot gate $1" | awk '/Sprint started:/ { print $3 }')"
  printf '# Plan\n## Sign-off\n- [x] Plan approved\n## Approach\ntest\n' > ".tickets/$gid/plan.md"
  printf '# Acceptance\n## Criteria\n- [x] item\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n' > ".tickets/$gid/acceptance.md"
  printf '# Summary\n| Item | Status |\n|---|---|\n| done | delivered |\n' > ".tickets/$gid/summary.md"
  printf '{"ts":"%s","session_id":"s1","agent_id":"x","agent_type":"evaluator","transcript_path":""}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .claude/subagent-runs.jsonl
}
# session <sid> <call-id> <agent_type> <prompt> <result> <unix-time> [success]: one gate dispatch as Copilot 1.0.114 records it
session() {
  mkdir -p "$COPILOT_HOME/session-state/$1"
  node -e '
    const [f, id, agent, prompt, result, at, ok] = process.argv.slice(1); const ts = new Date(at * 1000).toISOString();
    const lines = [
      { type: "assistant.message", timestamp: ts, data: { content: "main session text" } },
      { type: "tool.execution_start", timestamp: ts, data: { toolCallId: id, toolName: "task", arguments: { agent_type: agent, prompt, name: "gate", mode: "sync" } } },
      { type: "subagent.started", timestamp: ts, agentId: "ag-" + id, data: { toolCallId: id, agentName: agent, agentType: agent } },
      { type: "tool.execution_start", timestamp: ts, agentId: "ag-" + id, data: { toolCallId: "own-" + id, toolName: "bash", arguments: { command: "ls .tickets" } } },
      { type: "tool.execution_complete", timestamp: ts, data: { toolCallId: id, success: ok !== "false", result: { content: result } } },
    ];
    require("fs").appendFileSync(f, lines.map(l => JSON.stringify(l)).join("\n") + "\n");' \
    "$COPILOT_HOME/session-state/$1/events.jsonl" "$2" "$3" "$4" "$5" "$6" "${7:-true}"
}
evp() { printf 'You are canon'"'"'s evaluator for %s. Follow skills/sprint/reference/eval.md.' "$1"; }
body() { printf 'evaluator-run-id: %s\ngraded-head: abc\nModel: test-model\n\n## Verdict\n%s\n' "$1" "$2"; }

# 1. no Copilot session record: relay refuses and writes nothing; the close check fails open with a Note
gate_ticket none; rid="$now-1111"
out="$(run_fail "$SPRINT" relay-report "$gid")"; assert_contains "$out" "no Copilot session record under $COPILOT_HOME/session-state"   # t-2986: exit 3 apart from exit 1
[[ ! -f ".tickets/$gid/eval-report.md" ]] || fail "relay-report wrote a report with no Copilot record"
body "$rid" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
assert_contains "$("$SPRINT" complete 2>&1)" "no Copilot session record under"

# 2. a genuine canon-evaluator task: relay writes the report byte for byte (from its first line); the close verifies and passes
gate_ticket relay; rid="$now-2222"
session s1 c1 canon-evaluator "$(evp "$gid")" "I could not write the file, so here it is.

$(body "$rid" "pass: all criteria met")" "$now"
sum_before="$(find "$COPILOT_HOME" -type f -exec cksum {} + | sort)"
out="$("$SPRINT" relay-report "$gid")"; assert_contains "$out" "from Copilot's session record (canon-evaluator)"
assert_eq "$(body "$rid" "pass: all criteria met")" "$(cat ".tickets/$gid/eval-report.md")" "relayed byte for byte from the first report line"
assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

# 2b. a gate that wrote the report itself (Copilot on macOS can) and returned only a summary: no relay needed, the close checks its record
gate_ticket wroteit; rid="$now-2525"
mkdir -p "$COPILOT_HOME/session-state/s1b"
node -e '
  const [f, id, rid, gid, at] = process.argv.slice(1); const ts = new Date(at * 1000).toISOString();
  const rep = "evaluator-run-id: " + rid + "\ngraded-head: abc\nModel: test-model\n\n## Verdict\npass: all criteria met\n";
  const L = [
    { type: "tool.execution_start", timestamp: ts, data: { toolCallId: id, toolName: "task", arguments: { agent_type: "canon-evaluator", prompt: "Evaluate " + gid + ". Follow skills/sprint/reference/eval.md." } } },
    { type: "subagent.started", timestamp: ts, agentId: "ag-" + id, data: { toolCallId: id, agentType: "canon-evaluator" } },
    { type: "tool.execution_start", timestamp: ts, agentId: "ag-" + id, data: { toolCallId: "w", toolName: "bash", arguments: { command: "cat > .tickets/" + gid + "/eval-report.md <<R\n" + rep + "R" } } },
    { type: "tool.execution_complete", timestamp: ts, data: { toolCallId: id, success: true, result: { content: "pass: all met. The report is at .tickets/" + gid + "/eval-report.md." } } },
  ];
  require("fs").writeFileSync(f, L.map(l => JSON.stringify(l)).join("\n") + "\n");' "$COPILOT_HOME/session-state/s1b/events.jsonl" c1b "$rid" "$gid" "$now"
body "$rid" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

# 3. a hand-flipped report: the record says fail:, the file says pass: -> refused at close
gate_ticket flipped; rid="$now-3333"
session s2 c2 canon-evaluator "$(evp "$gid")" "$(body "$rid" "fail: criterion 2 not met")" "$now"
body "$rid" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator task result in Copilot's session record backs eval-report.md"
assert_gate_notice "$out" eval-report.md evaluator
# 3b. a report typed by hand, with no task behind its run-id at all
body "$now-3334" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator task result"
drop() { "$TKT" close "$gid" --no-sprint >/dev/null; }   # a refused close leaves the sprint active: end it before the next case
drop
# 3c. a genuine result outside the run-id's window (2 hours after it) does not back it
gate_ticket window; rid="$now-3535"
session s3 c3 canon-evaluator "$(evp "$gid")" "$(body "$rid" "pass: all criteria met")" "$((now + 7200))"
body "$rid" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator task result"
assert_contains "$out" "Reason: the newest matching canon-evaluator task finished at"; assert_contains "$out" "outside the window"   # t-2986: the failed check is named
drop

# 4. a general-purpose task never counts; truncated or failed results never count
gate_ticket fallback; rid="$now-4444"
session s4 g1 general-purpose "grade $gid" "$(body "$rid" "pass: all criteria met")" "$now"
out="$(run_fail "$SPRINT" relay-report "$gid")"; assert_contains "$out" "no evaluator result for $gid"
session s4 g2 canon-evaluator "$(evp "$gid")" "$(body "$rid" "pass: all criteria met")
Output too large to read at once. Saved to: /tmp/x" "$now"
out="$(run_fail "$SPRINT" relay-report "$gid")"; assert_contains "$out" "no evaluator result for $gid"
session s4 g3 canon-evaluator "$(evp "$gid")" "$(body "$rid" "pass: all criteria met")" "$now" false
out="$(run_fail "$SPRINT" relay-report "$gid")"; assert_contains "$out" "no evaluator result for $gid"
[[ ! -f ".tickets/$gid/eval-report.md" ]] || fail "relay-report wrote from a general-purpose, truncated or failed task"
# never a general-purpose task, even one naming the protocol: the session writes its prompt and it can write files (reviewer)
session s4 g4 general-purpose "$(evp "$gid")" "$(body "$rid" "pass: all criteria met")" "$now"
out="$(run_fail "$SPRINT" relay-report "$gid")"; assert_contains "$out" "no evaluator result for $gid"
session s4 g5 canon-evaluator "$(evp "$gid")" "$(body "$rid" "pass: all criteria met")" "$now"
assert_contains "$("$SPRINT" relay-report "$gid")" "relay-report: wrote"
assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

# 5. the reviewer's report: relayed into review-notes.md from a canon-reviewer task only
gate_ticket reviewer
session s5 r1 canon-reviewer "Review $gid. Follow skills/sprint/reference/review.md." "Done.
# Review Notes
Verdict: YES" "$now"
"$SPRINT" relay-report "$gid" reviewer >/dev/null
assert_eq "$(printf '# Review Notes\nVerdict: YES')" "$(cat ".tickets/$gid/review-notes.md")" "the reviewer's report relayed"
# 5b. t-2986, the Windows VM shape: a backslash protocol path relays (cut at the verdict); a prompt without the protocol names why
session s5 r2 canon-reviewer 'Review '"$gid"'. Follow .agents\skills\sprint\reference\review.md.' "# Review Notes

## Verdict

YES

The report file was not written." "$((now + 1))"
"$SPRINT" relay-report "$gid" reviewer >/dev/null
assert_eq "$(printf '# Review Notes\n\n## Verdict\n\nYES')" "$(cat ".tickets/$gid/review-notes.md")" "a backslash prompt relays, cut at its verdict"
drop; gate_ticket noproto   # its own ticket: r2 above still matches the first one
session s5 r3 canon-reviewer 'Review '"$gid"'. Follow .agents\skills\sprint\reference\guide.md.' "# Review Notes
Verdict: YES" "$((now + 2))"
out="$(run_fail "$SPRINT" relay-report "$gid" reviewer)"
assert_contains "$out" "the newest canon-reviewer task names $gid but not reference/review.md"
assert_contains "$out" "takes no input"
drop

# 6. an older board binary: relay refuses at once (it would take the word for a port), the close check fails open
old="$W/old/sprint-check"; mkdir -p "$W/old"
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "usage: sprint-check <port>"; exit 0; }\nsleep 30\n' > "$old"; chmod +x "$old"
gate_ticket oldboard
t0=$SECONDS; out="$(SPRINT_CHECK_BIN="$old" run_fail "$SPRINT" relay-report "$gid")"
assert_contains "$out" "predates copilot-report"; (( SECONDS - t0 < 10 )) || fail "relay-report ran an old board"
body "$now-6666" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
quick="$W/old/quick"; printf '#!/bin/sh
[ "$1" = --help ] && echo "usage: sprint-check <port>"
exit 0
' > "$quick"; chmod +x "$quick"   # answers every other word at once
assert_contains "$(SPRINT_CHECK_BIN="$quick" "$SPRINT" complete 2>&1)" "predates copilot-report"

# 6b. a COPILOT_HOME pointed at an empty folder does not skip the check when the default home (~/.copilot) has a record
gate_ticket redirect; mkdir -p "$W/empty" "$HOME/.copilot"
body "$now-6767" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
cp -R "$COPILOT_HOME/session-state" "$HOME/.copilot/"
out="$(COPILOT_HOME="$W/empty" run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator task result"
[[ "$HOME" == "$W/home" ]] && rm -rf "$W/home/.copilot/session-state"; drop

# 7. Claude Code wins when both are set: its transcript layout is checked, not Copilot's record
gate_ticket both
body "$now-7777" "pass: all criteria met" > ".tickets/$gid/eval-report.md"
assert_contains "$(CLAUDECODE=1 CLAUDE_CONFIG_DIR="$W/no-claude" "$SPRINT" complete 2>&1)" "no Claude Code subagent transcripts"

# 8. Copilot's files were only read
assert_eq "$sum_before" "$(find "$COPILOT_HOME/session-state/s1" -type f -exec cksum {} + | sort)" "Copilot's session record is never written"
echo "sprint-relay-report-copilot: ok"
