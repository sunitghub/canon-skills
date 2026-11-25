#!/usr/bin/env bash
# sprint-gate-prompt — t-63c6: canon prints each gate's whole dispatch prompt, so a session never assembles one by hand. On the Windows
# Copilot run (ToDo-Demo t-pnu4) a session-written prompt lost a different protocol input each time (the report heading, the verdict
# line, the Model line) and each loss cost a full gate run. Protects `sprint gate-prompt` (every gate dispatch: protocol path per
# harness, the Model line, the report rule, the evaluator's evidence and Manual mode, the second evaluator's report path), the line
# `gate-snapshot.sh pre` prints naming it, `sprint run-id` (eval.md's run-id on every harness) and `sprint --help`.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # Admin's pick comes from the board binary's stage-model (sprint gate-model)

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
export CANON_GATE_SCOPE_DIR="$W/registry" CANON_HOME="$W/canon-home"
project="$(make_project)"; project="$(cd "$project" && pwd -P)"
cleanup() {
  local f d
  for f in "$CANON_GATE_SCOPE_DIR"/*; do
    [[ -f "$f" ]] || continue
    d="$(sed -n 's/^dir=//p' "$f")"; [[ "$d" == /*/* ]] && rm -rf "$d"
  done
  rm -rf "$W" "$project"
}
trap cleanup EXIT
unset COCKPIT_AGENT COPILOT_CLI CLAUDECODE CANON_TICKETS_DIR
cd "$project"
git commit -q --allow-empty -m init
id="$("$SPRINT" start "Gate prompts" | awk '/Sprint started:/ { print $3 }')"
t=".tickets/$id"
signoff() { printf '# Plan\n\n## Sign-off\n%s\n\n- [x] Plan approved\n\n## Approach\nx\n' "$1" > "$t/plan.md"; }
reg() { mkdir -p "$CANON_HOME/cockpit"; printf '%s' "$1" > "$CANON_HOME/cockpit/model-tiers.json"; }
gp() { set +e; out="$("$SPRINT" gate-prompt "$id" "$1" 2>"$W/err")"; code=$?; err="$(cat "$W/err")"; set -e; }
absent() { [[ "$1" != *"$2"* ]] || fail "gate-prompt: '$2' must not appear in: $1"; }
MODELS='"models":{"anthropic":[{"id":"claude-sonnet-5-5","alias":"sonnet"},{"id":"claude-opus-5-5","alias":"opus"},{"id":"claude-haiku-5-5","alias":"haiku"}]}'
signoff "Tier: normal | Risk: x"

# 1. A consumer project under Claude Code: .claude/skills, the absolute report path, the agent file's floor when Admin has no pick
gp reviewer
assert_eq 0 "$code"
assert_contains "$out" "You are canon's advisory reviewer for ticket $id (Gate prompts). Repo: $project, branch "
assert_contains "$out" "Follow .claude/skills/sprint/reference/review.md for this ticket."
assert_contains "$out" "
Model: claude-sonnet-5 (definition floor)"
assert_contains "$out" "Write your report to $project/$t/review-notes.md and return its verdict line."
assert_contains "$out" "Never kill a process by name or pattern."
assert_contains "$out" "HOME, CANON_HOME, TMPDIR and XDG_CONFIG_HOME pinned"
assert_contains "$err" "gate-prompt: dispatch canon-reviewer with no model (its definition floor)"
assert_contains "$err" "gate-prompt: if the gate returns its report instead of writing it (the Plan fallback): sprint relay-report $id reviewer"
absent "$out" "Under Copilot CLI"

# 2. Admin's pick is the Model line and the model to pass; under Copilot: .agents/skills, the whole-report rule, the relay and `name`
reg '{"defaults":{"reviewer":{"claude":"claude-opus-5-5","copilot":"claude-sonnet-5.5"},"evaluator":{"claude":"claude-sonnet-5-5","copilot":"claude-sonnet-5.5"},"speccheck":{"claude":"claude-sonnet-5-5","copilot":"claude-haiku-5.5"},"evaluator2":{"claude":"claude-opus-5-5","copilot":"gpt-6-luna"}},'"$MODELS"'}'
gp reviewer
assert_contains "$out" "
Model: opus (Admin Reviewer default, claude)"
assert_contains "$err" "gate-prompt: dispatch canon-reviewer with model: opus"
COPILOT_CLI=1 gp speccheck
assert_contains "$out" "You are canon's spec checker for ticket $id"
assert_contains "$out" "Follow .agents/skills/sprint/reference/spec-check.md for this ticket."
assert_contains "$out" "
Model: claude-haiku-5.5 (Admin Spec check default, copilot)"
assert_contains "$out" "Under Copilot CLI write no file: your final message is the whole report, from its first line (\`# Spec check: $id\`) to the end, nothing after it."
absent "$out" "Write your report to"
absent "$out" "except that report"   # t-63c6 evaluator: "except that report" beside "write no file" is the contradiction the VM reviewer acted on
assert_contains "$out" "You are read-only: write no file at all."
assert_contains "$err" "Copilot's task call needs name; when the gate returns: sprint relay-report $id speccheck"
COPILOT_CLI=1 gp reviewer
assert_contains "$out" "from its first line (\`# Review Notes\`) to the end, nothing after it."

