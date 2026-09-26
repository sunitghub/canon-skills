#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

id="$("$TKT" create "Write tests" -t task -p 1 -d "Cover the ticket lifecycle")"

[[ "$id" =~ ^t-[a-f0-9]{4}$ ]] || fail "expected ticket ID to be four hex chars, got: $id"
assert_dir_exists ".tickets/$id"
assert_file_exists ".tickets/$id/ticket.md"
assert_grep "^id: $id$" ".tickets/$id/ticket.md"
assert_grep "^status: open$" ".tickets/$id/ticket.md"
assert_grep "^type: task$" ".tickets/$id/ticket.md"
assert_grep "^priority: 1$" ".tickets/$id/ticket.md"
assert_grep "^# Write tests$" ".tickets/$id/ticket.md"

# t-354b: --skills writes an allowlisted, order-preserving, deduped skills line.
sid="$("$TKT" create "maint" -t chore --skills "context-check, dead-code-cleanup ,bogus,context-check")"
assert_grep "^skills: context-check,dead-code-cleanup$" ".tickets/$sid/ticket.md"
grep -q "bogus" ".tickets/$sid/ticket.md" && fail "tkt --skills leaked a non-allowlisted skill" || true
# ...and no --skills → no skills line.
nsid="$("$TKT" create "plain" -t task)"
grep -q "^skills:" ".tickets/$nsid/ticket.md" && fail "tkt create without --skills wrote a skills line" || true

# t-2f53: ensure_tickets_dir seeds a .tickets/.gitignore for canon's own
# per-machine runtime files (so a project that tracks .tickets/ never commits
# them). The first `tkt create` above already ensured the dir.
assert_file_exists ".tickets/.gitignore"
assert_grep "^\.cockpit-\*$" ".tickets/.gitignore"
assert_grep "^ACTIVE$" ".tickets/.gitignore"

# ...and it must never clobber a user's existing .tickets/.gitignore.
preserve_project="$(make_project)"
mkdir -p "$preserve_project/.tickets"
printf 'custom-user-rule\n' > "$preserve_project/.tickets/.gitignore"
( cd "$preserve_project" && "$TKT" create "Preserve gitignore" >/dev/null )
assert_eq "custom-user-rule" "$(cat "$preserve_project/.tickets/.gitignore")"
rm -rf "$preserve_project"

start_output="$("$TKT" start "$id")"
assert_contains "$start_output" "$id: in_progress"
assert_eq "$id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"
assert_grep "^status: in_progress$" ".tickets/$id/ticket.md"

current_output="$("$TKT" current)"
assert_contains "$current_output" "$id  in_progress  Write tests"

second_id="$("$TKT" create "Second ticket")"
"$TKT" start "$second_id" >/dev/null
assert_eq "$second_id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"
assert_grep "^status: in_progress$" ".tickets/$second_id/ticket.md"

no_flag_output="$(run_fail "$TKT" close "$second_id")"
assert_contains "$no_flag_output" "has no sprint docs"
assert_contains "$no_flag_output" "--no-sprint"
assert_grep "^status: in_progress$" ".tickets/$second_id/ticket.md"

close_output="$("$TKT" close "$second_id" --no-sprint)"
assert_contains "$close_output" "$second_id: closed"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after closing active ticket"
assert_grep "^status: closed$" ".tickets/$second_id/ticket.md"

# t-dec8: a CLI close writes a `closed:` marker (the pre-commit hook keys off a co-added
# `closed:` line to tell a legit CLI close from a hand-edited status), and reopen removes it.
assert_grep "^closed: " ".tickets/$second_id/ticket.md"
"$TKT" reopen "$second_id" >/dev/null
assert_grep "^status: open$" ".tickets/$second_id/ticket.md"
grep -qE "^closed: " ".tickets/$second_id/ticket.md" && fail "expected reopen to remove the closed: marker" || true

