#!/usr/bin/env bash
# doc-mirror-parity — verify that the sprint/wrapup doc blocks which must stay
# in sync actually are. After H1 (shared-gate-protocol.md extraction), the
# majority of previously-duplicated content now lives in one file. This test
# verifies:
#   A: fallback git commands in shared-gate-protocol.md match security-review.md
#   B: review.md and eval.md both reference the shared file (not inline copies)
#   C: Windows `command -v` fallback clause present in start.md and wrapup/SKILL.md
#   D: base-ref branching commands match between shared-gate-protocol.md and security-review.md

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

REVIEW="$ROOT/skills/sprint/reference/review.md"
EVAL="$ROOT/skills/sprint/reference/eval.md"
SHARED="$ROOT/skills/sprint/reference/shared-gate-protocol.md"
SECURITY="$ROOT/skills/wrapup/gates/security-review.md"
START="$ROOT/skills/sprint/reference/start.md"
WRAPUP="$ROOT/skills/wrapup/SKILL.md"

# ── Check A: the two git commands in the fallback block must be byte-identical
# between shared-gate-protocol.md and security-review.md — these are the only
# two copies that still exist (review.md/eval.md now reference the shared file).
fallback_commands() {
  grep -A 2 "fall back in two tiers" "$1" | grep -oE '`git (diff|status) [^`]+`' | sort -u
}

shared_cmds="$(fallback_commands "$SHARED")"
security_cmds="$(fallback_commands "$SECURITY")"

if [[ -z "$shared_cmds" || -z "$security_cmds" ]]; then
  fail "doc-mirror-parity: could not find fallback git commands in shared-gate-protocol.md or security-review.md — extraction pattern is stale"
fi

if [[ "$shared_cmds" != "$security_cmds" ]]; then
  echo "doc-mirror-parity: FAIL — fallback git commands diverged between shared-gate-protocol.md and security-review.md"
  echo "shared-gate-protocol.md:"; echo "$shared_cmds" | sed 's/^/  /'
  echo "security-review.md:"; echo "$security_cmds" | sed 's/^/  /'
  exit 1
fi

# ── Check B: review.md and eval.md must reference shared-gate-protocol.md
# (not carry inline copies of the shared sections).
for file in "$REVIEW" "$EVAL"; do
  label="$(basename "$file")"
  if ! grep -q "shared-gate-protocol.md" "$file"; then
    fail "doc-mirror-parity: $label does not reference shared-gate-protocol.md — shared sections may have been re-inlined"
  fi
done

# ── Check C: the Windows `command -v` fallback clause must survive verbatim
# in start.md and wrapup/SKILL.md.
WINCLAUSE='`where sprint` on Windows if `command -v` returns nothing'

check_wins_clause() {
  local file="$1" label="$2"
  local count
  count="$(grep -coF "$WINCLAUSE" "$file")"
  [[ "$count" -ge 1 ]] || fail "doc-mirror-parity: $label is missing the Windows command -v fallback clause verbatim (\"$WINCLAUSE\")"
}

check_wins_clause "$START" "start.md"
check_wins_clause "$WRAPUP" "wrapup/SKILL.md"

start_occurrences="$(grep -coF "$WINCLAUSE" "$START")"
if [[ "$start_occurrences" -lt 2 ]]; then
  fail "doc-mirror-parity: start.md should have 2 occurrences of the Windows command -v fallback clause (steps 1 and 5), found $start_occurrences"
fi

# ── Check D: base-ref branching commands must match between
# shared-gate-protocol.md and security-review.md.
base_ref_commands() {
  grep -oE 'git diff --name-only <base-ref> HEAD|git diff --name-only \$\(git merge-base HEAD origin/main\) HEAD' "$1" | sort -u
}

shared_baseref="$(base_ref_commands "$SHARED")"
security_baseref="$(base_ref_commands "$SECURITY")"

if [[ -z "$shared_baseref" || -z "$security_baseref" ]]; then
  fail "doc-mirror-parity: could not find base-ref branching commands in shared-gate-protocol.md or security-review.md — extraction pattern is stale"
fi

