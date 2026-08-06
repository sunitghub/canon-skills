#!/usr/bin/env bash
# sprint-headless — covers the deterministic, free-to-run parts of the
# headless CI entry point (t-c368): pre-flight guard rails and invocation-
# error handling. Deliberately excludes real `claude -p` dispatch (real
# reviewer/evaluator/security-review subagents) — that costs real API money
# on every run and was instead verified live, once, this session (t-c368
# summary.md/research.md record the real end-to-end and fail-case results).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

SPRINT_HEADLESS="$ROOT/tools/sprint-headless"

WORK="$(mktemp -d)"
FAKE_WIN_EXE="$ROOT/tools/sprint-headless-json-win.exe"
BACKED_UP_WIN_EXE=0
# Trap-guaranteed, not just sequential cleanup: an assertion failure
# (fail()/assert_contains exit on the spot under set -e) mid-mutation must
# not leave the real, git-tracked win.exe corrupted in the working tree.
# Also called directly right after the mutating test below, on the success
# path, so the real binary isn't left swapped for the rest of the run.
restore_win_exe_stub() {
  if [[ "$BACKED_UP_WIN_EXE" -eq 1 && -f "$FAKE_WIN_EXE.orig-test-backup" ]]; then
    mv -f "$FAKE_WIN_EXE.orig-test-backup" "$FAKE_WIN_EXE"
  elif [[ "$BACKED_UP_WIN_EXE" -eq 2 ]]; then
    rm -f "$FAKE_WIN_EXE"
  fi
}
cleanup() {
  rm -rf "$WORK"
  restore_win_exe_stub
}
trap cleanup EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email t@t.com
git -C "$WORK" config user.name t
echo hello > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" commit -q -m init
# Deterministic branch name with no `main`/`origin/main`, so the base-ref default
# resolution (origin/main → main → error) is predictable across runners; case 15
# creates those refs explicitly when it needs them.
git -C "$WORK" branch -M work

seed_ticket() {
  local id="$1"
  mkdir -p "$WORK/.tickets/$id"
  cat > "$WORK/.tickets/$id/ticket.md" <<EOF
---
id: $id
status: open
type: task
priority: 2
created: 2026-01-01T00:00:00Z
---
# fixture
EOF
  cat > "$WORK/.tickets/$id/plan.md" <<'EOF'
# Plan
## Sign-off
Tier: trivial | Risk: fixture
- [ ] Plan approved — proceed to implementation
## Approach
fixture
## Files
- none
## Decisions
- none
EOF
  cat > "$WORK/.tickets/$id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] fixture
## Test Plan
- [x] fixture
## QA
- [x] Tested locally
EOF
}

# ── 0. Invalid ticket ID / base-ref rejected before any path or prompt use ──

out="$(cd "$WORK" && run_fail "$SPRINT_HEADLESS" 't-aaaa; rm -rf /tmp/x' --base-ref HEAD)"
assert_contains "$out" "not a valid ticket ID"

seed_ticket t-aaaa
out="$(cd "$WORK" && run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref 'main; rm -rf /tmp/x')"
assert_contains "$out" "not a valid base ref"

# ── 1. Not CI-eligible ───────────────────────────────────────────────────
out="$(cd "$WORK" && run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD)"
assert_contains "$out" "not CI-eligible"

# ── 2. CI-eligible but docs not committed/staged ────────────────────────
# Hand-edit ci: true directly rather than `tkt ci on` (t-4238: that command
# now auto-commits the docs) so this guard rail still gets exercised for a
# ticket that was made ci:true some other way (e.g. a hand-edited ticket.md,
# or a repo where the auto-commit failed for some reason).

sed -i.bak 's/^type: task$/type: task\nci: true/' "$WORK/.tickets/t-aaaa/ticket.md"
rm -f "$WORK/.tickets/t-aaaa/ticket.md.bak"
out="$(cd "$WORK" && run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD)"
assert_contains "$out" "aren't committed"

