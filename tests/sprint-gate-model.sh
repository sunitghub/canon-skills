#!/usr/bin/env bash
# sprint-gate-model — t-c723: the model every close gate (and the spec check) is dispatched with. Protects `sprint gate-model` and the line
# `gate-snapshot.sh pre --role` prints right before each dispatch (Admin's pick for this agent, with complete.md's fail-safes; a Gate model
# line or a Lite evaluator defers to complete.md), complete-checklist.md's Model bullet that tells the agent to pass it, and
# `sprint eval-verdict`'s refusal of a verdict line in the wrong shape (count unchanged), which cost the Windows Copilot run a second evaluator.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

W="$(mktemp -d)"
# gate-snapshot.sh pre registers a gate scope: pinned to this test's own registry (t-c206), every dir it recorded removed on exit
export CANON_GATE_SCOPE_DIR="$W/registry"
# its own Admin registry: the full run shares one CANON_HOME across parallel suites, and sprint-second-eval writes model-tiers.json too
export CANON_HOME="$W/canon-home"
project="$(make_project)"
cleanup() {
  local f d
  for f in "$CANON_GATE_SCOPE_DIR"/*; do
    [[ -f "$f" ]] || continue
    d="$(sed -n 's/^dir=//p' "$f")"; [[ "$d" == /*/* ]] && rm -rf "$d"
  done
  rm -rf "$W" "$project"
}
trap cleanup EXIT
unset COCKPIT_AGENT COPILOT_CLI CANON_TICKETS_DIR
cd "$project"
git commit -q --allow-empty -m init
id="$("$SPRINT" start "Gate models" | awk '/Sprint started:/ { print $3 }')"
t=".tickets/$id"
signoff() { printf '# Plan\n\n## Sign-off\n%s\n\n- [x] Plan approved\n\n## Approach\nx\n' "$1" > "$t/plan.md"; }
reg() { mkdir -p "$CANON_HOME/cockpit"; printf '%s' "$1" > "$CANON_HOME/cockpit/model-tiers.json"; }
gm() { "$SPRINT" gate-model "$id" "$1" 2>&1 || echo "EXIT $?"; }
snap() { "$ROOT/tools/gate-snapshot.sh" pre "$t/gate-snapshot.txt" --role "$1" | grep 'dispatch' || true; "$ROOT/tools/gate-snapshot.sh" post "$t/gate-snapshot.txt" >/dev/null; }
MODELS='"models":{"anthropic":[{"id":"claude-sonnet-5-5","alias":"sonnet"},{"id":"claude-opus-5-5","alias":"opus"},{"id":"claude-haiku-5-5","alias":"haiku"},{"id":"claude-mythos-1"}]}'

# 1. Admin's pick per agent: claude (its alias), copilot (as is) from COCKPIT_AGENT or COPILOT_CLI=1, pi none
signoff "Tier: normal | Risk: x"
reg '{"defaults":{"reviewer":{"claude":"claude-opus-5-5","copilot":"claude-sonnet-5.5"},"evaluator":{"claude":"claude-sonnet-5-5","copilot":"gpt-6-luna"},"speccheck":{"claude":"claude-sonnet-5-5","copilot":"claude-haiku-5.5"}},'"$MODELS"'}'
assert_eq "model: opus (Admin Reviewer default, claude)" "$(gm reviewer)"
assert_eq "model: sonnet (Admin Evaluator default, claude)" "$(gm evaluator)"
assert_eq "model: sonnet (Admin Spec check default, claude)" "$(gm speccheck)"
assert_eq "model: claude-sonnet-5.5 (Admin Reviewer default, copilot)" "$(COCKPIT_AGENT=copilot gm reviewer)"
assert_eq "model: gpt-6-luna (Admin Evaluator default, copilot)" "$(COPILOT_CLI=1 gm evaluator)"
assert_eq "model: claude-haiku-5.5 (Admin Spec check default, copilot)" "$(COPILOT_CLI=1 gm speccheck)"
assert_eq "model: opus (Admin Reviewer default, claude)" "$(COPILOT_CLI=0 gm reviewer)"            # only exactly 1 means Copilot
assert_eq "none: omit model (pi has no Model tiers pick)" "$(COCKPIT_AGENT=pi gm reviewer)"
assert_contains "$(gm bogus)" "Usage: sprint gate-model"
assert_contains "$(gm reviewerx)" "EXIT 1"                                                          # the whole role, nothing around it
assert_contains "$(gm xreviewer)" "EXIT 1"
assert_contains "$("$SPRINT" gate-model "" reviewer 2>&1 || echo "EXIT $?")" "EXIT 1"
assert_eq "Sprint t-zzzz: plan.md not found.
EXIT 1" "$("$SPRINT" gate-model t-zzzz reviewer 2>&1 || echo "EXIT $?")"