# A ticket with sprint docs refuses close without --no-sprint, pointing to sprint complete
sprint_id="$("$TKT" create "Ticket with sprint docs")"
mkdir -p ".tickets/$sprint_id"
: > ".tickets/$sprint_id/acceptance.md"
: > ".tickets/$sprint_id/plan.md"
sprint_docs_output="$(run_fail "$TKT" close "$sprint_id")"
assert_contains "$sprint_docs_output" "has sprint docs"
assert_contains "$sprint_docs_output" "sprint complete"
assert_grep "^status: open$" ".tickets/$sprint_id/ticket.md"

force_close_output="$("$TKT" close "$sprint_id" --no-sprint)"
assert_contains "$force_close_output" "$sprint_id: closed"
assert_grep "^status: closed$" ".tickets/$sprint_id/ticket.md"

"$TKT" start "$id" >/dev/null
assert_eq "$id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"
reopen_output="$("$TKT" reopen "$id")"
assert_contains "$reopen_output" "$id: open"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after reopening the active ticket"
assert_grep "^status: open$" ".tickets/$id/ticket.md"

missing_output="$(run_fail "$TKT" show does-not-exist)"
assert_contains "$missing_output" "Error: no ticket matching 'does-not-exist'"

mkdir -p nested/deeper
(
  cd nested/deeper
  nested_id="$("$TKT" create "Nested ticket")"
  [[ -f "../../.tickets/$nested_id/ticket.md" ]] || fail "expected nested create to use project .tickets"
)

# ── tkt gate (t-4e57): eval sets the line, full removes it, no-arg prints, bad errors ─
gate_id="$("$TKT" create "Gate mode ticket")"
assert_contains "$("$TKT" gate "$gate_id")" "$gate_id: gate=full"
assert_contains "$("$TKT" gate "$gate_id" eval)" "$gate_id: gate=eval"
assert_grep "^gate: eval$" ".tickets/$gate_id/ticket.md"
assert_contains "$("$TKT" gate "$gate_id")" "$gate_id: gate=eval"
"$TKT" gate "$gate_id" full >/dev/null
grep -q "^gate:" ".tickets/$gate_id/ticket.md" && fail "expected 'gate:' line removed after 'gate full'" || true
assert_contains "$("$TKT" gate "$gate_id")" "$gate_id: gate=full"
bad_gate_output="$(run_fail "$TKT" gate "$gate_id" bogus)"
assert_contains "$bad_gate_output" "must be 'eval' or 'full'"

# ── tkt demo (t-dfaa): on sets demo: true, off removes it, no-arg prints, bad errors ─
demo_id="$("$TKT" create "Demo mode ticket")"
grep -q "^demo:" ".tickets/$demo_id/ticket.md" && fail "expected no 'demo:' line on a fresh ticket" || true
assert_contains "$("$TKT" demo "$demo_id")" "$demo_id: demo=false"
assert_contains "$("$TKT" demo "$demo_id" on)" "$demo_id: demo=true"
assert_grep "^demo: true$" ".tickets/$demo_id/ticket.md"
assert_contains "$("$TKT" demo "$demo_id")" "$demo_id: demo=true"
"$TKT" demo "$demo_id" off >/dev/null
grep -q "^demo:" ".tickets/$demo_id/ticket.md" && fail "expected 'demo:' line removed after 'demo off'" || true
assert_contains "$("$TKT" demo "$demo_id")" "$demo_id: demo=false"
bad_demo_output="$(run_fail "$TKT" demo "$demo_id" bogus)"
assert_contains "$bad_demo_output" "must be 'on' or 'off'"
demo_usage_output="$(run_fail "$TKT" demo)"
assert_contains "$demo_usage_output" "Usage: tkt demo <id> [on|off]"

# ── tkt learn (t-0232): distill close artifacts into an UNPROMOTED candidate ──

# 1. Deviations present → an UNPROMOTED candidate with the non-delivered rows + findings.
learn_id="$("$TKT" create "Learn distill ticket")"
cat > ".tickets/$learn_id/summary.md" <<'EOF'
# Summary