if [[ "$shared_baseref" != "$security_baseref" ]]; then
  echo "doc-mirror-parity: FAIL — base-ref branching commands diverged between shared-gate-protocol.md and security-review.md"
  echo "shared-gate-protocol.md:"; echo "$shared_baseref" | sed 's/^/  /'
  echo "security-review.md:"; echo "$security_baseref" | sed 's/^/  /'
  exit 1
fi

# ── Check E: the required visual-verification convention (t-277d) must be
# present — there is no CLI gate for it (CSS-in-code defeats a file-extension
# trigger), so this lock guards the protocol language against silent deletion.
# shared-gate-protocol.md must carry the "required (not optional)" framing and
# the adjacent-element regression clause; start.md must carry the
# visual-acceptance-criterion requirement for UI-affecting sprints.
REQUIRED_VISUAL='required, not optional'
ADJACENT_CLAUSE='Check adjacent/related elements'
START_VISUAL_REQ='Visual acceptance criteria (required for UI-affecting work)'

grep -qF "$REQUIRED_VISUAL" "$SHARED" || fail "doc-mirror-parity: shared-gate-protocol.md ## Self-serve visual verification is missing the 'required, not optional' framing for UI changes (t-277d)"
grep -qF "$ADJACENT_CLAUSE" "$SHARED" || fail "doc-mirror-parity: shared-gate-protocol.md is missing the adjacent-element visual-regression check (t-277d)"
grep -qF "$START_VISUAL_REQ" "$START" || fail "doc-mirror-parity: start.md is missing the required visual-acceptance-criterion guidance for UI-affecting sprints (t-277d)"

# ── Check F: the citation backtick-escape rule is triplicated in
# shared-gate-protocol.md, eval.md, and review.md (each gate doc is dispatched
# to a fresh subagent independently, so the rule must be self-contained in each,
# not referenced). The three copies aren't byte-identical (surrounding prose
# differs), so this locks the load-bearing invariant phrase against silent
# divergence — the same "duplicate but lock with a parity test" pattern as
# Checks A/D, satisfying standards/efficiency.md's DRY trigger.
CITATION_ESCAPE_RULE='the board'\''s renderer treats a backslash-escaped backtick as literal'

for file in "$SHARED" "$EVAL" "$REVIEW"; do
  label="$(basename "$file")"
  grep -qF "$CITATION_ESCAPE_RULE" "$file" || fail "doc-mirror-parity: $label is missing the citation backtick-escape rule verbatim (\"$CITATION_ESCAPE_RULE\") — the citation-format wording has diverged across the gate docs"
done

# ── Check G: the scenario-backed grading language (t-c67e) must survive in
# eval.md (the evaluator runs the runner command, and never grades a runnable
# scenario item `not-run`) and start.md (scenario-backed criteria name a runner
# command and are locked before implementation). No CLI gate enforces scenario
# grading — this locks the protocol language against silent deletion, the same
# "lock the convention" pattern as Check E for t-277d.
EVAL_SCENARIO='scenario-backed criterion'
EVAL_SCENARIO_NOTRUN='do not grade it `not-run` from static reading when the command is present and runnable'
START_SCENARIO='Scenario-backed acceptance criteria'
START_ORDERING='locked at the sprint-start approval gate'

grep -qF "$EVAL_SCENARIO" "$EVAL" || fail "doc-mirror-parity: eval.md is missing the scenario-backed run-to-grade rule verbatim (\"$EVAL_SCENARIO\") (t-c67e)"
grep -qF "$EVAL_SCENARIO_NOTRUN" "$EVAL" || fail "doc-mirror-parity: eval.md is missing the scenario 'do not grade not-run when runnable' rule verbatim (t-c67e)"
grep -qF "$START_SCENARIO" "$START" || fail "doc-mirror-parity: start.md is missing the scenario-backed acceptance-criteria guidance verbatim (\"$START_SCENARIO\") (t-c67e)"
grep -qF "$START_ORDERING" "$START" || fail "doc-mirror-parity: start.md is missing the before-implementation ordering norm verbatim (\"$START_ORDERING\") (t-c67e)"

