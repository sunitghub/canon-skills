#!/usr/bin/env bash
# sprint-pipeline (t-7e76) — `sprint approve` and `sprint complete` read the project's pipeline (canon-config/pipeline.yaml, resolved by
# tools/pipeline.sh). End to end in throwaway projects:
#   - approve pins the resolved pipeline (`Pipeline: sha256:<12> off=<ids|-> wrapup=<ids>`) and refuses, writing nothing, when the resolver refuses;
#   - a project with no override closes exactly as before: no pipeline output, no refusal, no wrapup.gate_finished event;
#   - a removed node needs its Wrapup Gates row and a summary.md line (each refusal says what to add), and leaves one event per node;
#   - a pipeline that differs from the pin refuses naming what changed; no pin (an older ticket) is a notice; a malformed pin or file refuses;
#   - a refused close leaves plan.md, acceptance.md, summary.md and the ticket byte-identical, and a hostile pin or file is never executed.
# Protects `sprint approve` and `sprint complete`, the two commands every sprint runs.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # sprint complete's events go through the board binary
DIRS=()
cleanup() { local d; for d in ${DIRS[@]+"${DIRS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

SPRINT_REAL_ALL="$SPRINT"
ID=""
new_project() { local d; d="$(make_project)"; DIRS+=("$d"); cd "$d"; }
new_sprint() {   # start a sprint here with a plan that waits for `sprint approve`
  local out; out="$("$SPRINT" start "pipeline coverage")"
  ID="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
  printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [ ] Plan approved\n## Approach\ntest\n' > ".tickets/$ID/plan.md"
}
override() { mkdir -p canon-config; printf '%b' "$1" > canon-config/pipeline.yaml; }
close_docs() {   # close_docs <extra Wrapup Gates rows, printf %b> <extra summary lines, printf %b>: everything a close needs but a gate report
  printf '# Acceptance\n## Criteria\n- [x] Some criterion. **Waived (partial):** user-approved waiver, 2026-07-11: no real run.\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | verdict: fail |\n%b' "$1" > ".tickets/$ID/acceptance.md"
  printf '# Summary\n| Item | Status |\n|---|---|\n| done | delivered |\n%b' "$2" > ".tickets/$ID/summary.md"
  mkdir -p .claude
  printf '{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-pipe","agent_type":"general-purpose","transcript_path":"/tmp/pipe.jsonl"}\n' > .claude/subagent-runs.jsonl
  printf '# Eval Report\nevaluator-run-id: 1000000000-pipe1\nModel: test-model\n## Verdict\nfail: one criterion partial\n' > ".tickets/$ID/eval-report.md"
  sed -i.bak 's/^eval_override: false$/eval_override: true/' ".tickets/$ID/ticket.md"; rm -f ".tickets/$ID/ticket.md.bak"
}
fingerprint() { shasum -a 256 ".tickets/$ID/plan.md" ".tickets/$ID/acceptance.md" ".tickets/$ID/summary.md" ".tickets/$ID/ticket.md"; }
events_of() { cat "$CANON_HOME"/events/*.jsonl 2>/dev/null | grep -F '"kind":"wrapup.gate_finished"' | grep -F "\"ticket\":\"$ID\"" || true; }
pin_of() { sed -n 's/^Pipeline: sha256:\(.*\)$/\1/p' ".tickets/$ID/plan.md"; }
DEFAULT_WRAPUP="code-simplifier,code-reviewer,doc-audit"
ROW_MT='| mutation-test | skipped | removed in this project'"'"'s pipeline |\n'
ROW_BI='| break-it | skipped | removed in this project'"'"'s pipeline |\n'

# ── no override: the pin is written, and the close is unchanged ──
new_project; new_sprint
"$SPRINT" approve "$ID" >/dev/null
assert_eq "$(printf '%s' "$(pin_of)" | cut -c14-)" "off=- wrapup=$DEFAULT_WRAPUP"
[[ "$(pin_of)" =~ ^[0-9a-f]{12}\ off=-\ wrapup=$DEFAULT_WRAPUP$ ]] || fail "sprint approve wrote a malformed Pipeline pin: $(pin_of)"
[[ "$(grep -c '^Pipeline: sha256:' ".tickets/$ID/plan.md")" == 1 ]] || fail "sprint approve wrote more than one Pipeline pin"
"$SPRINT" approve "$ID" >/dev/null   # approving again replaces the pin, never stacks one
[[ "$(grep -c '^Pipeline: sha256:' ".tickets/$ID/plan.md")" == 1 ]] || fail "a second sprint approve stacked a second Pipeline pin"
close_docs '' ''
out="$("$SPRINT" complete 2>&1)"
assert_contains "$out" "Sprint completed: $ID"
[[ "$out" != *[Pp]ipeline* ]] || fail "a close with no override printed pipeline output: $out"
[[ -z "$(events_of)" ]] || fail "a close with no override wrote wrapup.gate_finished: $(events_of)"

# ── removed nodes: row, summary line, event; each refusal says what to add; a refusal writes nothing ──
new_project; override 'extends: canon-default\noff: [mutation-test, break-it]\n'; new_sprint
"$SPRINT" approve "$ID" >/dev/null
assert_eq "off=break-it,mutation-test wrapup=$DEFAULT_WRAPUP" "$(pin_of | cut -d' ' -f2-)"
close_docs '' ''
before="$(fingerprint)"
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "this project's pipeline removes break-it,mutation-test"
assert_contains "$out" "| break-it | skipped | removed in this project's pipeline |"
assert_contains "$out" "| mutation-test | skipped | removed in this project's pipeline |"
assert_contains "$out" "summary.md needs a line naming break-it: Pipeline: removed break-it,mutation-test (canon-config/pipeline.yaml)"
assert_eq "$before" "$(fingerprint)"
close_docs "$ROW_MT" ''
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "acceptance.md ## Wrapup Gates needs the row: | break-it |"
[[ "$out" != *"needs the row: | mutation-test"* ]] || fail "a present row was still demanded: $out"
close_docs "$ROW_MT$ROW_BI" ''
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "summary.md needs a line naming break-it"
assert_contains "$out" "summary.md needs a line naming mutation-test"
close_docs '| break-it | ran | removed in this project'"'"'s pipeline |\n| mutation-test | skipped | not needed |\n' 'Pipeline: removed break-it, mutation-test\n'
out="$(run_fail "$SPRINT" complete)"   # the row for a removed node must be `skipped` with the phrase: `ran` or another reason does not count
assert_contains "$out" "needs the row: | break-it |"; assert_contains "$out" "needs the row: | mutation-test |"
[[ -z "$(events_of)" ]] || fail "a refused close wrote wrapup.gate_finished"
close_docs "$ROW_MT$ROW_BI" 'Pipeline: removed break-it, mutation-test (canon-config/pipeline.yaml)\n'
out="$("$SPRINT" complete 2>&1)"
assert_contains "$out" "Sprint completed: $ID"
ev="$(events_of)"
[[ "$(printf '%s\n' "$ev" | wc -l | tr -d ' ')" == 2 ]] || fail "expected two wrapup.gate_finished events, got: $ev"
assert_contains "$ev" '"gate":"break-it"'; assert_contains "$ev" '"gate":"mutation-test"'; assert_contains "$ev" '"result":"removed"'
[[ "$ev" != *'"gate":"doc-audit"'* ]] || fail "an event was written for a node that was not removed: $ev"

# ── drift after approval: refused naming what changed; fixed by restoring the file ──
new_project; new_sprint
"$SPRINT" approve "$ID" >/dev/null
override 'extends: canon-default\noff: [mutation-test]\n'
close_docs "$ROW_MT" 'Pipeline: removed mutation-test\n'
before="$(fingerprint)"
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "the pipeline changed after approval (mutation-test)"
assert_contains "$out" "sprint approve $ID"
assert_eq "$before" "$(fingerprint)"
override 'extends: canon-default\nwrapup-order: [doc-audit, code-reviewer, code-simplifier]\n'
close_docs '' ''
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "the pipeline changed after approval (wrapup order)"
rm -r canon-config
out="$("$SPRINT" complete 2>&1)"
assert_contains "$out" "Sprint completed: $ID"

# ── approve again after a change: the new pipeline is the pin ──
new_project; new_sprint
"$SPRINT" approve "$ID" >/dev/null
override 'extends: canon-default\noff: [skill-eval]\n'
"$SPRINT" approve "$ID" >/dev/null
assert_eq "off=skill-eval wrapup=$DEFAULT_WRAPUP" "$(pin_of | cut -d' ' -f2-)"
close_docs '| skill-eval | skipped | removed in this project'"'"'s pipeline |\n' 'Pipeline: removed skill-eval\n'
assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed: $ID"

# ── a locked node or a malformed file: approve refuses and writes nothing; a later edit refuses the close ──
new_project; override 'extends: canon-default\noff: [eval]\n'; new_sprint
before="$(shasum -a 256 ".tickets/$ID/plan.md")"
out="$(run_fail "$SPRINT" approve "$ID")"
assert_contains "$out" "node 'eval' is locked"
assert_eq "$before" "$(shasum -a 256 ".tickets/$ID/plan.md")"
override 'extends: canon-default\nthis is not a pipeline\n'
out="$(run_fail "$SPRINT" approve "$ID")"
assert_contains "$out" "unsupported line"
assert_eq "$before" "$(shasum -a 256 ".tickets/$ID/plan.md")"
rm -r canon-config; "$SPRINT" approve "$ID" >/dev/null
close_docs '' ''
override 'extends: canon-default\noff: [security-review]\n'
before="$(fingerprint)"
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "cannot close"; assert_contains "$out" "node 'security-review' is locked"
assert_eq "$before" "$(fingerprint)"
override 'extends: canon-default\n$(touch EXECUTED)\n'
out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "unsupported line"
[[ ! -e EXECUTED ]] || fail "a project file ran a command during sprint complete"

# ── a ticket approved before the pin (no Pipeline: line): a notice, no drift check, still closes ──
new_project; new_sprint
printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [x] Plan approved\n## Approach\ntest\n' > ".tickets/$ID/plan.md"
close_docs '' ''
out="$("$SPRINT" complete 2>&1)"
assert_contains "$out" "plan.md has no 'Pipeline:' pin"
assert_contains "$out" "Sprint completed: $ID"
# ...and a removed node on such a ticket still needs its row, summary line and event
new_project; override 'extends: canon-default\noff: [mutation-test]\n'; new_sprint
printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [x] Plan approved\n## Approach\ntest\n' > ".tickets/$ID/plan.md"
close_docs '' ''
out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "| mutation-test | skipped | removed in this project's pipeline |"
close_docs "$ROW_MT" 'Pipeline: removed mutation-test\n'
assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed: $ID"
[[ "$(events_of | wc -l | tr -d ' ')" == 1 ]] || fail "expected one wrapup.gate_finished for the old ticket's removed node"

# ── malformed-input run (before the gates): hostile and wrong-shaped pins end in a one-line refusal or a pass, never a shell error or a write ──
pins=('' 'x' 'zzzzzzzzzzzz off=- wrapup=a' '000000000000 off=$(touch EXECUTED) wrapup=a' '000000000000 off=- wrapup=a b' 'aaaaaaaaaaaa off=a,b,c wrapup=code-simplifier,code-reviewer,doc-audit'
  "$(printf 'a%.0s' $(seq 1 5000))" $'000000000000 off=-\r wrapup=x' '`touch EXECUTED`' '000000000000 off=- wrapup=-; touch EXECUTED')
for pin in "${pins[@]}"; do
  new_project; new_sprint
  printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [x] Plan approved\nPipeline: sha256:%s\n## Approach\ntest\n' "$pin" > ".tickets/$ID/plan.md"
  close_docs '' ''
  before="$(fingerprint)"; rc=0
  out="$("$SPRINT" complete 2>&1)" || rc=$?
  if (( rc != 0 )); then
    assert_eq "$before" "$(fingerprint)"
    [[ "$out" == *"cannot close"* && "$out" != *"syntax error"* && "$out" != *"unbound variable"* ]] || fail "a bad pin ended in a shell error: $out"
    if [[ "$pin" =~ ^[0-9a-f]{12}\ off=[a-z0-9,-]+\ wrapup=[a-z0-9,-]+$ ]]; then
      [[ "$out" == *"changed after approval"* ]] || fail "a well-shaped pin that differs did not say the pipeline changed: $out"
    else
      [[ "$out" == *"'Pipeline:' pin is malformed"* ]] || fail "a malformed pin did not say so: $pin -> $out"
    fi
  fi
  [[ ! -e EXECUTED ]] || fail "a pin line ran a command: $pin"
done

# ── a broken default (the resolver refuses): the close refuses with the resolver's own line and nothing else changes ──
new_project; new_sprint
printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [x] Plan approved\n## Approach\ntest\n' > ".tickets/$ID/plan.md"
close_docs '' ''
override 'off: [break-it]\n'   # no `extends: canon-default`
before="$(fingerprint)"
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "missing 'extends: canon-default'"
assert_eq "$before" "$(fingerprint)"

# ── survivors of the mutation sweep and the reviewer's CRLF finding ──
# CRLF: a Windows checkout ends every line with \r; the summary line, the table rows and the pin must still match
new_project; override 'extends: canon-default\noff: [mutation-test]\n'; new_sprint
"$SPRINT" approve "$ID" >/dev/null
sed -i.bak 's/$/\r/' ".tickets/$ID/plan.md"; rm -f ".tickets/$ID/plan.md.bak"
close_docs "$ROW_MT" 'Pipeline: removed mutation-test (canon-config/pipeline.yaml)\n'
sed -i.bak 's/$/\r/' ".tickets/$ID/acceptance.md" ".tickets/$ID/summary.md"; rm -f ".tickets/$ID/acceptance.md.bak" ".tickets/$ID/summary.md.bak"
out="$("$SPRINT" complete 2>&1)" || fail "a CRLF summary, table and pin refused a correct close: $out"
assert_contains "$out" "Sprint completed: $ID"
ev="$(events_of)"; assert_contains "$ev" "\"project\":\"$(pwd -P)\""
# every problem is on its own line, and a resolver refusal prints its fix line and stops there (nothing later in the gate runs)
new_project; override 'extends: canon-default\noff: [mutation-test, break-it]\n'; new_sprint
"$SPRINT" approve "$ID" >/dev/null
close_docs '' ''
out="$(run_fail "$SPRINT" complete)"
[[ "$(printf '%s\n' "$out" | grep -c 'needs')" == 4 ]] || fail "the four missing rows and lines are not four separate lines: $out"
# a summary line that names only one of two removed nodes, or one whose name merely starts with a removed node's, does not count
close_docs "$ROW_MT$ROW_BI" 'Pipeline: removed mutation-test\n'
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "summary.md needs a line naming break-it"; [[ "$out" != *"naming mutation-test"* ]] || fail "a node the summary names was demanded again: $out"
close_docs "$ROW_MT$ROW_BI" 'Pipeline: removed mutation-testx, break-itx\n'
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "summary.md needs a line naming break-it"; assert_contains "$out" "summary.md needs a line naming mutation-test"
# drift names exactly the nodes that were added or removed since the pin, once each
new_project; override 'extends: canon-default\noff: [mutation-test, break-it]\n'; new_sprint
"$SPRINT" approve "$ID" >/dev/null
override 'extends: canon-default\noff: [break-it, skill-eval]\n'
close_docs '| break-it | skipped | removed in this project'"'"'s pipeline |\n| skill-eval | skipped | removed in this project'"'"'s pipeline |\n' 'Pipeline: removed break-it, skill-eval\n'
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "the pipeline changed after approval (mutation-test, skill-eval)."
# a resolver refusal prints its fix line and nothing from the later checks
new_project; new_sprint
"$SPRINT" approve "$ID" >/dev/null
close_docs '' ''
override 'extends: canon-default\noff: [eval]\n'
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "Fix canon-config/pipeline.yaml (or restore it); a locked node cannot be switched off."
[[ "$out" != *"changed after approval"* && "$out" != *"malformed"* && "$out" != *"needs the row"* ]] || fail "the gate went on after the resolver refused: $out"
# a malformed pin is refused outright (never only noticed), including one with junk in front of a well-shaped pin
for pin in 'x' 'junk 000000000000 off=- wrapup=code-simplifier,code-reviewer,doc-audit' '000000000000 off=- wrapup=a;'; do
  new_project; new_sprint
  printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [x] Plan approved\nPipeline: sha256:%s\n## Approach\ntest\n' "$pin" > ".tickets/$ID/plan.md"
  close_docs '' ''
  out="$(run_fail "$SPRINT" complete)"
  assert_contains "$out" "'Pipeline:' pin is malformed"
done
# canon's own default changed after approval (a canon update): the same refusal, naming the change; a copy of the install holds its own default
T3="$(mktemp -d)"; DIRS+=("$T3"); mkdir -p "$T3/tools" "$T3/skills/sprint"; cp "$ROOT"/tools/* "$T3/tools/" 2>/dev/null || true; cp "$ROOT/skills/sprint/pipeline.yaml" "$T3/skills/sprint/"
SPRINT="$T3/tools/sprint"
new_project; new_sprint
"$SPRINT" approve "$ID" >/dev/null
sed -i.bak 's/order: 90$/order: 91/' "$T3/skills/sprint/pipeline.yaml"; rm -f "$T3/skills/sprint/pipeline.yaml.bak"
close_docs '' ''
out="$(run_fail "$SPRINT" complete)"
assert_contains "$out" "the pipeline changed after approval (the resolved order (a canon default or a node order changed))"
SPRINT="$SPRINT_REAL_ALL"
# approve touches only the Sign-off: a Pipeline: line elsewhere in plan.md stays, and the pins sit right under the box
new_project; new_sprint
printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [ ] Plan approved\n## Approach\nPipeline: sha256:keep-me\ntest\n' > ".tickets/$ID/plan.md"
"$SPRINT" approve "$ID" >/dev/null
assert_grep '^Pipeline: sha256:keep-me$' ".tickets/$ID/plan.md"
assert_eq "- [x] Plan approved" "$(sed -n 4p ".tickets/$ID/plan.md")"
[[ "$(sed -n 5p ".tickets/$ID/plan.md")" == "Approved: sha256:"* && "$(sed -n 6p ".tickets/$ID/plan.md")" == "Pipeline: sha256:"* ]] || fail "the Approved and Pipeline pins are not right under the box: $(sed -n 3,7p ".tickets/$ID/plan.md")"

# ── an install with no pipeline.sh (an older one): the gate is skipped, approve writes no pin, nothing refuses ──
T2="$(mktemp -d)"; DIRS+=("$T2"); cp "$ROOT"/tools/* "$T2/" 2>/dev/null || true; rm -f "$T2/pipeline.sh"
SPRINT_REAL="$SPRINT"; SPRINT="$T2/sprint"
new_project; override 'extends: canon-default\noff: [eval]\n'   # a file the resolver would refuse; without a resolver it is not read
new_sprint
"$SPRINT" approve "$ID" >/dev/null
[[ -z "$(pin_of)" ]] || fail "sprint approve wrote a Pipeline pin with no pipeline.sh in the install: $(pin_of)"
close_docs '' ''
out="$("$SPRINT" complete 2>&1)"
assert_contains "$out" "Sprint completed: $ID"
SPRINT="$SPRINT_REAL"

# ── the docs say it ──
grep -qF -- 'Project pipeline (t-7e76)' "$ROOT/skills/sprint/reference/complete.md" || fail "complete.md lost its 'Project pipeline (t-7e76)' paragraph"
grep -qF -- "removed in this project's pipeline" "$ROOT/skills/sprint/reference/complete.md" || fail "complete.md does not name the removed-node row reason"

echo "PASS: sprint-pipeline"
