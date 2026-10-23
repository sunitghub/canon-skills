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

# ── Check C2 (t-2595): start.md's three helper-doc reads stay conditional, and the
# start checklist that replaces them stays. An unconditional read costs ~390 lines
# on every sprint start.
# Anchor the read and its condition to the same line, so the condition can't drift elsewhere.
grep -F 'Read `tools/ticket.md` (the `tkt`/`sprint` CLI help' "$START" | grep -F "only if you need a command you don't know" >/dev/null || fail "doc-mirror-parity: start.md step 1's tools/ticket.md read is missing or no longer conditional (t-2595)"
grep -qF 'Read `standards/ticket-layout.md` (field contract, doc lifecycle, board rendering rules) only when' "$START" || fail "doc-mirror-parity: start.md step 4's standards/ticket-layout.md read is no longer conditional (t-2595)"
grep -qF 'create it from the template in `tools/handoff.md` (read that only then' "$START" || fail "doc-mirror-parity: start.md step 5's tools/handoff.md read is no longer conditional (t-2595)"
grep -qF 'Start checklist' "$START" || fail "doc-mirror-parity: start.md is missing its Start checklist (t-2595)"
# The three old unconditional forms must not come back.
[ "$(grep -cE 'Read `tools/handoff.md` \(same resolution|1\. \*\*Ticket and context\.\*\* Read `tools/ticket.md`|^   - Read `standards/ticket-layout.md` for' "$START")" -eq 0 ] || fail "doc-mirror-parity: start.md has an unconditional helper-doc read again (t-2595)"

# ── Check C3 (t-de16): the reviewer's concern labels have one owner — tools/sprint's
# REVIEW_CONCERNS array, which _gate_review_notes_shape enforces at close. review.md's report
# template must show each label, or a reviewer following it would be rejected at close.
concerns_line="$(grep -m1 '^REVIEW_CONCERNS=' "$ROOT/tools/sprint")" || fail "doc-mirror-parity: tools/sprint has no REVIEW_CONCERNS array (t-de16)"
concern_count=0
while IFS= read -r label; do
  [[ -n "$label" ]] || continue
  concern_count=$((concern_count + 1))
  grep -qF "$label:" "$ROOT/skills/sprint/reference/review.md" || fail "doc-mirror-parity: review.md's report template is missing the '$label:' concern line that tools/sprint requires at close (t-de16)"
done < <(grep -oE '"[^"]+"' <<<"$concerns_line" | tr -d '"')
[[ "$concern_count" -ge 5 ]] || fail "doc-mirror-parity: expected >= 5 review concern labels in tools/sprint, found $concern_count (t-de16)"
# t-f13a: the same for the triage buckets (REVIEW_BUCKETS).
buckets_line="$(grep -m1 '^REVIEW_BUCKETS=' "$ROOT/tools/sprint")" || fail "doc-mirror-parity: tools/sprint has no REVIEW_BUCKETS array (t-f13a)"
bucket_count=0
while IFS= read -r label; do
  [[ -n "$label" ]] || continue
  bucket_count=$((bucket_count + 1))
  grep -qF "$label:" "$ROOT/skills/sprint/reference/review.md" || fail "doc-mirror-parity: review.md's report template is missing the '$label:' triage line that tools/sprint requires at close (t-f13a)"
done < <(grep -oE '"[^"]+"' <<<"$buckets_line" | tr -d '"')
[[ "$bucket_count" -eq 4 ]] || fail "doc-mirror-parity: expected 4 triage buckets in tools/sprint, found $bucket_count (t-f13a)"

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