# ── Check H: the design-fit tag set (t-d92e) must stay identical between the
# code-reviewer gate definition (reviewer.md dim.3) and its user-facing doc row
# (docs/wrapup-gates.md). The two are hand-synced; this locks the principle
# vocabulary so a future edit to either side can't silently drift it.
REVIEWER_GATE="$ROOT/skills/wrapup/gates/reviewer.md"
WRAPUP_DOC="$ROOT/docs/wrapup-gates.md"

design_tags() {
  grep -oE '\[(SRP|OCP|LSP|ISP|DIP|DRY|LoD|CoC|pattern-fit)\]' "$1" | sort -u
}

gate_tags="$(design_tags "$REVIEWER_GATE")"
doc_tags="$(design_tags "$WRAPUP_DOC")"

if [[ -z "$gate_tags" || -z "$doc_tags" ]]; then
  fail "doc-mirror-parity: design-fit tags not found in reviewer.md or wrapup-gates.md — the tag-set extraction pattern is stale"
fi

if [[ "$gate_tags" != "$doc_tags" ]]; then
  echo "doc-mirror-parity: FAIL — design-fit tag set diverged between reviewer.md and docs/wrapup-gates.md"
  echo "reviewer.md:"; echo "$gate_tags" | sed 's/^/  /'
  echo "wrapup-gates.md:"; echo "$doc_tags" | sed 's/^/  /'
  exit 1
fi

# ── Check I: the demo-mode / gate-floor invariant "never drops below the binding
# evaluator" is intentionally distributed (not de-duplicated) across the workflow
# docs — DECISIONS.md 2026-08-07 keeps the "superset" phrasing in place as
# drift-resistant rather than consolidating it. This locks the verbatim phrase in
# each home so a demo-policy edit can't silently drop it from one — the same
# "duplicate but lock with a parity test" pattern as Checks A/D/F.
EVALUATOR_FLOOR='never drops below the binding evaluator'
COMPLETE="$ROOT/skills/sprint/reference/complete.md"
SPRINT_SKILL="$ROOT/skills/sprint/SKILL.md"
HOWITWORKS="$ROOT/docs/how-it-works.md"
AGENTS="$ROOT/AGENTS.md"

for file in "$SPRINT_SKILL" "$COMPLETE" "$HOWITWORKS" "$AGENTS"; do
  label="$(basename "$file")"
  grep -qF "$EVALUATOR_FLOOR" "$file" || fail "doc-mirror-parity: $label is missing the gate-floor invariant verbatim (\"$EVALUATOR_FLOOR\") — the demo-mode/evaluator-floor wording has drifted across the workflow docs"
done

# ── Check J: the destructive-git-command guardrail (t-00e9) is triplicated in
# shared-gate-protocol.md, eval.md, and review.md — same reasoning as Check F
# (each gate doc is dispatched to a fresh subagent independently, so the rule
# must be self-contained in each, not referenced). Live-reproduced trigger: a
# dispatched evaluator ran `git checkout` on an unrelated file to make its own
# pre-existing-failure test run green, silently discarding the user's
# uncommitted work.
NO_DESTRUCTIVE_GIT='never run git checkout, git reset, or git clean to make an unrelated failure disappear'

for file in "$SHARED" "$EVAL" "$REVIEW"; do
  label="$(basename "$file")"
  grep -qF "$NO_DESTRUCTIVE_GIT" "$file" || fail "doc-mirror-parity: $label is missing the destructive-git-command guardrail verbatim (\"$NO_DESTRUCTIVE_GIT\") — the gate-safety wording has diverged across the gate docs"
done

echo "doc-mirror-parity: ok (fallback commands match shared↔security; review.md/eval.md reference shared file; Windows fallback clause present; base-ref commands match shared↔security; required-visual convention present in shared-gate-protocol.md + start.md; citation backtick-escape rule present in shared-gate-protocol.md + eval.md + review.md; scenario-backed grading language present in eval.md + start.md; design-fit tag set matches reviewer.md↔wrapup-gates.md; gate-floor invariant present in SKILL.md + complete.md + how-it-works.md + AGENTS.md; destructive-git-command guardrail present in shared-gate-protocol.md + eval.md + review.md)"