| Acceptance item | Status | Notes |
|---|---|---|
| Core behavior works | delivered | ok |
| Extra polish | waived | out of scope this sprint |
| Migration path | deferred | tracked in a follow-up |
EOF
cat > ".tickets/$learn_id/eval-report.md" <<'EOF'
evaluator-run-id: test-123
# Eval Report
## Findings
1. The guard only covers case A; case B is unverified.
## Verdict
fail: one partial
EOF
learn_out="$("$TKT" learn "$learn_id")"
assert_contains "$learn_out" "wrote UNPROMOTED learnings candidate"
assert_file_exists ".tickets/$learn_id/learnings.md"
assert_grep "^status: UNPROMOTED$" ".tickets/$learn_id/learnings.md"
cand="$(cat ".tickets/$learn_id/learnings.md")"
assert_contains "$cand" "Extra polish"
assert_contains "$cand" "Migration path"
assert_contains "$cand" "case A"
# a delivered row must NOT appear as a deviation
if [[ "$cand" == *"Core behavior works"* ]]; then fail "tkt learn: delivered row leaked into the candidate"; fi
# must never write to a durable store — only the ticket folder
[[ -f critique/canon-learnings.md ]] && fail "tkt learn must not create critique/canon-learnings.md" || true

# 2. Re-run refuses to clobber; --force regenerates.
reclobber="$(run_fail "$TKT" learn "$learn_id")"
assert_contains "$reclobber" "already exists"
force_out="$("$TKT" learn "$learn_id" --force)"
assert_contains "$force_out" "wrote UNPROMOTED learnings candidate"

# 3. Clean sprint (all delivered, no findings) → writes nothing, says so.
clean_id="$("$TKT" create "Clean sprint ticket")"
cat > ".tickets/$clean_id/summary.md" <<'EOF'
# Summary

| Acceptance item | Status | Notes |
|---|---|---|
| Everything shipped | delivered | ok |
EOF
cat > ".tickets/$clean_id/eval-report.md" <<'EOF'
evaluator-run-id: test-456
# Eval Report
## Findings
No findings.
## Verdict
pass: all good
EOF
clean_out="$("$TKT" learn "$clean_id")"
assert_contains "$clean_out" "nothing to distill"
[[ -f ".tickets/$clean_id/learnings.md" ]] && fail "tkt learn wrote a candidate for a clean sprint" || true

# 3b. (t-de16) A review-notes.md in the per-concern shape whose five lines are all
#     "none — checked …" is a clean pass: nothing to distill, the none lines are not findings.
shape_id="$("$TKT" create "Per-concern all none")"
cat > ".tickets/$shape_id/summary.md" <<'EOF'
# Summary

| Acceptance item | Status | Notes |
|---|---|---|
| Everything shipped | delivered | ok |
EOF
cat > ".tickets/$shape_id/eval-report.md" <<'EOF'
evaluator-run-id: test-de16
# Eval Report
## Findings
No findings.
## Verdict
pass: all good
EOF
cat > ".tickets/$shape_id/review-notes.md" <<'EOF'
# Review Notes
Model: test-model
Changed files: tools/tkt, tests/tkt.sh
## Findings
Scope creep: none — checked plan.md Files vs diff, plan.md:20
Visual regression: none — checked no UI files changed, tools/tkt:1
Dead code: none — checked no orphaned code, tools/tkt:730
Unnecessary complexity: none — checked one added rule, tools/tkt:731
Standards violations: none — checked efficiency.md, tools/tkt:731
## Verdict
YES
EOF
shape_out="$("$TKT" learn "$shape_id")"
assert_contains "$shape_out" "nothing to distill"
[[ -f ".tickets/$shape_id/learnings.md" ]] && fail "tkt learn treated per-concern 'none — checked' lines as findings" || true

