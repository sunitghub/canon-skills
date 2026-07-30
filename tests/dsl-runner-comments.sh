#!/usr/bin/env bash
# dsl-runner-comments.sh (t-b878) — the scenario runners must skip `#` comment lines.
#
# Independent invariant: a line whose trimmed form starts with `#` contributes nothing — it neither
# starts a scenario nor sets a field. Fixture below has a real scenario followed by a commented-out
# `#Scenario:` + commented Given/Then whose values (cart_total 40.00, applied false) would CLOBBER
# the real scenario if the parser didn't skip comments — turning its final_total check into a
# mismatch (exit 1). With the fix the comment block is ignored and the real scenario PASSes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

EX="$ROOT/examples/dsl-discount-spec"

have_node=0; command -v node >/dev/null 2>&1 && have_node=1
have_py=0;   command -v python3 >/dev/null 2>&1 && have_py=1
if [[ "$have_node" -eq 0 && "$have_py" -eq 0 ]]; then
  echo "dsl-runner-comments: skipped (node and python3 both absent)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$EX/__pycache__"' EXIT

cat > "$WORK/comments.feature" <<'EOF'
Scenario: Real scenario stays intact
  Given cart_total 120.00
  And code "SAVE20"
  When discount is applied
  Then applied is true
  And final_total is 96.00
  And reason is "SAVE20 applied"

#Scenario: Commented-out clobber must be ignored (t-b878)
#  Given cart_total 40.00
#  And code "SAVE10"
#  When discount is applied
#  Then applied is false
#  And reason is "minimum not met"
EOF

check_output() {
  local label="$1" out="$2" rc="$3"
  [[ "$rc" -eq 0 ]] || fail "dsl-runner-comments: $label exited $rc — comment lines not skipped (the commented block clobbered the real scenario). Output: $out"
  assert_contains "$out" "Verdict: PASS"
  [[ "$out" != *FAIL* ]] || fail "dsl-runner-comments: $label reported FAIL — comment block clobbered the real scenario. Output: $out"
  local n; n="$(printf '%s\n' "$out" | grep -c 'Verdict:')"
  [[ "$n" -eq 1 ]] || fail "dsl-runner-comments: $label parsed $n scenarios, expected 1 — a commented '#Scenario:' leaked a scenario. Output: $out"
}

if [[ "$have_node" -eq 1 ]]; then
  set +e; out="$(node "$EX/app/dsl_runner.js" "$WORK/comments.feature" 2>&1)"; rc=$?; set -e
  check_output "node dsl_runner.js" "$out" "$rc"
fi

if [[ "$have_py" -eq 1 ]]; then
  # dsl_runner.py does `from discount import apply_discount`, resolved from its own dir.
  set +e; out="$(cd "$EX" && python3 dsl_runner.py "$WORK/comments.feature" 2>&1)"; rc=$?; set -e
  check_output "python3 dsl_runner.py" "$out" "$rc"
fi

echo "dsl-runner-comments: ok (# comment lines skipped by both runners; commented clobber block ignored, real scenario intact)"
