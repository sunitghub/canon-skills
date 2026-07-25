#!/usr/bin/env bash
# jtbd-routing.sh — locks the JTBD job-type routing (t-7af4): type:bug -> root-why,
# refactor -> mikado, orthogonal to risk tier; and the root-why independent-invariant rule.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT/skills/sprint/reference/start.md"
ROOTWHY="$ROOT/skills/sprint/reference/root-why.md"
SKILL="$ROOT/skills/sprint/SKILL.md"

fail() { echo "jtbd-routing: FAIL — $1" >&2; exit 1; }

# root-why reference exists with the 5-Whys method and the independent-invariant rule.
[ -f "$ROOTWHY" ] || fail "missing skills/sprint/reference/root-why.md"
grep -qi "5 whys" "$ROOTWHY" || fail "root-why.md missing the 5 Whys method"
grep -qi "invariant" "$ROOTWHY" || fail "root-why.md missing the invariant rule"
grep -qi "worked example" "$ROOTWHY" || fail "root-why.md missing the worked-example requirement"
# It must NOT re-derive the code's own formula (the anti-circular rule).
grep -qi "re-derive\|re-derives\|hardcod" "$ROOTWHY" \
  || fail "root-why.md missing the anti-circular (no re-derived test) guidance"

# start.md routes by job type and states orthogonality to tier.
grep -qi "job-type planning step" "$START" || fail "start.md missing the Job-type planning step"
grep -q "root-why" "$START" || fail "start.md does not route type:bug to root-why"
grep -q "mikado" "$START" || fail "start.md does not route refactor to mikado"
grep -qi "orthogonal" "$START" || fail "start.md does not state job type is orthogonal to tier"

# SKILL.md documents the job-type dimension.
grep -qi "job types\|jtbd" "$SKILL" || fail "SKILL.md missing the Job types (JTBD) section"
grep -qi "orthogonal" "$SKILL" || fail "SKILL.md job-type section missing the orthogonal-to-tier statement"

# The invariant must be planning-only: no claim that job type changes/skips gates.
grep -qi "never changes which gates run\|never change.*gate" "$SKILL" \
  || fail "SKILL.md job-type section must state it never changes which gates run"

echo "jtbd-routing: ok (root-why 5-Whys + independent-invariant rule; start.md routes bug->root-why, refactor->mikado, orthogonal to tier; SKILL.md job-type dimension changes no gate)"