# 3c. (t-de16) One real finding among four none lines: the candidate quotes only the finding.
shape2_id="$("$TKT" create "Per-concern one finding")"
cp ".tickets/$shape_id/summary.md" ".tickets/$shape2_id/summary.md"
cp ".tickets/$shape_id/eval-report.md" ".tickets/$shape2_id/eval-report.md"
sed 's|^Dead code: none.*|Dead code: tools/tkt:730 — orphaned awk variable [severity: low · confidence: med]|; s|^## Verdict|## Verdict|; s|^YES$|NO|' ".tickets/$shape_id/review-notes.md" > ".tickets/$shape2_id/review-notes.md"
"$TKT" learn "$shape2_id" >/dev/null
shape2_cand="$(cat ".tickets/$shape2_id/learnings.md")"
assert_contains "$shape2_cand" "orphaned awk variable"
if [[ "$shape2_cand" == *"none — checked"* ]]; then fail "tkt learn: a 'none — checked' line leaked into the candidate"; fi

# 4. Usage error with no id.
learn_usage="$(run_fail "$TKT" learn)"
assert_contains "$learn_usage" "Usage: tkt learn <id> [--force]"

# 5. (t-13b3) Reviewer-only findings: clean summary + evaluator pass, but the advisory reviewer
#    caught a defect → a candidate is still written and quotes it.
rev_id="$("$TKT" create "Reviewer only findings")"
cat > ".tickets/$rev_id/summary.md" <<'EOF'
# Summary

| Acceptance item | Status | Notes |
|---|---|---|
| Everything shipped | delivered | ok |
EOF
cat > ".tickets/$rev_id/eval-report.md" <<'EOF'
evaluator-run-id: test-789
# Eval Report
## Findings
No findings.
## Verdict
pass: all good
EOF
cat > ".tickets/$rev_id/review-notes.md" <<'EOF'
# Review Notes

## Findings

- `app.html:2807` — esc() does not escape a double quote, so title="..." is injectable. [severity: med · confidence: high]
- `spec.js:6432` — the hostile-name test never tries attribute breakout. [severity: low · confidence: high]

## Verdict

NO
EOF
rev_out="$("$TKT" learn "$rev_id")"
assert_contains "$rev_out" "wrote UNPROMOTED learnings candidate"
rev_cand="$(cat ".tickets/$rev_id/learnings.md")"
assert_contains "$rev_cand" "## Reviewer findings"
assert_contains "$rev_cand" "esc() does not escape a double quote"
assert_contains "$rev_cand" "never tries attribute breakout"
assert_contains "$rev_cand" "Advisory reviewer verdict: NO"
assert_contains "$rev_cand" "Lesson from the reviewer findings above"

# 6. Reviewer "No findings." + otherwise clean sprint → still writes nothing.
revclean_id="$("$TKT" create "Reviewer clean")"
cp ".tickets/$clean_id/summary.md" ".tickets/$revclean_id/summary.md"
cp ".tickets/$clean_id/eval-report.md" ".tickets/$revclean_id/eval-report.md"
printf '# Review Notes\n\n## Findings\n\nNo findings.\n\n## Verdict\n\nYES\n' > ".tickets/$revclean_id/review-notes.md"
revclean_out="$("$TKT" learn "$revclean_id")"
assert_contains "$revclean_out" "nothing to distill"
[[ -f ".tickets/$revclean_id/learnings.md" ]] && fail "tkt learn wrote a candidate for a reviewer-clean sprint" || true

