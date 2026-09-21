#!/usr/bin/env bash
# plugin-eval-gen — tools/plugin-eval-gen turns a skill's evals.json into a
# throwaway `claude plugin eval` plugin. Runs the real generator (no model
# calls) and asserts its output; the reject cases feed the guards inputs they
# must refuse.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# Guarded skip: this script is in scripts/test.sh's mandatory list, so an
# unconditional jq under `set -euo pipefail` would abort the suite without it.
if ! command -v jq >/dev/null 2>&1; then
  echo "plugin-eval-gen: jq absent — skipped"
  exit 0
fi

GEN="$ROOT/tools/plugin-eval-gen"
REL=".canon-cache/plugin-eval-test-$$"
OUT="$ROOT/$REL"
trap 'rm -rf "$OUT"' EXIT

"$GEN" capture --plugin-dir "$REL" >/dev/null
"$GEN" wrapup --plugin-dir "$REL" >/dev/null

# Structure: one case dir per evals.json entry, valid manifest, skill copied without evals/.
expected="$(jq '.evals | length' "$ROOT/skills/capture/evals/evals.json")"
actual="$(find "$OUT/evals" -maxdepth 1 -type d -name 'capture-*' | wc -l | tr -d ' ')"
assert_eq "$expected" "$actual"
jq -e .name "$OUT/.claude-plugin/plugin.json" >/dev/null || fail "plugin.json is not valid JSON with a name"
assert_file_exists "$OUT/skills/capture/SKILL.md"
[[ ! -e "$OUT/skills/capture/evals" ]] || fail "copied skill still carries evals/"

# Prompt: the "/capture " invocation is replaced with plain text.
first="$(sed -n 6p "$OUT/evals/capture-1/prompt.md")"
assert_contains "$first" "Use the capture skill: "
[[ "$first" != /capture* ]] || fail "prompt still starts with /capture"

# Tools: read-only by default, --write adds Write/Edit/Bash.
assert_grep '^allowed_tools: \[Read, Glob, Grep, Skill\]$' "$OUT/evals/capture-1/prompt.md"
"$GEN" capture --write --plugin-dir "$REL" >/dev/null
assert_grep '^allowed_tools: \[.*Write, Edit, Bash\]$' "$OUT/evals/capture-1/prompt.md"

# Memory: capture-1 expects a memory save, so the bullet is dropped by default and
# kept with --keep-memory.
"$GEN" capture --plugin-dir "$REL" >/dev/null
if grep -qiE '^- .*memory' "$OUT/evals/capture-1/graders/criteria.md"; then
  fail "memory expectation survived the default filter"
fi
assert_grep '^Ignore any mention of a failed or skipped memory save\.$' "$OUT/evals/capture-1/graders/criteria.md"
"$GEN" capture --keep-memory --plugin-dir "$REL" >/dev/null
assert_grep '^- .*[Mm]emory' "$OUT/evals/capture-1/graders/criteria.md"

# skill-fired grader: present for a control case, absent for a boundary case
# (wrapup-1 is control, wrapup-3 is boundary in skills/wrapup/evals/evals.json).
assert_file_exists "$OUT/evals/wrapup-1/graders/skill-fired.md"
[[ ! -e "$OUT/evals/wrapup-3/graders/skill-fired.md" ]] || fail "boundary case got a skill-fired grader"

# Guards must reject: absolute or '..' plugin dir, unknown skill.
rc=0; "$GEN" capture --plugin-dir /tmp/x >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc"
rc=0; "$GEN" capture --plugin-dir ../x >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc"
rc=0; "$GEN" no-such-skill --plugin-dir "$REL" >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc"

echo "plugin-eval-gen: ok"