# ── 2b. `tkt ci on` auto-commits the docs (t-4238) ──────────────────────

seed_ticket t-cmt1
(cd "$WORK" && "$ROOT/tools/tkt" ci t-cmt1 on >/dev/null)
if ! git -C "$WORK" ls-files --error-unmatch .tickets/t-cmt1/plan.md .tickets/t-cmt1/acceptance.md >/dev/null 2>&1; then
  fail "sprint-headless: FAIL — 'tkt ci on' did not commit t-cmt1's docs automatically"
fi
if ! git -C "$WORK" diff --quiet HEAD -- .tickets/t-cmt1/; then
  fail "sprint-headless: FAIL — t-cmt1's docs are tracked but have uncommitted changes after 'tkt ci on'"
fi
# Running it again must be a no-op, not an empty commit or an error.
before="$(git -C "$WORK" rev-parse HEAD)"
(cd "$WORK" && "$ROOT/tools/tkt" ci t-cmt1 on >/dev/null)
after="$(git -C "$WORK" rev-parse HEAD)"
[[ "$before" == "$after" ]] || fail "sprint-headless: FAIL — repeat 'tkt ci on' created an unnecessary commit"

# `tkt ci off` must not touch git.
before="$(git -C "$WORK" rev-parse HEAD)"
(cd "$WORK" && "$ROOT/tools/tkt" ci t-cmt1 off >/dev/null)
after="$(git -C "$WORK" rev-parse HEAD)"
[[ "$before" == "$after" ]] || fail "sprint-headless: FAIL — 'tkt ci off' created a commit; it should not touch git"

# ── 3. Staged but plan not approved ─────────────────────────────────────

(cd "$WORK" && git add -f ".tickets/t-aaaa/")
out="$(cd "$WORK" && run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD)"
assert_contains "$out" "Plan approved"

# ── 4. Approved, no --base-ref, and no default resolves (t-54e5) ────────
# With no --base-ref/$GITHUB_BASE_REF the tools default to origin/main → main;
# WORK has neither (branch is `work`, no remote), so it errors clearly instead.

sed -i.bak 's/- \[ \] Plan approved/- [x] Plan approved/' "$WORK/.tickets/t-aaaa/plan.md"
rm -f "$WORK/.tickets/t-aaaa/plan.md.bak"
(cd "$WORK" && git add -f ".tickets/t-aaaa/")
out="$(cd "$WORK" && GITHUB_BASE_REF= run_fail "$SPRINT_HEADLESS" t-aaaa)"
assert_contains "$out" "could not resolve a default base ref"

# ── 5. All guard rails pass; claude -p invocation itself fails ─────────

# Minimal canon-repo-layout skills dir so the layout-detection guard (added
# for consumer-project support) passes before reaching the claude stub below.
mkdir -p "$WORK/skills/sprint"

STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"result","is_error":true,"api_error_status":429,"result":"Rate limit exceeded","terminal_reason":"api_error"}'
exit 1
EOF
chmod +x "$STUB_DIR/claude"

out="$(cd "$WORK" && PATH="$STUB_DIR:$PATH" run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD)"
assert_contains "$out" "invocation failed"

# ── 6. Consumer-project layout (.claude/skills/sprint, no top-level skills/) ─

rmdir "$WORK/skills/sprint" "$WORK/skills" 2>/dev/null || true
mkdir -p "$WORK/.claude/skills/sprint"
out="$(cd "$WORK" && PATH="$STUB_DIR:$PATH" run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD)"
assert_contains "$out" "invocation failed"
rm -rf "$WORK/.claude/skills"

# ── 7. Neither layout present ────────────────────────────────────────────

out="$(cd "$WORK" && PATH="$STUB_DIR:$PATH" run_fail "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD)"
assert_contains "$out" "no sprint/wrapup skill docs found"

rm -rf "$STUB_DIR"