# 7. Malformed review-notes.md never errors or emits garbage: CRLF, empty, no bullets, a 5000-char line.
mal_id="$("$TKT" create "Malformed review notes")"
cp ".tickets/$rev_id/summary.md" ".tickets/$mal_id/summary.md"
cp ".tickets/$rev_id/eval-report.md" ".tickets/$mal_id/eval-report.md"
: > ".tickets/$mal_id/review-notes.md"
mal_out="$("$TKT" learn "$mal_id")"
assert_contains "$mal_out" "nothing to distill"
printf '# R\n\n## Findings\n\n\n## Verdict\n\nNO\n' > ".tickets/$mal_id/review-notes.md"
mal_out="$("$TKT" learn "$mal_id")"
assert_contains "$mal_out" "nothing to distill"
printf '# R\r\n\r\n## Findings\r\n\r\n- crlf finding one [severity: low]\r\n\r\n## Verdict\r\n\r\nNO\r\n' > ".tickets/$mal_id/review-notes.md"
"$TKT" learn "$mal_id" >/dev/null
mal_cand="$(cat ".tickets/$mal_id/learnings.md")"
assert_contains "$mal_cand" "crlf finding one [severity: low]"
assert_contains "$mal_cand" "Advisory reviewer verdict: NO."
if [[ "$mal_cand" == *$'\r'* ]]; then fail "tkt learn: CR leaked into the candidate"; fi
# 8. Real reviewer reports rarely use "- " bullets: review.md's template is one `file:line — issue` per line,
#    and headings carry suffixes. Every shape must still reach the candidate (t-13b3 reviewer finding).
for shape in bare numbered star; do
  shape_id="$("$TKT" create "Shape $shape")"
  cp ".tickets/$rev_id/summary.md" ".tickets/$shape_id/summary.md"
  cp ".tickets/$rev_id/eval-report.md" ".tickets/$shape_id/eval-report.md"
  case "$shape" in
    bare)     body='src/a.go:10 — first bare finding [severity: med]\n\nsrc/b.go:20 — second bare finding' ;;
    numbered) body='1. first numbered finding\n2. second numbered finding' ;;
    star)     body='* first star finding\n* second star finding' ;;
  esac
  printf '# R\n\n## Findings (advisory)\n\n%b\n\n## Verdict: NO — see above\n' "$body" > ".tickets/$shape_id/review-notes.md"
  "$TKT" learn "$shape_id" >/dev/null
  shape_cand="$(cat ".tickets/$shape_id/learnings.md")"
  assert_contains "$shape_cand" "first $shape finding"
  assert_contains "$shape_cand" "second $shape finding"
  assert_contains "$shape_cand" "Advisory reviewer verdict: NO — see above."
done

long_line="$(head -c 5000 /dev/zero | tr '\0' 'x')"
printf '## Findings\n\n- %s\n\n## Verdict\n\nNO\n' "$long_line" > ".tickets/$mal_id/review-notes.md"
"$TKT" learn "$mal_id" --force >/dev/null
assert_contains "$(cat ".tickets/$mal_id/learnings.md")" "(see review-notes.md)"
if grep -q "$(head -c 500 /dev/zero | tr '\0' 'x')" ".tickets/$mal_id/learnings.md"; then fail "tkt learn: an over-long reviewer line was not capped"; fi

# ── t-01a4: current_id() is per-worktree, not repo-wide ────────────────────

wt_project="$(make_project)"
(cd "$wt_project" && git commit -q --allow-empty -m init)

# Backward-compat baseline: single in_progress ticket, main checkout only —
# must resolve exactly as before this change (HIGH blast-radius mitigation).
(
  cd "$wt_project"
  solo_id="$("$TKT" create "Solo ticket" -t task)"
  "$TKT" start "$solo_id" >/dev/null
  cur_out="$("$TKT" current)"
  assert_contains "$cur_out" "$solo_id"
  "$TKT" close "$solo_id" --no-sprint >/dev/null
)