# the line gate-snapshot prints before each dispatch is the same resolution
assert_eq "gate-snapshot: dispatch canon-reviewer with model: opus (Admin Reviewer default, claude)" "$(snap reviewer)"
assert_eq "gate-snapshot: dispatch canon-evaluator with model: gpt-6-luna (Admin Evaluator default, copilot)" "$(COPILOT_CLI=1 snap evaluator)"
assert_eq "gate-snapshot: dispatch canon-spec-checker with model: sonnet (Admin Spec check default, claude)" "$(snap speccheck)"
assert_eq "" "$(snap evaluator2)"                                                                       # second-eval names its own model
# no line, and pre still succeeds, for another role or a snapshot outside a ticket folder
"$ROOT/tools/gate-snapshot.sh" pre "$t/gate-snapshot.txt" --role evaluator2 >/dev/null || fail "pre --role evaluator2 failed"
"$ROOT/tools/gate-snapshot.sh" post "$t/gate-snapshot.txt" >/dev/null
mkdir -p "$W/loose/.tickets/notes"; printf '# Plan\n' > "$W/loose/plan.md"; cp "$W/loose/plan.md" "$W/loose/.tickets/notes/"
for f in "$W/loose/gate-snapshot.txt" "$W/loose/.tickets/notes/gate-snapshot.txt"; do
  out="$("$ROOT/tools/gate-snapshot.sh" pre "$f" --role reviewer)" || fail "pre outside a ticket failed: $f"
  "$ROOT/tools/gate-snapshot.sh" post "$f" >/dev/null
  [[ "$out" != *"writes its report"* ]] || fail "t-597f: a report path printed for a file outside a ticket folder: $f"   # no ticket.md there
  [[ "$f" == */notes/* ]] && continue                                                                   # .tickets/<name> with a plan.md is a ticket
  assert_eq "" "$(grep dispatch <<<"$out" || true)"
done
# t-597f: pre with no --role (as before roles existed) still works and names no report
out="$("$ROOT/tools/gate-snapshot.sh" pre "$W/loose/gate-snapshot.txt")" || fail "t-597f: pre with no --role failed"
"$ROOT/tools/gate-snapshot.sh" post "$W/loose/gate-snapshot.txt" >/dev/null
[[ "$out" != *"writes its report"* ]] || fail "t-597f: pre with no --role printed a report path"
rm -f "$W/loose/plan.md"; mkdir -p "$W/loose/.tickets/t-ab99"
out="$("$ROOT/tools/gate-snapshot.sh" pre "$W/loose/.tickets/t-ab99/gate-snapshot.txt" --role reviewer)" || fail "pre in a folder with no plan.md failed"
"$ROOT/tools/gate-snapshot.sh" post "$W/loose/.tickets/t-ab99/gate-snapshot.txt" >/dev/null
assert_eq "" "$(grep dispatch <<<"$out" || true)"
# a failed lookup is said, not silent: gate-snapshot beside a sprint that fails
mkdir "$W/tools"; for f in "$ROOT"/tools/*; do ln -s "$f" "$W/tools/"; done
rm "$W/tools/sprint" "$W/tools/gate-snapshot.sh"; cp "$ROOT/tools/gate-snapshot.sh" "$W/tools/"
printf '#!/usr/bin/env bash\necho "registry unreadable" >&2; exit 1\n' > "$W/tools/sprint"; chmod +x "$W/tools/sprint"
out="$("$W/tools/gate-snapshot.sh" pre "$t/gate-snapshot.txt" --role reviewer | grep dispatch || true)"; "$ROOT/tools/gate-snapshot.sh" post "$t/gate-snapshot.txt" >/dev/null
assert_eq "gate-snapshot: dispatch canon-reviewer: no model line (sprint gate-model failed: registry unreadable); look it up as complete.md \"Model tier for gates\" says" "$out"

# 2. complete.md's fail-safes: a Haiku evaluator pick, a Claude pick with no Agent-tool alias, no pick, no speccheck default
reg '{"defaults":{"reviewer":{"claude":"claude-mythos-1","copilot":"gpt-6-terra"},"evaluator":{"claude":"claude-haiku-5-5","copilot":"claude-haiku-5.5"}},'"$MODELS"'}'
assert_contains "$(gm evaluator)" "none: omit model (Admin's Evaluator pick haiku is a Haiku model"
assert_contains "$(COPILOT_CLI=1 gm evaluator)" "none: omit model (Admin's Evaluator pick claude-haiku-5.5 is a Haiku model"
assert_eq "none: omit model (Admin's Reviewer pick claude-mythos-1 has no alias the Agent tool takes)" "$(gm reviewer)"
assert_eq "model: gpt-6-terra (Admin Spec check default, copilot)" "$(COPILOT_CLI=1 gm speccheck)"   # no speccheck: the reviewer pick (the loader fills it)
assert_eq "gate-snapshot: dispatch canon-evaluator: none: omit model (Admin's Evaluator pick haiku is a Haiku model; the binding evaluator never runs on Haiku outside Lite)" "$(snap evaluator)"
reg '{"defaults":{},'"$MODELS"'}'
assert_eq "none: omit model (no Admin Reviewer default for claude)" "$(gm reviewer)"
# an Agent-tool alias must be the whole pick, not a part of it
reg '{"defaults":{"reviewer":{"claude":"my-opus"},"evaluator":{"claude":"sonnet-legacy"}},"models":{"anthropic":[{"id":"my-opus"},{"id":"sonnet-legacy"}]}}'
assert_eq "none: omit model (Admin's Reviewer pick my-opus has no alias the Agent tool takes)" "$(gm reviewer)"
assert_eq "none: omit model (Admin's Evaluator pick sonnet-legacy has no alias the Agent tool takes)" "$(gm evaluator)"

# 3. the ticket's own rule wins: a Gate model line (any value), or a Lite ticket's evaluator
reg '{"defaults":{"reviewer":{"claude":"claude-opus-5-5"},"evaluator":{"claude":"claude-sonnet-5-5"}},'"$MODELS"'}'
signoff "Tier: normal | Risk: x | Gate model: haiku"
assert_eq "ticket rule: the ticket's Gate model line — complete.md \"Model tier for gates\"" "$(gm reviewer)"
signoff "Tier: normal | Risk: x | Gate model: session"
assert_eq "ticket rule: the ticket's Gate model line — complete.md \"Model tier for gates\"" "$(gm evaluator)"
signoff "Tier: normal | Risk: x"
awk 'NR==1 { print; print "demo: true"; next } 1' "$t/ticket.md" > "$t/ticket.tmp" && mv "$t/ticket.tmp" "$t/ticket.md"
assert_eq "ticket rule: Lite (demo: true) evaluator — complete.md \"Model tier for gates\"" "$(gm evaluator)"
assert_eq "model: opus (Admin Reviewer default, claude)" "$(gm reviewer)"                           # Lite changes only the evaluator

# 4. complete-checklist.md tells the agent to dispatch with canon's printed prompt, whose stderr names the model (t-63c6), inside its cap
assert_contains "$(cat "$ROOT/skills/sprint/reference/complete-checklist.md")" "stderr names the \`model\` to pass"
words="$(wc -w < "$ROOT/skills/sprint/reference/complete-checklist.md" | tr -d ' ')"
(( words <= 900 )) || fail "complete-checklist.md is $words words (cap 900)"

# 5. sprint eval-verdict: a verdict line in another shape is refused, naming the shape, and the count is unchanged
verdict() { printf 'evaluator-run-id: 1-1\n\n## Criteria\n\n| Criterion | Status |\n|---|---|\n| x | pass |\n\n%s\n' "$1" > "$t/eval-report.md"
  rc=0; out="$("$SPRINT" eval-verdict "$id" 2>&1)" || rc=$?; }
count() { sed -n 's/^eval_fail_count:[[:space:]]*//p' "$t/ticket.md"; }
verdict "fail: not yet"; assert_eq 0 "$rc"; assert_eq 1 "$(count)"
for bad in "verdict: pass — all criteria met" "**pass:** all met" "## pass" "Pass: all met"; do
  verdict "$bad"
  assert_eq 1 "$rc"
  assert_contains "$out" "must start the line with \`pass: <one-line summary>\`"
  assert_eq 1 "$(count)"
done
verdict "Everything should pass"; assert_eq 0 "$rc"; assert_eq 2 "$(count)"               # no verdict-like line: counted as before
verdict "pass: all met"; assert_eq 0 "$rc"; assert_eq 0 "$(count)"
verdict "fail: x"; assert_eq 0 "$rc"; assert_eq 1 "$(count)"
assert_contains "$(cat "$ROOT/agents/canon-evaluator.md")" "starts the line with \`pass:\` or \`fail:\`"

# t-597f: protects every close gate dispatch from a land worktree (no .tickets/ of its own: the main checkout's, t-cd06). The docs'
# relative `.tickets/<id>/gate-snapshot.txt` works there, `pre` names each role's report as an absolute path in the main checkout, and a
# report written relative to the worktree (a stray .tickets/) stops `post` and `sprint complete` with the files named.
git commit -q --allow-empty -m wt; LW="$W/land-wt"; git worktree add -q "$LW" -b "land/$id"
main_t="$(cd "$project/.tickets/$id" && pwd -P)"
for pair in reviewer:review-notes.md evaluator:eval-report.md evaluator2:eval-report-2.md speccheck:spec-review.md; do
  r="${pair%%:*}"; out="$(cd "$LW" && "$SPRINT" gate-snapshot pre ".tickets/$id/gate-snapshot.txt" --role "$r" 2>&1)" || fail "t-597f: pre --role $r from a land worktree failed: $out"
  assert_contains "$out" "the gate writes its report to $main_t/${pair#*:}"
  (cd "$LW" && "$SPRINT" gate-snapshot post ".tickets/$id/gate-snapshot.txt" >/dev/null 2>&1) || fail "t-597f: post from a land worktree failed ($r)"
done
[[ ! -e "$LW/.tickets" ]] || fail "t-597f: the snapshot was written into the worktree"
(cd "$LW" && "$SPRINT" gate-snapshot pre ".tickets/$id/gate-snapshot.txt" --role evaluator >/dev/null 2>&1)
mkdir -p "$LW/.tickets/$id"; echo stray > "$LW/.tickets/$id/eval-report.md"
rc=0; out="$(cd "$LW" && "$SPRINT" gate-snapshot post ".tickets/$id/gate-snapshot.txt" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "hides the ticket"; assert_contains "$out" ".tickets/$id/eval-report.md"
rc=0; out="$(cd "$LW" && "$SPRINT" complete 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "Sprint cannot close here"; assert_contains "$out" ".tickets/$id/eval-report.md"
rm -rf "$LW/.tickets"
# a .tickets/ there that holds no ticket the main checkout has is not this guard's (nothing to name): post goes on
mkdir -p "$LW/.tickets/t-zz99"; echo x > "$LW/.tickets/t-zz99/note.md"
(cd "$LW" && "$ROOT/tools/gate-snapshot.sh" pre "$project/.tickets/$id/gate-snapshot.txt" >/dev/null 2>&1)
out="$(cd "$LW" && "$ROOT/tools/gate-snapshot.sh" post "$project/.tickets/$id/gate-snapshot.txt" 2>&1)" || fail "t-597f: post stopped on a .tickets/ with no main ticket in it: $out"
rm -rf "$LW/.tickets"
(cd "$LW" && "$SPRINT" gate-snapshot pre ".tickets/$id/gate-snapshot.txt" >/dev/null 2>&1); (cd "$LW" && "$SPRINT" gate-snapshot post ".tickets/$id/gate-snapshot.txt" >/dev/null 2>&1) || fail "t-597f: post after the move failed"
git worktree remove --force "$LW"
# ...but an adopted worktree's own .tickets/ copy (t-3abc), on a branch that is not land/<id>, is legitimate: post goes on
AW="$W/adopted-wt"; git worktree add -q "$AW" -b "sprint/$id"; mkdir -p "$AW/.tickets"; cp -R "$project/.tickets/$id" "$AW/.tickets/"
(cd "$AW" && "$SPRINT" gate-snapshot pre ".tickets/$id/gate-snapshot.txt" --role reviewer >/dev/null 2>&1) || fail "t-597f: pre in an adopted worktree failed"
out="$(cd "$AW" && "$SPRINT" gate-snapshot post ".tickets/$id/gate-snapshot.txt" 2>&1)" || fail "t-597f: post refused an adopted worktree's own .tickets/: $out"
git worktree remove --force "$AW"
echo "sprint-gate-model: a land worktree's snapshot, report paths and stray .tickets/ guard (t-597f)"

echo "sprint-gate-model: ok"
