#!/usr/bin/env bash
# sprint-approve — `sprint approve` pins ## Approach and the close plan gate refuses on drift (t-0865).
# Protects the sprint-close plan gate (_gate_plan_signoff).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

id="$("$SPRINT" start "Pin approval" | awk '/Sprint started:/ { print $3 }')"
plan=".tickets/$id/plan.md"
cat > "$plan" <<'PLAN'
# Plan

## Sign-off
Tier: normal | Risk: low

- [ ] Plan approved — proceed to implementation

## Approach
Do the thing.

## Files
- tools/sprint
PLAN
spec_verdict ".tickets/$id"   # t-2bfe: approve waits for the spec check; its refusal is tested below

# The gate is called directly: a full `sprint complete` needs reviewer/evaluator reports.
# eval, not source <(...): macOS's bash 3.2 sources nothing from a process substitution.
gate() { ( eval "$(sed -n '/^_acceptance_section()/,/^}/p;/^_gate_plan_signoff()/,/^}/p;/^_approach_digest()/,/^}/p' "$SPRINT")"; _gate_plan_signoff "$id" "$plan" 2>&1 ); }

# 1. approve ticks the box and writes the pin under it
out="$("$SPRINT" approve "$id")"
assert_contains "$out" "pinned ## Approach"
assert_grep '^- \[x\] Plan approved' "$plan"
assert_grep '^Approved: sha256:[0-9a-f]{64} [0-9TZ:-]+$' "$plan"
first="$(grep -c '^Approved:' "$plan")"; assert_eq "1" "$first"
# t-2db7: approve writes plan.approved (the kind had no writer) and the main checkout's HANDOFF.md Recent activity shows it
assert_contains "$(event_line plan.approved "$id")" '"tier":"normal"'
assert_grep "· $id · plan approved \(normal\)$" HANDOFF.md
assert_contains "$("$SPRINT" recent)" "· $id · plan approved (normal)"

# 2. unchanged Approach passes
gate >/dev/null || fail "unchanged Approach must pass the plan gate"

# 3. Files-only (and Decisions) change passes
printf '\n- tests/sprint-approve.sh\n' >> "$plan"
gate >/dev/null || fail "a change only in ## Files must pass the plan gate"

# 4. changed Approach refuses and names sprint approve
sed -i.bak 's/Do the thing\./Do another thing./' "$plan"; rm -f "$plan.bak"
if out="$(gate)"; then fail "changed Approach must refuse"; fi
assert_contains "$out" "Approach changed after approval"
assert_contains "$out" "sprint approve $id"

# 5. re-approve updates the single Approved line and the gate passes again
"$SPRINT" approve "$id" >/dev/null
assert_eq "1" "$(grep -c '^Approved:' "$plan")"
gate >/dev/null || fail "re-approve must make the plan gate pass"

# 6. t-2bfe: a ticked box with no Approved: pin is not approved (it used to pass with a warning, t-0865)
sed -i.bak '/^Approved:/d' "$plan"; rm -f "$plan.bak"
if out="$(gate)"; then fail "a ticked box with no pin must refuse the close"; fi
assert_contains "$out" "Sprint $id cannot close: plan.md has no 'Approved: sha256:' pin; run sprint approve $id."
# ...and sprint start on a written plan with that ticked box (no pin) asks for approval, not "already approved" (sprint start's step 3)
p2="$(make_project)"; unpinned="$(sed '/^Approved:/d' "$plan")"
out="$(cd "$p2" && sid="$("$TKT" create "Ticked, not pinned" -t task -p 2)" && mkdir -p ".tickets/$sid" \
  && printf '%s\n' "$unpinned" > ".tickets/$sid/plan.md" && "$SPRINT" start "$sid")"
rm -rf "$p2"
assert_contains "$out" "3. Fill in plan.md — write the approach, then wait for explicit approval before coding."
[[ "$out" != *"already approved"* ]] || fail "a ticked box with no pin must not read as approved at sprint start: $out"

# 7. approve refuses a missing id, a missing plan, and a plan with no approval box
out="$(run_fail "$SPRINT" approve)"; assert_contains "$out" "Usage: sprint approve"
out="$(run_fail "$SPRINT" approve t-nope)"; assert_contains "$out" "no plan.md"
printf '# Plan\n\n## Sign-off\nTier: normal\n\n## Approach\nx\n\n## Files\n- [ ] Plan approved\n' > "$plan"   # box outside ## Sign-off
out="$(run_fail "$SPRINT" approve "$id")"; assert_contains "$out" "no '- [ ] Plan approved' box"

# 8. trailing spaces on Approach lines do not change the pin
printf '# Plan\n\n## Sign-off\n- [ ] Plan approved\n\n## Approach\nstep one\n' > "$plan"
"$SPRINT" approve "$id" >/dev/null
sed -i.bak 's/step one/step one   /' "$plan"; rm -f "$plan.bak"
gate >/dev/null || fail "trailing spaces in Approach must not trip the plan gate"