# ── Check K: the demo-mode policy is deliberately mirrored between SKILL.md
# (sprint-start, needed to propose demo mode before a ticket exists) and
# complete.md (close-time, needed to execute the close-path) — separate
# consumers per efficiency-notes.md's mirrored-docs exception, so lock instead of
# merging (t-936d). This is what t-8f16's headless/demo contradiction slipped
# through: Check I only locked the evaluator-floor phrase, not the gate list
# or the headless carve-out that actually drifted.
DEMO_GATE_LIST='keep exactly `security-review` + the binding evaluator, skip the advisory reviewer + the rest of wrapup — a superset of what `bugfix` trims, additionally dropping `code-reviewer` (which `bugfix` keeps).'
DEMO_HAIKU='evaluator is forced to Haiku'
DEMO_HEADLESS='Headless/CI never reduces the gate set for `demo`: `sprint-headless` runs its full pipeline and ignores `demo` entirely; `sprint-headless-eval` (already eval-only) also runs its full gate set but reads `demo: true` to default the evaluator to Haiku when no `--model` is given — a model choice, never a skipped gate.'

for file in "$SPRINT_SKILL" "$COMPLETE"; do
  label="$(basename "$file")"
  grep -qF "$DEMO_GATE_LIST" "$file" || fail "doc-mirror-parity: $label is missing the demo-mode gate-list phrase verbatim — the demo close-path's gate set has diverged between SKILL.md and complete.md"
  grep -qF "$DEMO_HAIKU" "$file" || fail "doc-mirror-parity: $label is missing the demo-mode Haiku-forcing phrase verbatim"
  grep -qF "$DEMO_HEADLESS" "$file" || fail "doc-mirror-parity: $label is missing the demo-mode headless carve-out phrase verbatim — this is the exact fact that drifted in t-8f16"
done

# ── Check L: the "probe only in a scratch copy" rule (t-bb2d) is mirrored in shared-gate-protocol.md, eval.md and review.md — each gate doc is
# dispatched to a fresh subagent on its own (same reasoning as Checks F and J), so each must carry the load-bearing fragments verbatim. Live
# trigger: an evaluator's probe ran with the real checkout as its cwd (an unchecked cd failed) and renamed the branch, committed junk and wrote
# files in and outside the repo.
SCRATCH_RULE_FRAGMENTS=(
  '**Probe only in a scratch copy**'
  'S="$(mktemp -d)" || exit 1'
  'cd "$S/…" || exit 1'
  'never a bare `cd`'
  '`git init`, `add`, `commit`, `branch`, `config` or `worktree`'
  'write nothing outside the scratch directory'
)
for file in "$SHARED" "$EVAL" "$REVIEW"; do
  label="$(basename "$file")"
  for frag in "${SCRATCH_RULE_FRAGMENTS[@]}"; do
    grep -qF -- "$frag" "$file" || fail "doc-mirror-parity: $label is missing the scratch-copy rule fragment verbatim: $frag (t-bb2d, Check L)"
  done
done

# ── Check M: the "pin the environment" rule (t-ce0b) lives in shared-gate-protocol.md and is mirrored in the two agent files and the two Codex
# files — a gate may read only its agent file first. Live trigger: a reviewer ran `canon update` in a scratch clone and re-linked the user's
# registered projects. The four mirrors carry the same sentence; the owner carries the paragraph.
PIN_RULE_FRAGMENTS=(
  '`canon update`, `skills.sh`, `install.sh`'
  '`HOME`, `CANON_HOME`, `TMPDIR` and `XDG_CONFIG_HOME`'
  'fresh `mktemp -d` directories in that same command'
  "registered projects, not on the working directory"
)
for file in "$SHARED" "$ROOT/agents/canon-reviewer.md" "$ROOT/agents/canon-evaluator.md" "$ROOT/agents/codex/canon-reviewer.toml" "$ROOT/agents/codex/canon-evaluator.toml"; do
  label="${file#"$ROOT"/}"
  for frag in "${PIN_RULE_FRAGMENTS[@]}"; do
    grep -qF -- "$frag" "$file" || fail "doc-mirror-parity: $label is missing the pin-the-environment rule fragment verbatim: $frag (t-ce0b, Check M)"
  done