# 3. canon's own checkout: the protocol at skills/ (whatever the harness)
mkdir -p skills/sprint/reference && : > skills/sprint/reference/eval.md
COPILOT_CLI=1 gp evaluator
assert_contains "$out" "Follow skills/sprint/reference/eval.md for this ticket."
rm -rf skills

# 4. A ticket rule is resolved here, never dropped: the Sign-off's Gate model (Copilot's id under Copilot), the Lite evaluator's Haiku
signoff "Tier: normal | Risk: x | Gate model: haiku"
gp reviewer; assert_contains "$out" "
Model: haiku (Gate model override)"; assert_contains "$err" "with model: haiku"
COPILOT_CLI=1 gp evaluator; assert_contains "$out" "
Model: claude-haiku-4.5 (Gate model override)"
# Gate model: session -> the gate names its own model (only it knows it); openai:<id> -> as is under Copilot, else Admin's pick, loudly
signoff "Tier: normal | Risk: x | Gate model: session"
gp reviewer
assert_contains "$out" "Put this Model line in your report, with your own model id in place of <your model id>:
Model: <your model id> (Gate model override — session)"
assert_contains "$err" "dispatch canon-reviewer with your own session's model (Gate model: session)"
signoff "Tier: normal | Risk: x | Gate model: openai:gpt-6-luna"
COPILOT_CLI=1 gp reviewer; assert_contains "$out" "
Model: gpt-6-luna (Gate model override, OpenAI)"; assert_contains "$err" "with model: gpt-6-luna"
gp reviewer; assert_contains "$out" "
Model: opus (fallback: openai:gpt-6-luna needs Copilot CLI)"; assert_contains "$err" "with model: opus"
signoff "Tier: normal | Risk: x"
"$TKT" demo "$id" on >/dev/null
gp evaluator; assert_contains "$out" "
Model: haiku (Lite evaluator)"
"$TKT" demo "$id" off >/dev/null

# 4b. t-3e06: the Close pick is the session's model, never a gate's: with Admin's Close on a model no gate step picks (and a ticket Close
# model line), the reviewer, evaluator and spec check prompts name their own steps' models, and a Lite evaluator stays Haiku.
cp "$CANON_HOME/cockpit/model-tiers.json" "$W/tiers.saved"
reg '{"defaults":{"reviewer":{"claude":"claude-sonnet-5-5"},"evaluator":{"claude":"claude-sonnet-5-5"},"speccheck":{"claude":"claude-sonnet-5-5"},"close":{"claude":"claude-opus-5-5"}},'"$MODELS"'}'
signoff "Tier: normal | Risk: x | Close model: opus"
for g in reviewer evaluator speccheck; do
  gp "$g"; absent "$out" "opus"; absent "$err" "opus"; assert_contains "$err" "with model: sonnet"
done
"$TKT" demo "$id" on >/dev/null
gp evaluator; assert_contains "$out" "
Model: haiku (Lite evaluator)"; absent "$err" "opus"
"$TKT" demo "$id" off >/dev/null
signoff "Tier: normal | Risk: x"; cp "$W/tiers.saved" "$CANON_HOME/cockpit/model-tiers.json"

# 5. The evaluator carries check-evidence's output; a refusing check-evidence gives no prompt, exit 1 and the reason
gp evaluator
assert_eq 0 "$code"
assert_contains "$out" "\`sprint check-evidence $id\` output (pre-flight):"
assert_contains "$out" "check-evidence: no stamped logs"
mkdir -p "$t/evidence"; printf 'HEAD %s 2026-11-22T00:00:00Z\nexit 3\n' "$(git rev-parse HEAD)" > "$t/evidence/c.log"
gp evaluator
assert_eq 1 "$code"; assert_eq "" "$out"
assert_contains "$err" "gate-prompt: sprint check-evidence $id refuses"
assert_contains "$err" "REFUSE  fresh c.log exit=3"
rm -rf "$t/evidence"

# 6. Manual mode (complete.md): the evaluator is told it is read-only; the reviewer is not
awk 'NR == 1 || !done && /^---$/ && NR > 1 { if (NR > 1) { print "manual: true"; done = 1 } } { print }' "$t/ticket.md" > "$W/tk" && mv "$W/tk" "$t/ticket.md"
"$SPRINT" manual-qa "$id" --by tester --step "open the app|pass" >/dev/null
gp evaluator
assert_eq 0 "$code"
assert_contains "$out" "Manual mode: the user's recorded testing is the evidence. Run and create no tests, no mutants and no command that writes"
gp reviewer; absent "$out" "Manual mode"
sed -i.bak '/^manual: true$/d' "$t/ticket.md" && rm -f "$t/ticket.md.bak"; rm -rf "$t/evidence"
gp evaluator; absent "$out" "Manual mode"

