#!/usr/bin/env bash
# doc-mirror-parity — catch drift in the sprint/wrapup doc blocks that are
# deliberately duplicated across files instead of extracted to one owner
# (fresh subagents load these files standalone, with no shared context).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

REVIEW="$ROOT/skills/sprint/reference/review.md"
EVAL="$ROOT/skills/sprint/reference/eval.md"
SECURITY="$ROOT/skills/wrapup/gates/security-review.md"
START="$ROOT/skills/sprint/reference/start.md"
WRAPUP="$ROOT/skills/wrapup/SKILL.md"

# ── Check A: the two git commands in the fallback block must be byte-identical
# across all three gates — the executable substance can't drift even though
# each gate's surrounding prose deliberately differs (review.md/eval.md say
# "read", security-review.md says "scan" — DECISIONS.md records this as
# intentional, so this check never compares prose, only the commands).
fallback_commands() {
  grep -A 2 "fall back in two tiers" "$1" | grep -oE '`git (diff|status) [^`]+`' | sort -u
}

review_cmds="$(fallback_commands "$REVIEW")"
eval_cmds="$(fallback_commands "$EVAL")"
security_cmds="$(fallback_commands "$SECURITY")"

if [[ -z "$review_cmds" || -z "$eval_cmds" || -z "$security_cmds" ]]; then
  fail "doc-mirror-parity: could not find fallback git commands in one of review.md/eval.md/security-review.md — extraction pattern is stale"
fi

if [[ "$review_cmds" != "$eval_cmds" || "$review_cmds" != "$security_cmds" ]]; then
  echo "doc-mirror-parity: FAIL — fallback git commands diverged across gates"
  echo "review.md:"; echo "$review_cmds" | sed 's/^/  /'
  echo "eval.md:"; echo "$eval_cmds" | sed 's/^/  /'
  echo "security-review.md:"; echo "$security_cmds" | sed 's/^/  /'
  exit 1
fi

# ── Check B: review.md and eval.md's fallback block is a true mirror of each
# other (both are fresh-subagent-loaded reviewer/evaluator gates with the same
# "read the real changed files" framing) — compare the two bullet lines
# verbatim, normalizing away only the lead-in's "same as `x`/`y`" clause,
# since that clause legitimately names the *other* files and differs per copy.
fallback_bullets() {
  grep -A 2 "fall back in two tiers" "$1" | grep '^\s*-'
}

review_bullets="$(fallback_bullets "$REVIEW")"
eval_bullets="$(fallback_bullets "$EVAL")"

if [[ -z "$review_bullets" || -z "$eval_bullets" ]]; then
  fail "doc-mirror-parity: could not find fallback bullets in review.md/eval.md — extraction pattern is stale"
fi

if [[ "$review_bullets" != "$eval_bullets" ]]; then
  echo "doc-mirror-parity: FAIL — review.md and eval.md's fallback bullets diverged (they're meant to be byte-identical mirrors)"
  diff <(echo "$review_bullets") <(echo "$eval_bullets") || true
  exit 1
fi

# ── Check C: the Windows `command -v` fallback clause is deliberately
# paraphrased per file (different surrounding sentences), but the literal
# "no `command -v`, use `where sprint`" instruction must survive verbatim in
# every copy — a reworded copy that silently drops the Windows case is the
# real risk here, not prose-level wording drift.
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

echo "doc-mirror-parity: ok (fallback commands match across 3 gates; review.md/eval.md bullets are byte-identical; Windows fallback clause present in all path-resolution copies)"