done
# The verb and the condition carry the rule: a flipped "Never run ... unless" must not pass on its nouns alone.
grep -qF -- 'Never run them, or a script that calls them, unless' "$SHARED" || fail "doc-mirror-parity: shared-gate-protocol.md lost 'Never run them, or a script that calls them, unless' (t-ce0b, Check M)"
for file in "$ROOT/agents/canon-reviewer.md" "$ROOT/agents/canon-evaluator.md" "$ROOT/agents/codex/canon-reviewer.toml" "$ROOT/agents/codex/canon-evaluator.toml"; do
  grep -qF -- 'Never run `canon update`, `skills.sh`, `install.sh`, an uninstall or the daemon unless' "$file" || fail "doc-mirror-parity: ${file#"$ROOT"/} lost the 'Never run ... unless' sentence (t-ce0b, Check M)"
done
grep -qF -- '**Pin the environment**' "$SHARED" || fail "doc-mirror-parity: shared-gate-protocol.md is missing the '**Pin the environment**' paragraph (t-ce0b, Check M)"

# ── Check N: the repo-check gate is gone (t-0a7c); its checks live elsewhere. The wrapup pipeline no longer names it, the gate file is
# deleted, doc-audit hands its mechanical checks to tools/doc-check, and code-reviewer holds the syntax check and the canon-checkout-only
# checks (skills lint, catalog drift, orphan scripts, board render). complete.md's skill-eval skip keeps the canon-checkout test (t-b215).
COMPLETE_MD="$ROOT/skills/sprint/reference/complete.md"
grep -qF -- 'security-review → doc-audit → refresh docs' "$WRAPUP" || fail "doc-mirror-parity: wrapup/SKILL.md's pipeline is not code-simplifier → code-reviewer → security-review → doc-audit → refresh docs (t-0a7c, Check N)"
[[ ! -e "$ROOT/skills/wrapup/gates/repo-check.md" ]] || fail "doc-mirror-parity: skills/wrapup/gates/repo-check.md is back; the gate was removed (t-0a7c, Check N)"
for frag in '`tools/skill-eval-scope.sh`' '`skipped | not a canon checkout`'; do
  grep -qF -- "$frag" "$COMPLETE_MD" || fail "doc-mirror-parity: complete.md's skill-eval skip lost '$frag' (t-b215, Check N)"
done
grep -qF -- 'tools/doc-check' "$ROOT/skills/doc-audit/SKILL.md" || fail "doc-mirror-parity: doc-audit no longer runs tools/doc-check first (t-0a7c, Check N)"
grep -qF -- 'only when a user-facing doc changed' "$ROOT/skills/doc-audit/SKILL.md" || fail "doc-mirror-parity: doc-audit lost its skip rule (t-0a7c, Check N)"
for frag in '`bash -n` for shell scripts' 'canon-dev.sh lint' 'canon-dev.sh catalog'; do
  grep -qF -- "$frag" "$ROOT/skills/wrapup/gates/reviewer.md" || fail "doc-mirror-parity: code-reviewer lost '$frag', moved there from repo-check (t-0a7c, Check N)"
done