# 7. The second evaluator: second-eval's model, eval-report-2.md named as its report (the relay tells the two apart by it); skip refuses
signoff "Tier: normal | Risk: x | Second eval: on"
gp evaluator2
assert_eq 0 "$code"
assert_contains "$out" "You are canon's second evaluator for ticket $id"
assert_contains "$out" "
Model: opus (Admin Second eval default, claude)"
assert_contains "$out" "Write your report to $project/$t/eval-report-2.md"
COPILOT_CLI=1 gp evaluator2
assert_contains "$out" "You are the second evaluator: your report is .tickets/$id/eval-report-2.md."
assert_contains "$out" "Under Copilot CLI write no file"
COPILOT_CLI=1 gp evaluator; absent "$out" "eval-report-2.md"
signoff "Tier: normal | Risk: x"
gp evaluator2
assert_eq 1 "$code"; assert_eq "" "$out"; assert_contains "$err" "gate-prompt: no second evaluator for $id (sprint second-eval: skip:"

# 8. Outside Copilot no prompt states a verdict line or carries a run-id value: the protocol file owns the report's shape (t-63c6).
# CLAUDECODE=1 is the Claude Code harness (this file unsets it at the top, so the other sections run as harness none).
for r in speccheck reviewer evaluator; do
  for h in none claude copilot; do
    case "$h" in none) gp "$r" ;; claude) CLAUDECODE=1 gp "$r" ;; copilot) COPILOT_CLI=1 gp "$r" ;; esac
    absent "$out" "verdict:"
    [[ ! "$out" =~ evaluator-run-id:\ *[0-9] ]] || fail "gate-prompt $r ($h) carries a run-id value: $out"
    [[ ! "$out" =~ [0-9a-f]{40} ]] || fail "gate-prompt $r ($h) carries a commit hash (a gate records only the head it runs itself, t-2dc4): $out"
    if [[ "$h" != copilot ]]; then
      absent "$out" "pass:"; absent "$out" "must carry"; absent "$out" "graded-head"; absent "$out" "READY"
    fi
  done
done

# 8b. t-2dc4: under Copilot the prompt carries the lines the close parses, so a gate that cannot read its protocol (ToDo-Demo t-6x4z:
# the evaluator never read eval.md, 4 runs) still returns a closeable report. Protects every Copilot gate dispatch.
for r in evaluator evaluator2; do
  [[ "$r" != evaluator2 ]] || signoff "Tier: normal | Risk: x | Second eval: on"
  COPILOT_CLI=1 gp "$r"
  assert_eq 0 "$code"
  assert_contains "$out" "Follow .agents/skills/sprint/reference/eval.md for this ticket."
  assert_contains "$out" "- line 1: \`evaluator-run-id: <the output of sprint run-id>\`"
  assert_contains "$out" "- \`graded-head: <the full 40-character output of git rev-parse HEAD>\`: run it yourself and grade the diff up to that commit; never a short hash, never a hash taken from this prompt or your inputs"
  assert_contains "$out" "- the Model line above"
  assert_contains "$out" "- a verdict line that starts with \`pass:\` or \`fail:\` and a one-line summary"
done
signoff "Tier: normal | Risk: x"
COPILOT_CLI=1 gp speccheck
assert_contains "$out" "Your report must carry a \`## Verdict\` section whose line starts with \`READY\` (no finding) or \`GAPS\` (at least one)"
COPILOT_CLI=1 gp reviewer; absent "$out" "must carry"

# 9. Refusals: an unknown role or ticket
gp bogus; assert_eq 1 "$code"; assert_contains "$err" "Usage: sprint gate-prompt <id> <speccheck|reviewer|evaluator|evaluator2>"
set +e; out="$("$SPRINT" gate-prompt t-zzzz reviewer 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "gate-prompt: no ticket t-zzzz with a plan.md here."

# 10. gate-snapshot pre names the command; sprint --help lists the new pieces; sprint run-id has the shape the close checks
snap="$("$ROOT/tools/gate-snapshot.sh" pre "$t/gate-snapshot.txt" --role reviewer)"
"$ROOT/tools/gate-snapshot.sh" post "$t/gate-snapshot.txt" >/dev/null
assert_contains "$snap" "gate-snapshot: prompt: sprint gate-prompt $id reviewer (pass its output to the gate verbatim)"
help="$("$SPRINT" --help 2>&1 || true)"
assert_contains "$help" "  gate-prompt <id> <speccheck|reviewer|evaluator|evaluator2>"
assert_contains "$help" "  run-id "
assert_contains "$help" "  relay-report <id> [evaluator|evaluator2|reviewer|speccheck]"
rid="$("$SPRINT" run-id)"
[[ "$rid" =~ ^[0-9]{10}-[0-9]+$ ]] || fail "sprint run-id printed '$rid', not <epoch-seconds>-<number>"

echo "sprint-gate-prompt: ok"