# ── 8. Well-formed delimited response: correct content, no section-swap ────

mkdir -p "$WORK/skills/sprint"
rm -f "$WORK/.tickets/t-aaaa/review-notes.md" "$WORK/.tickets/t-aaaa/eval-report.md"

STUB_OK_DIR="$(mktemp -d)"
cat > "$STUB_OK_DIR/claude" <<'EOF'
#!/usr/bin/env bash
python3 -c '
import json
result = """Summary text.

@@@CANON_HEADLESS_REPORT:reviewer@@@
# Review Notes
Verdict: YES
@@@CANON_HEADLESS_REPORT:/reviewer@@@

@@@CANON_HEADLESS_REPORT:evaluator@@@
# Eval Report
Verdict: pass: all good
@@@CANON_HEADLESS_REPORT:/evaluator@@@

HEADLESS_VERDICT: PASS"""
print(json.dumps({"type": "result", "is_error": False, "session_id": "stub-ok", "result": result}))
'
EOF
chmod +x "$STUB_OK_DIR/claude"

(cd "$WORK" && PATH="$STUB_OK_DIR:$PATH" run_ok "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD >/dev/null)

review_notes="$(cat "$WORK/.tickets/t-aaaa/review-notes.md")"
eval_report="$(cat "$WORK/.tickets/t-aaaa/eval-report.md")"
assert_contains "$review_notes" "Verdict: YES"
assert_contains "$eval_report" "Verdict: pass: all good"
# Section-swap guard: each file must contain only its own gate's content.
if [[ "$review_notes" == *"Eval Report"* ]]; then fail "review-notes.md contains evaluator content — section swap"; fi
if [[ "$eval_report" == *"Review Notes"* ]]; then fail "eval-report.md contains reviewer content — section swap"; fi

# ── 9. Malformed delimiter (missing evaluator end marker): fail-open ───────

rm -f "$WORK/.tickets/t-aaaa/review-notes.md" "$WORK/.tickets/t-aaaa/eval-report.md"

STUB_BAD_DIR="$(mktemp -d)"
cat > "$STUB_BAD_DIR/claude" <<'EOF'
#!/usr/bin/env bash
python3 -c '
import json
result = """Summary text.

@@@CANON_HEADLESS_REPORT:reviewer@@@
# Review Notes
Verdict: YES
@@@CANON_HEADLESS_REPORT:/reviewer@@@

@@@CANON_HEADLESS_REPORT:evaluator@@@
# Eval Report
Verdict: pass: all good

HEADLESS_VERDICT: PASS"""
print(json.dumps({"type": "result", "is_error": False, "session_id": "stub-bad", "result": result}))
'
EOF
chmod +x "$STUB_BAD_DIR/claude"

set +e
err="$(cd "$WORK" && PATH="$STUB_BAD_DIR:$PATH" "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD 2>&1 >/dev/null)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "expected exit 0 (HEADLESS_VERDICT: PASS unaffected by extraction failure), got $rc"
assert_contains "$err" "could not extract the evaluator's report"
[[ -f "$WORK/.tickets/t-aaaa/review-notes.md" ]] || fail "review-notes.md should still be written (its markers were well-formed)"
[[ -f "$WORK/.tickets/t-aaaa/eval-report.md" ]] && fail "eval-report.md should NOT be written (its end marker was missing)"

# ── 10. GITHUB_STEP_SUMMARY receives the full result text when set ─────────