# ── Check O: efficiency.md is the always-loaded minimum and efficiency-notes.md holds its domain rules (t-8837). Every domain the
# index line in efficiency.md names must be a section of the notes file, or an agent is sent to a section that does not exist; and the
# lesson-destination rule in skill-setup-std.md and its mirror in promote-learnings (read by a fresh reviewer) name the same two homes.
EFF="$ROOT/standards/efficiency.md"; NOTES="$ROOT/standards/efficiency-notes.md"
index="$(grep -F 'Domain rules live in `efficiency-notes.md`' "$EFF")" || fail "doc-mirror-parity: efficiency.md lost its index line to efficiency-notes.md (t-8837, Check O)"
domains="$(printf '%s\n' "${index#*domain:\*\* }" | tr '·' '\n' | sed 's/^ *//; s/ *\.\{0,1\} *$//' | grep -v '^$')"
[[ "$(printf '%s\n' "$domains" | grep -c .)" -ge 5 ]] || fail "doc-mirror-parity: could not read the domains from efficiency.md's index line: $index"
while IFS= read -r d; do
  grep -qixF -- "## $d" "$NOTES" || fail "doc-mirror-parity: efficiency.md's index names '$d', which is not a section of efficiency-notes.md (t-8837, Check O)"
done <<< "$domains"
while IFS= read -r h; do   # and every section of the notes file is reachable from that index
  printf '%s\n' "$domains" | grep -ixF -- "$h" >/dev/null || fail "doc-mirror-parity: efficiency-notes.md section '$h' is not named in efficiency.md's index line (t-8837, Check O)"
done < <(sed -n 's/^## //p' "$NOTES")
for f in "$ROOT/standards/skill-setup-std.md" "$ROOT/skills/promote-learnings/SKILL.md"; do
  for frag in '`standards/efficiency-notes.md`' 'nearly every session'; do
    grep -qF -- "$frag" "$f" || fail "doc-mirror-parity: ${f#"$ROOT"/} lost '$frag' from the lesson-destination rule (t-8837, Check O)"
  done
done


# ── Check P: the mutation sweep is a non-binding pre-evaluator step (t-087c). The checklist, complete.md and the mutation-test skill
# each name the evidence stamp and the skip-needs-a-reason row, so one cannot drop either while the others keep it.
for f in "$ROOT/skills/sprint/reference/complete-checklist.md" "$COMPLETE" "$ROOT/skills/mutation-test/SKILL.md"; do
  for frag in 'evidence.sh stamp <id> mutant-sweep -- mutant-sweep' 'mutation-test | skipped | <reason>' 'not skippable without a reason'; do
    grep -qF -- "$frag" "$f" || fail "doc-mirror-parity: ${f#"$ROOT"/} lost '$frag' from the pre-evaluator mutation sweep (t-087c, Check P)"
  done
done
# ── Check Q: the Plan fallback is relayed, never typed (t-ff14). The checklist, complete.md and shared-gate-protocol.md each name
# `sprint relay-report`; the checklist and complete.md also name the Plan fallback and that the main session never types a report.
for f in "$ROOT/skills/sprint/reference/complete-checklist.md" "$COMPLETE" "$SHARED"; do
  grep -qF -- 'sprint relay-report' "$f" || fail "doc-mirror-parity: ${f#"$ROOT"/} lost 'sprint relay-report' from the Plan fallback (t-ff14, Check Q)"
done
for f in "$ROOT/skills/sprint/reference/complete-checklist.md" "$COMPLETE"; do
  grep -qF -- '`Plan`' "$f" || fail "doc-mirror-parity: ${f#"$ROOT"/} does not name the \`Plan\` fallback (t-ff14, Check Q)"
  grep -qiF -- 'never types' "$f" || fail "doc-mirror-parity: ${f#"$ROOT"/} lost 'never types' (the main session never types a gate report) (t-ff14, Check Q)"
done
echo "doc-mirror-parity: ok (fallback commands match shared↔security; review.md/eval.md reference shared file; Windows fallback clause present; base-ref commands match shared↔security; required-visual convention present in shared-gate-protocol.md + start.md; citation backtick-escape rule present in shared-gate-protocol.md + eval.md + review.md; scenario-backed grading language present in eval.md + start.md; design-fit tag set matches reviewer.md↔wrapup-gates.md; gate-floor invariant present in SKILL.md + complete.md + how-it-works.md + AGENTS.md; destructive-git-command guardrail present in shared-gate-protocol.md + eval.md + review.md; demo-mode policy phrases match SKILL.md↔complete.md; scratch-copy rule present in shared-gate-protocol.md + eval.md + review.md; pin-the-environment rule present in shared-gate-protocol.md + both agent files + both Codex files)"
