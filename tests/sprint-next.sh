#!/usr/bin/env bash
# sprint-next — `sprint next <id>` prints the ticket's one next pipeline step and the earlier steps passed over (t-2bfe), through the
# close (t-a4e8: the wrapup rows, the reviewer, the full-suite stamp from evidence.sh's verdict).
# Protects the shipped `sprint next` command (start-checklist.md step 9) and its fail-loud paths: a pipeline the reader refuses and a
# canon-go with no walk exit 2 and name the fix, never a next line.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

project="$(make_project)"
stub="$(mktemp -d)"
trap 'rm -rf "$project" "$stub"' EXIT
cd "$project"

id="$("$SPRINT" start "Walk me" | awk '/Sprint started:/ { print $3 }')"
plan=".tickets/$id/plan.md"
printf '# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved\n\n## Approach\nDo it.\n' > "$plan"
then_line="then: code-simplifier (gate) — no code-simplifier row: run it, then sprint wrapup-row $id code-simplifier ran|skipped with its evidence (complete-checklist.md step 1)"

# 1. a fresh ticket: the spec check is next, its note names this ticket
out="$("$SPRINT" next "$id")"
assert_eq "next: spec-check (agent) — the spec check has not run: dispatch canon-spec-checker with sprint gate-prompt $id speccheck before the brief (start-checklist.md step 9)" "$out"

# 2. the verdict is written: approval is next
printf '# Spec check: %s\n\n## Verdict\nREADY — no gap\n' "$id" > ".tickets/$id/spec-review.md"
out="$("$SPRINT" next "$id")"
assert_eq "next: approve-plan (you) — show the person the brief and wait for their explicit approval, then run sprint approve $id (start-checklist.md step 11)" "$out"

# 3. a ticked box is not approval; the pin is
sed -i.bak 's/- \[ \] Plan approved/- [x] Plan approved/' "$plan"; rm -f "$plan.bak"
assert_contains "$("$SPRINT" next "$id")" "next: approve-plan (you)"
"$SPRINT" approve "$id" >/dev/null
assert_eq "next: build (step) — -
$then_line" "$("$SPRINT" next "$id")"

# 4. approved earlier with the spec check gone: the build is next, after a missed line
rm ".tickets/$id/spec-review.md"
out="$("$SPRINT" next "$id")"
assert_contains "$out" "missed: spec-check — the spec check has not run"
assert_contains "$out" "next: build (step)"

# 4b. t-a4e8: the close. A wrapup row moves next past the build; with no test-sh.log evidence.sh is not run (this repo has no commit
# yet, so a run would fail), with one it is, and its failure is exit 2, never a next line
spec_verdict ".tickets/$id"
"$SPRINT" wrapup-row "$id" code-simplifier ran "fixture" >/dev/null
assert_eq "next: code-reviewer (gate) — no code-reviewer row: run it, then sprint wrapup-row $id code-reviewer ran|skipped with its evidence (complete-checklist.md step 1)" "$("$SPRINT" next "$id")"
mkdir -p ".tickets/$id/evidence"; printf 'HEAD 0000000 2026-11-25T00:00:00Z\nexit 0\n' > ".tickets/$id/evidence/test-sh.log"
set +e; out="$("$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "evidence.sh check could not read the evidence"; ! grep -q '^next:' <<< "$out" || fail "a failed evidence check printed a next line: $out"
rm ".tickets/$id/evidence/test-sh.log"
for g in code-reviewer doc-audit skill-eval break-it security-review mutation-test; do "$SPRINT" wrapup-row "$id" "$g" ran "fixture" >/dev/null; done
printf '# Review Notes\n\n## Verdict\nYES — fixture\n' > ".tickets/$id/review-notes.md"
assert_contains "$("$SPRINT" next "$id")" "next: test-stamp (step) — no fresh full-suite log"
git commit -q --allow-empty -m init
"$SPRINT" evidence stamp "$id" test-sh -- true >/dev/null 2>&1
assert_eq "next: eval (agent) — no eval-report.md verdict: dispatch canon-evaluator with sprint gate-prompt $id evaluator (complete-checklist.md step 3)" "$("$SPRINT" next "$id")"
echo later > later.txt; git add later.txt; git commit -q -m later   # a tracked change after the stamp: stale
out="$("$SPRINT" next "$id")"
assert_contains "$out" "next: test-stamp (step)"
# the one predicate for an ok log (check-evidence's `ok` and the walk's --evidence): fresh with exit 0, or covered
eval "$(sed -n '/^_evidence_ok()/,/^}/p' "$SPRINT")"
_evidence_ok "fresh test-sh.log exit=0 (HEAD abc1234 = graded)" || fail "a fresh exit-0 log is not ok"
_evidence_ok "covered test-sh.log exit=1 (HEAD abc1234)" || fail "a covered log is not ok"
! _evidence_ok "fresh test-sh.log exit=1 (HEAD abc1234)" || fail "a failing fresh log is ok"
! _evidence_ok "stale test-sh.log exit=0 (HEAD abc1234)" || fail "a stale log is ok"
[[ "$(grep -c '_evidence_ok "\$line"' "$SPRINT")" == 2 ]] || fail "check-evidence and the walk must share _evidence_ok"

# 4c. t-f8e9: a land worktree (no .tickets/ of its own, the main checkout holds the ticket): a test-sh stamped at its HEAD, which
# main does not contain, is fresh there, so the walk reads it from the caller's checkout, not the main one
(
  git worktree add -q "$stub/wt" -b land/x
  cd "$stub/wt"
  echo wt > wt.txt; git add wt.txt; git commit -q -m wt
  "$SPRINT" evidence stamp "$id" test-sh -- true >/dev/null 2>&1 || fail "the test-sh stamp in the worktree failed"
  out="$("$SPRINT" next "$id")"
  assert_eq "next: eval (agent) — no eval-report.md verdict: dispatch canon-evaluator with sprint gate-prompt $id evaluator (complete-checklist.md step 3)" "$out"
)

# 5. a pipeline the reader refuses: exit 2 naming the file, no next line
mkdir -p canon-config; printf 'extends: canon-default\noff: [nope]\n' > canon-config/pipeline.yaml
set +e; out="$("$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "unknown node 'nope'"; ! grep -q '^next:' <<< "$out" || fail "a refused pipeline printed a next line: $out"
# t-2bfe C2: a project file cannot set an assertion
printf 'extends: canon-default\nproduces: spec.verdict\n' > canon-config/pipeline.yaml
set +e; out="$("$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "canon-config/pipeline.yaml: line 2"
rm -rf canon-config

# 6. a canon-go with no walk (an older install): exit 2 naming canon update, the binary never asked to walk
printf '#!/usr/bin/env bash\n[[ "$1" == --help ]] && { echo "usage: canon-go validate <ticket dir | artifact file>"; exit 0; }\ntouch "%s/called"\n' "$stub" > "$stub/canon-go"
chmod +x "$stub/canon-go"
set +e; out="$(SPRINT_CHECK_BIN="$stub/canon-go" "$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "has no walk (run canon update)"
[[ ! -e "$stub/called" ]] || fail "an older canon-go was asked to walk"

# 7. usage
set +e; out="$("$SPRINT" next 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "usage: sprint next <ticket-id>"
set +e; out="$("$SPRINT" next t-zzzz 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "no ticket folder .tickets/t-zzzz"

echo "sprint-next: ok"