SUMMARY_FILE="$(mktemp)"
(cd "$WORK" && PATH="$STUB_OK_DIR:$PATH" GITHUB_STEP_SUMMARY="$SUMMARY_FILE" run_ok "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD >/dev/null)
assert_contains "$(cat "$SUMMARY_FILE")" "HEADLESS_VERDICT: PASS"
assert_contains "$(cat "$SUMMARY_FILE")" "Verdict: YES"
rm -f "$SUMMARY_FILE"

# ── 11. Windows JSON-parse binary present but not on Windows: never exec'd ──
# uname on this test runner is never MINGW/MSYS/CYGWIN, so the IS_WINDOWS
# gate in sprint-headless must keep using python3 and never attempt to run
# the checked-in Windows PE binary — a non-executable stub in its place
# proves it: if sprint-headless ever tried to exec it, this would hard-fail
# instead of the well-formed-response path succeeding as in case 8.
# BACKED_UP_WIN_EXE/FAKE_WIN_EXE are declared at the top of this file so
# cleanup()'s EXIT trap can restore the real binary even if an assertion
# below fails mid-test (set -e exits immediately, skipping any restore
# written as plain sequential code after it).

rm -f "$WORK/.tickets/t-aaaa/review-notes.md" "$WORK/.tickets/t-aaaa/eval-report.md"
if [[ -f "$FAKE_WIN_EXE" ]]; then
  cp "$FAKE_WIN_EXE" "$FAKE_WIN_EXE.orig-test-backup"
  BACKED_UP_WIN_EXE=1
else
  BACKED_UP_WIN_EXE=2
fi
printf 'not a real executable' > "$FAKE_WIN_EXE"

(cd "$WORK" && PATH="$STUB_OK_DIR:$PATH" run_ok "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD >/dev/null)
review_notes="$(cat "$WORK/.tickets/t-aaaa/review-notes.md")"
assert_contains "$review_notes" "Verdict: YES"

restore_win_exe_stub

# ── 12. Adversarial content through awk extract_report: no injection, no mangling ─

rm -f "$WORK/.tickets/t-aaaa/review-notes.md" "$WORK/.tickets/t-aaaa/eval-report.md"

STUB_ADV_DIR="$(mktemp -d)"
cat > "$STUB_ADV_DIR/claude" <<'EOF'
#!/usr/bin/env bash
python3 -c '
import json
result = """Summary text.

@@@CANON_HEADLESS_REPORT:reviewer@@@
# Review Notes
Verdict: YES
Adversarial content: "quoted", `backticked`, $HOME, and a \\backslash\\ pair.
@@@CANON_HEADLESS_REPORT:/reviewer@@@

@@@CANON_HEADLESS_REPORT:evaluator@@@
# Eval Report
Verdict: pass: all good
@@@CANON_HEADLESS_REPORT:/evaluator@@@

HEADLESS_VERDICT: PASS"""
print(json.dumps({"type": "result", "is_error": False, "session_id": "stub-adv", "result": result}))
'
EOF
chmod +x "$STUB_ADV_DIR/claude"

(cd "$WORK" && PATH="$STUB_ADV_DIR:$PATH" run_ok "$SPRINT_HEADLESS" t-aaaa --base-ref HEAD >/dev/null)
review_notes="$(cat "$WORK/.tickets/t-aaaa/review-notes.md")"
assert_contains "$review_notes" 'Adversarial content: "quoted", `backticked`, $HOME, and a \backslash\ pair.'
rm -rf "$STUB_ADV_DIR"

# ── 13. Tier: bugfix (t-2abb) — eval-only headless: 2 gates, reviewer skipped ──
# A committed Tier: bugfix must make the orchestrator prompt dispatch only evaluator +
# security-review (reviewer skipped), persist eval-report.md from an evaluator-only relay,
# create no review-notes.md, and emit no reviewer-extract warning.
mkdir -p "$WORK/skills/sprint"
seed_ticket t-bugf
(cd "$WORK" && "$ROOT/tools/tkt" ci t-bugf on >/dev/null)
sed -i.bak 's/Tier: trivial | Risk: fixture/Tier: bugfix | Risk: single logic file + covering test/' "$WORK/.tickets/t-bugf/plan.md"
sed -i.bak 's/- \[ \] Plan approved/- [x] Plan approved/' "$WORK/.tickets/t-bugf/plan.md"
rm -f "$WORK/.tickets/t-bugf/plan.md.bak"
(cd "$WORK" && git add -f ".tickets/t-bugf/" && git commit -q -m "seed t-bugf bugfix")

PROMPT_CAPTURE="$(mktemp)"
STUB_BUGFIX_DIR="$(mktemp -d)"
cat > "$STUB_BUGFIX_DIR/claude" <<EOF
#!/usr/bin/env bash
# capture the orchestrator prompt (arg after -p) for assertion
printf '%s' "\$2" > "$PROMPT_CAPTURE"
python3 -c '
import json
result = """Summary.

@@@CANON_HEADLESS_REPORT:evaluator@@@
# Eval Report
Verdict: pass: bugfix verified
@@@CANON_HEADLESS_REPORT:/evaluator@@@

HEADLESS_VERDICT: PASS"""
print(json.dumps({"type":"result","is_error":False,"session_id":"stub-bugfix","result":result}))
'
EOF
chmod +x "$STUB_BUGFIX_DIR/claude"

set +e
bugfix_err="$(cd "$WORK" && PATH="$STUB_BUGFIX_DIR:$PATH" "$SPRINT_HEADLESS" t-bugf --base-ref HEAD 2>&1 >/dev/null)"
bugfix_rc=$?
set -e
[[ "$bugfix_rc" -eq 0 ]] || fail "bugfix headless run should exit 0 (PASS), got $bugfix_rc"

# Prompt must be bugfix-mode: two gates, reviewer skipped, no reviewer relay marker requested.
prompt="$(cat "$PROMPT_CAPTURE")"
assert_contains "$prompt" "two fresh Agent subagents"
assert_contains "$prompt" "advisory reviewer gate is intentionally SKIPPED"
if [[ "$prompt" == *"@@@CANON_HEADLESS_REPORT:reviewer@@@"* ]]; then fail "bugfix prompt should not request a reviewer relay block"; fi

# eval-report.md persisted; review-notes.md NOT created; no reviewer-extract warning.
assert_contains "$(cat "$WORK/.tickets/t-bugf/eval-report.md")" "pass: bugfix verified"
[[ -f "$WORK/.tickets/t-bugf/review-notes.md" ]] && fail "bugfix mode must not create review-notes.md"
if [[ "$bugfix_err" == *"could not extract the reviewer's report"* ]]; then fail "bugfix mode should not warn about a missing reviewer report"; fi

rm -rf "$STUB_BUGFIX_DIR"; rm -f "$PROMPT_CAPTURE"

# ── 14. Model plumbing (t-4003) — Gate model / --model reaches claude -p ──────
# A claude stub that records its argv (one marker-prefixed line per arg) lets us
# assert --model is/ isn't passed, with no real dispatch. The marker prefix makes
# a real `--model` argv token distinguishable from the same text inside the prompt.
SPRINT_HEADLESS_EVAL="$ROOT/tools/sprint-headless-eval"
CAP_ARGS="$(mktemp)"
STUB_CAP_DIR="$(mktemp -d)"
cat > "$STUB_CAP_DIR/claude" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do printf '<<ARG>>%s\n' "\$a"; done > "$CAP_ARGS"
printf '%s\n' '{"type":"result","is_error":false,"session_id":"cap","result":"@@@CANON_HEADLESS_REPORT:reviewer@@@\nVerdict: YES\n@@@CANON_HEADLESS_REPORT:/reviewer@@@\n@@@CANON_HEADLESS_REPORT:evaluator@@@\nVerdict: pass: ok\n@@@CANON_HEADLESS_REPORT:/evaluator@@@\nHEADLESS_VERDICT: PASS"}'
EOF
chmod +x "$STUB_CAP_DIR/claude"

assert_model_arg()   { grep -qx "<<ARG>>--model" "$CAP_ARGS" && grep -qx "<<ARG>>$1" "$CAP_ARGS" || fail "sprint-headless model test: expected '--model $1' in claude argv"; }
assert_no_model_arg() { if grep -qx "<<ARG>>--model" "$CAP_ARGS"; then fail "sprint-headless model test: unexpected --model in claude argv"; fi; }

# plan.md writer — files are already tracked (tkt ci on), and the tools read the
# working-tree plan.md, so re-committing per scenario isn't needed.
write_plan() {
  cat > "$WORK/.tickets/t-mdl1/plan.md" <<EOF
# Plan
## Sign-off
$1
- [x] Plan approved — proceed to implementation
## Approach
fixture
## Files
- none
## Decisions
- none
EOF
}

mkdir -p "$WORK/skills/sprint"
seed_ticket t-mdl1
(cd "$WORK" && "$ROOT/tools/tkt" ci t-mdl1 on >/dev/null)

# 14a. Gate model: haiku → --model haiku reaches claude
write_plan 'Tier: normal | Risk: fixture | Gate model: haiku'
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS" t-mdl1 --base-ref HEAD >/dev/null)
assert_model_arg haiku

# 14b. Gate model: session → no --model (claude default)
write_plan 'Tier: normal | Risk: fixture | Gate model: session'
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS" t-mdl1 --base-ref HEAD >/dev/null)
assert_no_model_arg

# 14c. No Gate model field → no --model (unchanged default path)
write_plan 'Tier: normal | Risk: fixture'
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS" t-mdl1 --base-ref HEAD >/dev/null)
assert_no_model_arg

# 14d. Invalid Gate model → hard-fail before claude, no dispatch
write_plan 'Tier: normal | Risk: fixture | Gate model: bad;model'
: > "$CAP_ARGS"
out="$(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_fail "$SPRINT_HEADLESS" t-mdl1 --base-ref HEAD)"
assert_contains "$out" "is invalid"
[[ -s "$CAP_ARGS" ]] && fail "sprint-headless model test: claude was invoked despite an invalid Gate model"

# 14e. sprint-headless-eval --model haiku → --model haiku reaches claude
mkdir -p "$WORK/specs"
cat > "$WORK/specs/x.md" <<'EOF'
# spec
- [ ] something holds
EOF
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" specs/x.md --base-ref HEAD --model haiku >/dev/null)
assert_model_arg haiku

# 14f. sprint-headless-eval without --model → no --model
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" specs/x.md --base-ref HEAD >/dev/null)
assert_no_model_arg

# 14g. sprint-headless-eval --model invalid → hard-fail before claude
: > "$CAP_ARGS"
out="$(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_fail "$SPRINT_HEADLESS_EVAL" specs/x.md --base-ref HEAD --model 'bad;model')"
assert_contains "$out" "not a valid model"
[[ -s "$CAP_ARGS" ]] && fail "sprint-headless-eval model test: claude was invoked despite an invalid --model"

# 14h–14k. sprint-headless-eval demo:true → default evaluator to Haiku (t-9dda).
# Ticket-id mode reads the ticket's demo flag for MODEL selection only (no gate change).
# seed a demo ticket (frontmatter demo: true) + a non-demo ticket, each with acceptance criteria.
seed_eval_ticket() {  # <id> <demo:true|"">
  local id="$1" demo_line="$2"
  mkdir -p "$WORK/.tickets/$id"
  cat > "$WORK/.tickets/$id/ticket.md" <<EOF
---
id: $id
status: open
type: task
priority: 2
created: 2026-01-01T00:00:00Z${demo_line:+
$demo_line}
---
# fixture
EOF
  cat > "$WORK/.tickets/$id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [ ] something holds
EOF
}
seed_eval_ticket t-demo "demo: true"
seed_eval_ticket t-ndm0 ""

# 14h. demo: true + no --model → --model haiku (auto-default)
: > "$CAP_ARGS"
demo_out="$(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-demo --base-ref HEAD 2>&1)"
assert_model_arg haiku
assert_contains "$demo_out" "demo: true and no --model"

# 14i. demo: true + explicit --model sonnet → explicit wins (sonnet, not haiku)
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-demo --base-ref HEAD --model sonnet >/dev/null)
assert_model_arg sonnet
if grep -qx "<<ARG>>haiku" "$CAP_ARGS"; then fail "sprint-headless-eval demo test: explicit --model must win over demo:true"; fi

# 14j. ticket WITHOUT demo + no --model → no --model (unchanged default)
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-ndm0 --base-ref HEAD >/dev/null)
assert_no_model_arg