# 9. t-cc88: a capped file plan.md ## Files names prints one headroom line when under 10% is left (HANDOFF.md: 80 block-lines,
# tools/caps.tsv); exactly 10%, no row, an absent capped file and an older board print nothing; a failed read says so.
handoff() { { echo '<!-- canon:handoff:BEGIN -->'; for ((i = 0; i < $1; i++)); do echo "line $i"; done; echo '<!-- canon:handoff:END -->'; } > HANDOFF.md; }
approve_with() { printf '# Plan\n\n## Sign-off\n- [ ] Plan approved\n\n## Approach\nstep one\n\n## Files\n%s\n' "$1" > "$plan"; "$SPRINT" approve "$id"; }
caplines() { grep -v '^Approved \|Build model\|^Models (' <<< "$1" || true; }   # t-3425: the Build model line is checked below; t-2a21: the Models line in sprint-models-line.sh
echo notes > notes.md
handoff 75; out="$(approve_with '`HANDOFF.md`, `notes.md` (new)')"
assert_eq "HANDOFF.md: 75 of 80 lines, 5 left: make room first" "$(caplines "$out")"
assert_grep '^Approved: sha256:' "$plan"
# t-c990: the line also writes budget.warned with the row name, never the path; over the cap, budget.exceeded
assert_eq '"data":{"cap":"handoff","limit":"80","stage":"plan","ticket":"'"$id"'","unit":"lines","used":"75"}}' "$(sed -n 's/.*\("data":.*\)/\1/p' <<< "$(event_line budget.warned "$id")")"
handoff 82; out="$(approve_with '- HANDOFF.md.')"   # a bare bullet, a sentence's full stop
assert_eq "HANDOFF.md: 82 of 80 lines, over by 2: make room first" "$(caplines "$out")"
assert_contains "$(event_line budget.exceeded "$id")" '"cap":"handoff","limit":"80","stage":"plan"'
handoff 72; out="$(approve_with '`HANDOFF.md`')"; assert_eq "" "$(caplines "$out")"   # 8 left of 80: exactly 10%
warned() { cat "$CANON_HOME"/events/*.jsonl 2>/dev/null | grep -F '"kind":"budget.warned"' | grep -cF "\"ticket\":\"$id\"" || true; }
assert_eq 1 "$(warned)"   # within the cap: no event
out="$(approve_with '`notes.md`, `LEARNINGS.md`')"; assert_eq "" "$(caplines "$out")"   # no row; a row whose file is absent
echo 'no markers' > HANDOFF.md; out="$(approve_with '`HANDOFF.md`')"
[[ "$(caplines "$out")" == "HANDOFF.md: cap not measured: caps: handoff: no <!-- canon:handoff:BEGIN -->"* ]] || fail "unmeasured cap: $out"
# an older board (no `caps` in --help) is never asked: it would take the word for a port and serve
stub="$(mktemp -d)"; trap 'rm -rf "$project" "$stub"' EXIT
printf '#!/usr/bin/env bash\n[[ "$1" == --help ]] && { echo "usage: sprint-check [port]"; exit 0; }\ntouch "%s/called"; sleep 30\n' "$stub" > "$stub/board"; chmod +x "$stub/board"
# t-2bfe: an older board has no walk either, so approve refuses before any caps call, naming canon update, nothing written
handoff 75; set +e; out="$(SPRINT_CHECK_BIN="$stub/board" approve_with '`HANDOFF.md`' 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "has no walk (run canon update)"; [[ ! -e "$stub/called" ]] || fail "an older board was called"
assert_grep '^- \[ \] Plan approved' "$plan"
# no board binary at all: the same refusal (the --help call fails under set -e)
set +e; out="$(SPRINT_CHECK_BIN="$stub/missing" approve_with '`HANDOFF.md`' 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "has no walk (run canon update)"; assert_grep '^- \[ \] Plan approved' "$plan"
# a CRLF plan.md still names its files
printf '# Plan\r\n\r\n## Sign-off\r\n- [ ] Plan approved\r\n\r\n## Approach\r\nstep one\r\n\r\n## Files\r\n- HANDOFF.md\r\n' > "$plan"
assert_eq "HANDOFF.md: 75 of 80 lines, 5 left: make room first" "$(caplines "$("$SPRINT" approve "$id")")"

# t-3425: approve names the Build model: the ticket's line first, else Admin's Build pick for the agent ($CANON_HOME's registry, read by
# canon-go stage-model); in the Cockpit it says the switch comes when the turn ends, elsewhere it gives the /model line; Pi gets none.
signoff() { printf '# Plan\n\n## Sign-off\n%s\n\n- [ ] Plan approved\n\n## Approach\nstep one\n' "$1" > "$plan"; }
buildline() { grep 'Build model' <<< "$1" || true; }
mkdir -p "$CANON_HOME/cockpit"
printf '%s' '{"defaults":{"build":{"claude":"claude-sonnet-5-5","copilot":"gpt-6"}},"models":{"anthropic":[{"id":"claude-sonnet-5-5","alias":"sonnet"}]}}' > "$CANON_HOME/cockpit/model-tiers.json"
signoff "Tier: normal | Build model: haiku"
assert_eq "Build model (the ticket's Build model line): haiku: switch with /model haiku" "$(buildline "$(COCKPIT_TICKET='' "$SPRINT" approve "$id")")"
signoff "Tier: normal"
assert_eq "This session switches to the Build model (sonnet, from Admin > Model tiers) when this turn ends: end your turn now." "$(buildline "$(COCKPIT_TICKET="$id" COCKPIT_AGENT=claude "$SPRINT" approve "$id")")"
signoff "Tier: normal"
assert_eq "This session switches to the Build model (gpt-6, from Admin > Model tiers) when this turn ends: end your turn now." "$(buildline "$(COCKPIT_TICKET="$id" COCKPIT_AGENT=copilot "$SPRINT" approve "$id")")"
signoff "Tier: normal | Build model: haiku"
assert_eq "Build model: Pi has no /model, so this session keeps its model." "$(buildline "$(COCKPIT_TICKET="$id" COCKPIT_AGENT=pi "$SPRINT" approve "$id")")"
# outside the Cockpit a pi run gets no line, and approve still succeeds
signoff "Tier: normal | Build model: haiku"
out="$(COCKPIT_TICKET='' COCKPIT_AGENT=pi "$SPRINT" approve "$id")" || fail "approve failed for pi"
assert_eq "" "$(buildline "$out")"
# a leading-dash value is never offered as a model; with no Admin pick there is no line at all
printf '{}' > "$CANON_HOME/cockpit/model-tiers.json"
signoff "Tier: normal | Build model: --dangerously-skip-permissions"
assert_eq "" "$(buildline "$(COCKPIT_TICKET='' "$SPRINT" approve "$id")")"
assert_grep '^- \[x\] Plan approved' "$plan"

# t-2bfe: approve refuses while the spec check has not run (it was t-d826's warning, read past twice on Windows Copilot): exit 1,
# the missed line naming the fix, plan.md byte for byte as it was. Only when the pipeline runs it for this ticket (Lite and off: skip).
try() { set +e; err="$("$@" approve "$id" 2>&1 >/dev/null)"; code=$?; set -e; }
refused() { assert_eq 1 "$code"; assert_eq "$before" "$(cksum < "$plan")"; assert_contains "$err" "$1"; }
printf '{}' > "$CANON_HOME/cockpit/model-tiers.json"
signoff "Tier: normal"; rm -f ".tickets/$id/spec-review.md"; before="$(cksum < "$plan")"
try "$SPRINT"; refused "sprint approve: $id is not approved: a step before approval has not run (nothing written)"
assert_contains "$err" "missed: spec-check — the spec check has not run: dispatch canon-spec-checker with sprint gate-prompt $id speccheck"
[[ "$err" != *relay-report* ]] || fail "the refusal names the Copilot relay outside Copilot: $err"
COPILOT_CLI=1 try "$SPRINT"; refused "sprint approve: under Copilot, when it returns: sprint relay-report $id speccheck"
printf '# Spec check: %s\n\n## Verdict\nREADY | GAPS — <one sentence>\n' "$id" > ".tickets/$id/spec-review.md"   # the unfilled template
try "$SPRINT"; refused "missed: spec-check"
spec_verdict ".tickets/$id"; try "$SPRINT"; assert_eq 0 "$code"; assert_grep '^Approved: sha256:' "$plan"
rm -f ".tickets/$id/spec-review.md"
"$TKT" demo "$id" on >/dev/null; signoff "Tier: normal"; try "$SPRINT"; assert_eq 0 "$code"   # Lite: skip_on: lite
"$TKT" demo "$id" off >/dev/null
awk 'NR == 1 || !d && /^---$/ { if (NR > 1) { print "manual: true"; d = 1 } } { print }' ".tickets/$id/ticket.md" > "$plan.tk" && mv "$plan.tk" ".tickets/$id/ticket.md"
signoff "Tier: normal"; before="$(cksum < "$plan")"; try "$SPRINT"; refused "missed: spec-check"   # canon's default skips it for Lite only
sed -i.bak '/^manual: true$/d' ".tickets/$id/ticket.md" && rm -f ".tickets/$id/ticket.md.bak"
mkdir -p canon-config; printf 'extends: canon-default\noff: [spec-check]\n' > canon-config/pipeline.yaml
signoff "Tier: normal"; try "$SPRINT"; assert_eq 0 "$code"   # the project's pipeline turns it off
printf 'not: [a, valid\n' > canon-config/pipeline.yaml   # a pipeline the reader refuses: never read as "nothing to check"
signoff "Tier: normal"; before="$(cksum < "$plan")"; try "$SPRINT"; refused "sprint approve: "
rm -rf canon-config
# an install with no tools/pipeline.sh cannot check: refused, never a guess
nopipe="$(mktemp -d)"; copy_canon_tree "$nopipe"; rm -f "$nopipe/tools/pipeline.sh"
signoff "Tier: normal"; before="$(cksum < "$plan")"; try "$nopipe/tools/sprint"; rm -rf "$nopipe"
refused "cannot check the steps before approval"

echo "sprint-approve: ok"