# Two real worktrees, one in_progress ticket bound to each (via .cockpit-cwd,
# same as the daemon/cmd_start would write) — tkt current from EACH worktree
# resolves to ITS OWN ticket independently, no "multiple in-progress" error.
(
  cd "$wt_project"
  wt_a_id="$("$TKT" create "Worktree A ticket" -t task)"
  "$TKT" start "$wt_a_id" >/dev/null
  printf '%s\n' "$(cd "$wt_project" && pwd -P)" > ".tickets/$wt_a_id/.cockpit-cwd"

  worktree_b="$wt_project-worktrees/feat-b"
  mkdir -p "$(dirname "$worktree_b")"
  git worktree add -q -b "sprint/feat-b" "$worktree_b" >/dev/null 2>&1

  wt_b_id="$("$TKT" create "Worktree B ticket" -t task)"
  "$TKT" start "$wt_b_id" >/dev/null
  printf '%s\n' "$(cd "$worktree_b" && pwd -P)" > ".tickets/$wt_b_id/.cockpit-cwd"

  # From the main checkout: resolves to A, not B, not an error.
  main_cur="$("$TKT" current)"
  assert_contains "$main_cur" "$wt_a_id"

  # From worktree B: resolves to B, not A, not an error — the whole point.
  wt_b_cur="$(cd "$worktree_b" && "$TKT" current)"
  assert_contains "$wt_b_cur" "$wt_b_id"

  git worktree remove -f "$worktree_b" >/dev/null 2>&1 || true
  "$TKT" close "$wt_a_id" --no-sprint >/dev/null
  "$TKT" close "$wt_b_id" --no-sprint >/dev/null
)

# Two tickets in_progress in the SAME worktree stays a genuine, hard error —
# never silently resolved to either one.
(
  cd "$wt_project"
  same_a="$("$TKT" create "Same-worktree A" -t task)"
  same_b="$("$TKT" create "Same-worktree B" -t task)"
  "$TKT" start "$same_a" >/dev/null
  here="$(pwd -P)"
  printf '%s\n' "$here" > ".tickets/$same_a/.cockpit-cwd"
  # Force B in_progress too, bypassing the gate (simulating the anomaly
  # directly, since the gate itself should normally prevent this).
  sed -i.bak 's/^status: open$/status: in_progress/' ".tickets/$same_b/ticket.md" && rm -f ".tickets/$same_b/ticket.md.bak"
  printf '%s\n' "$here" > ".tickets/$same_b/.cockpit-cwd"

  set +e
  err_out="$("$TKT" current 2>&1)"
  err_rc=$?
  set -e
  [[ "$err_rc" -eq 2 ]] || fail "expected rc 2 for same-worktree double in_progress, got $err_rc"
  assert_contains "$err_out" "multiple in-progress tickets bound to this worktree"
)

rm -rf "$wt_project" "$wt_project-worktrees"

# ── t-01a4 (review finding): bare `tkt start` also binds a worktree ────────
# Distinct from the "two worktrees" case above, which starts BOTH tickets via
# tkt start too but never isolated this specific gap: a ticket started with
# no sprint/daemon involvement at all must still be visible to `tkt current`
# from its own worktree, not silently invisible there.

bare_project="$(make_project)"
(cd "$bare_project" && git commit -q --allow-empty -m init)
(
  cd "$bare_project"
  bare_wt="$bare_project-worktrees/bare"
  mkdir -p "$(dirname "$bare_wt")"
  git worktree add -q -b sprint/bare "$bare_wt" >/dev/null

  cd "$bare_wt"
  bare_id="$("$TKT" create "Bare start" -t task)"
  "$TKT" start "$bare_id" >/dev/null

  assert_file_exists "$bare_project/.tickets/$bare_id/.cockpit-cwd"
  assert_eq "$(pwd -P)" "$(cat "$bare_project/.tickets/$bare_id/.cockpit-cwd")"
  assert_contains "$("$TKT" current)" "$bare_id"

  # From the main checkout, this worktree-bound ticket must NOT show as active.
  main_cur_rc=0
  (cd "$bare_project" && "$TKT" current >/dev/null 2>&1) || main_cur_rc=$?
  [[ "$main_cur_rc" -eq 1 ]] || fail "expected main checkout to see no active ticket, got rc $main_cur_rc"

  "$TKT" close "$bare_id" --no-sprint >/dev/null
  cd "$bare_project"
  git worktree remove -f "$bare_wt" >/dev/null 2>&1 || true
)
rm -rf "$bare_project" "$bare_project-worktrees"