# 14k. spec-file mode never reads demo (scope): a demo ticket exists, but a spec-file path → no --model
: > "$CAP_ARGS"
(cd "$WORK" && PATH="$STUB_CAP_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" specs/x.md --base-ref HEAD >/dev/null)
assert_no_model_arg

rm -rf "$WORK/.tickets/t-demo" "$WORK/.tickets/t-ndm0"
rm -rf "$STUB_CAP_DIR"; rm -f "$CAP_ARGS"

# ── 15. sprint-headless-eval ticket-id mode + QA exclusion + base-ref default (t-54e5) ──
SPRINT_HEADLESS_EVAL="$ROOT/tools/sprint-headless-eval"
mkdir -p "$WORK/skills/sprint"
seed_ticket t-ev01   # acceptance.md: Criteria/Test Plan "fixture" + QA "Tested locally"

PROMPT_CAP="$(mktemp)"; ARGS_CAP="$(mktemp)"
STUB_EV_DIR="$(mktemp -d)"
cat > "$STUB_EV_DIR/claude" <<EOF
#!/usr/bin/env bash
printf '%s' "\$2" > "$PROMPT_CAP"
for a in "\$@"; do printf '<<ARG>>%s\n' "\$a"; done > "$ARGS_CAP"
printf '%s\n' '{"type":"result","is_error":false,"session_id":"ev","result":"@@@CANON_HEADLESS_REPORT:evaluator@@@\nVerdict: pass: ok\n@@@CANON_HEADLESS_REPORT:/evaluator@@@\nHEADLESS_VERDICT: PASS"}'
EOF
chmod +x "$STUB_EV_DIR/claude"

# 15a. ticket-id: grades .tickets/<id>/acceptance.md, report into ticket folder,
# no --base-ref → default origin/main (simulated), QA item excluded from criteria.
git -C "$WORK" update-ref refs/remotes/origin/main HEAD
rm -f "$WORK/.tickets/t-ev01/eval-report.md"
(cd "$WORK" && PATH="$STUB_EV_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-ev01 >/dev/null)
[[ -f "$WORK/.tickets/t-ev01/eval-report.md" ]] || fail "eval ticket mode: eval-report.md not written into the ticket folder"
assert_contains "$(cat "$WORK/.tickets/t-ev01/eval-report.md")" "pass: ok"
ev_prompt="$(cat "$PROMPT_CAP")"
assert_contains "$ev_prompt" "git diff --name-only origin/main HEAD"
assert_contains "$ev_prompt" "fixture"
if [[ "$ev_prompt" == *"Tested locally"* ]]; then fail "eval ticket mode: QA 'Tested locally' leaked into graded criteria"; fi

# 15b. missing ticket → clear error, no dispatch
: > "$ARGS_CAP"
out="$(cd "$WORK" && PATH="$STUB_EV_DIR:$PATH" run_fail "$SPRINT_HEADLESS_EVAL" t-zzzz)"
assert_contains "$out" "not found"
[[ -s "$ARGS_CAP" ]] && fail "eval ticket mode: claude invoked for a missing ticket"

# 15c. base-ref default falls back to main when origin/main is absent
git -C "$WORK" update-ref -d refs/remotes/origin/main
git -C "$WORK" branch -f main HEAD
: > "$ARGS_CAP"
(cd "$WORK" && PATH="$STUB_EV_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-ev01 >/dev/null)
main_prompt="$(cat "$PROMPT_CAP")"
assert_contains "$main_prompt" "git diff --name-only main HEAD"
if [[ "$main_prompt" == *"origin/main"* ]]; then fail "eval: fell back to main but still referenced origin/main"; fi
git -C "$WORK" branch -D main >/dev/null 2>&1 || true

# 15d. --model works with the ticket-id form
git -C "$WORK" update-ref refs/remotes/origin/main HEAD
: > "$ARGS_CAP"
(cd "$WORK" && PATH="$STUB_EV_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-ev01 --model haiku >/dev/null)
{ grep -qx "<<ARG>>--model" "$ARGS_CAP" && grep -qx "<<ARG>>haiku" "$ARGS_CAP"; } || fail "eval ticket mode: --model haiku not passed"

# 15e. explicit --base-ref beats the default
(cd "$WORK" && PATH="$STUB_EV_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" t-ev01 --base-ref HEAD >/dev/null)
head_prompt="$(cat "$PROMPT_CAP")"
assert_contains "$head_prompt" "git diff --name-only HEAD HEAD"
if [[ "$head_prompt" == *"origin/main"* ]]; then fail "eval: default used despite explicit --base-ref"; fi

# 15f. spec-file mode still works (report next to the spec)
mkdir -p "$WORK/specs2"
printf '# spec\n- [ ] some standalone criterion\n' > "$WORK/specs2/s.md"
rm -f "$WORK/specs2/eval-report.md"
(cd "$WORK" && PATH="$STUB_EV_DIR:$PATH" run_ok "$SPRINT_HEADLESS_EVAL" specs2/s.md --base-ref HEAD >/dev/null)
[[ -f "$WORK/specs2/eval-report.md" ]] || fail "eval spec mode: eval-report.md not written next to the spec"

# 15g. neither origin/main nor main → clear error (fresh repo, no remote)
NB="$(mktemp -d)"
git -C "$NB" init -q; git -C "$NB" config user.email t@t.com; git -C "$NB" config user.name t
echo x > "$NB/f"; git -C "$NB" add f; git -C "$NB" commit -q -m x; git -C "$NB" branch -M somebranch
mkdir -p "$NB/skills/sprint" "$NB/specs"; printf '# s\n- [ ] x\n' > "$NB/specs/s.md"
out="$(cd "$NB" && PATH="$STUB_EV_DIR:$PATH" run_fail "$SPRINT_HEADLESS_EVAL" specs/s.md)"
assert_contains "$out" "could not resolve a default base ref"
rm -rf "$NB"

git -C "$WORK" update-ref -d refs/remotes/origin/main 2>/dev/null || true
rm -rf "$STUB_EV_DIR"; rm -f "$PROMPT_CAP" "$ARGS_CAP"

rm -rf "$STUB_OK_DIR" "$STUB_BAD_DIR"

echo "sprint-headless: ok (guard rails: not-ci-eligible, uncommitted docs, unapproved plan, no-resolvable-base-ref all hard-fail; invocation error hard-fails with a clear message; canon-repo and consumer-project skills layouts both resolve, neither-layout case fails closed; well-formed relay persists correct per-gate content with no section-swap; malformed relay skips that file with a warning and leaves HEADLESS_VERDICT/exit-code unaffected; GITHUB_STEP_SUMMARY receives the full result text; a present-but-non-Windows sprint-headless-json-win.exe is never exec'd; adversarial content (quotes, backticks, \$HOME, backslashes) survives extract_report unmangled; model plumbing: Gate model:/--model reaches claude, session/absent passes none, invalid hard-fails before dispatch; sprint-headless-eval ticket-id mode grades .tickets/<id>/acceptance.md into the ticket folder excluding ## QA, base-ref defaults origin/main→main with explicit override + clear no-default error, spec-file mode still works)"
