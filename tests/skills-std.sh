#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# The real skills/ must always lint clean.
clean_output="$("$CANON_DEV" lint)"
assert_contains "$clean_output" "skills lint: clean"

# Fixtures with known violations must be caught.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture" "${pfix:-}" "${hfix:-}" "${deg_fix:-}"' EXIT

# Valid skill in directory format — must not be flagged (structural OR advisory).
mkdir -p "$fixture/good-skill/evals"
cat > "$fixture/good-skill/SKILL.md" <<'EOF'
---
name: good-skill
description: Exercises the linter with a structurally valid skill fixture. Use when running the skills-std suite.
category: dev
tags: [test]
---

```css
@keyframes fadeUp {
  from { opacity: 0; }
  to { opacity: 1; }
}
```
EOF
cat > "$fixture/good-skill/evals/evals.json" <<'EOF'
{"skill_name": "good-skill", "evals": [{"id": 1}, {"id": 2}, {"id": 3}]}
EOF

# name does not match directory name + unknown category.
mkdir -p "$fixture/bad-skill"
cat > "$fixture/bad-skill/SKILL.md" <<'EOF'
---
name: wrong-name
description: Name does not match directory name
category: nonsense
tags: [x]
---
EOF

# Missing description + empty tags.
mkdir -p "$fixture/missing-fields"
cat > "$fixture/missing-fields/SKILL.md" <<'EOF'
---
name: missing-fields
category: dev
tags: []
---
EOF

# Flat file — violates the directory-format rule.
cat > "$fixture/flat-skill.md" <<'EOF'
---
name: flat-skill
description: Should not be a flat file
category: dev
tags: [x]
---
EOF

# Sibling import not declared in depends + a depends entry that resolves nowhere.
mkdir -p "$fixture/graph-skill"
cat > "$fixture/graph-skill/SKILL.md" <<'EOF'
---
name: graph-skill
description: Import not declared, plus a stale dep
category: dev
tags: [x]
depends: [no-such-skill]
---
@../good-skill/SKILL.md
EOF

# One-job violation: a leaf skill chains actions with "and then".
mkdir -p "$fixture/chained"
cat > "$fixture/chained/SKILL.md" <<'EOF'
---
name: chained
description: Map the subsystem and then edit every file it touches
category: dev
tags: [x]
---
EOF

# Vague: description too short to convey scope.
mkdir -p "$fixture/terse"
cat > "$fixture/terse/SKILL.md" <<'EOF'
---
name: terse
description: Does things
category: dev
tags: [x]
---
EOF

out="$(run_fail "$CANON_DEV" lint "$fixture")"
assert_contains "$out" "name 'wrong-name' does not match directory name"
assert_contains "$out" "category 'nonsense' not in"
assert_contains "$out" "missing required field 'description'"
assert_contains "$out" "missing required field 'tags'"
assert_contains "$out" "must be in directory format"
assert_contains "$out" "imports 'good-skill' but 'good-skill' is not in depends"
assert_contains "$out" "depends entry 'no-such-skill' does not resolve"
assert_contains "$out" "chained/SKILL.md: description chains actions ('and then')"
assert_contains "$out" "terse/SKILL.md: description too short"
[[ "$out" != *"good-skill/SKILL.md:"* ]] || fail "valid skill should not be flagged"


# ---------------------------------------------------------------------------
# Advisory prose / best-practice layer (non-blocking unless --strict).
# ---------------------------------------------------------------------------

# Structurally VALID fixtures that only trip advisory checks — the whole run
# must still exit 0, and each finding must carry its stable check id.
pfix="$(mktemp -d)"

mkdir -p "$pfix/noop-directive"
cat > "$pfix/noop-directive/SKILL.md" <<'EOF'
---
name: noop-directive
description: Valid fixture. Use when testing no-op detection in the suite.
category: dev
tags: [test]
---

## Guidance

- Be thorough.
- Write clean, high-quality code.
EOF

mkdir -p "$pfix/noop-safe"
cat > "$pfix/noop-safe/SKILL.md" <<'EOF'
---
name: noop-safe
description: Valid fixture. Use when testing no-op skip logic in the suite.
category: dev
tags: [test]
---

## Guidance

Reviewers must not "be thorough" in the hollow sense; that phrase is filler.
Terms like `make sure to` are stripped during export.
EOF

mkdir -p "$pfix/person-skill"
cat > "$pfix/person-skill/SKILL.md" <<'EOF'
---
name: person-skill
description: I can help you run the fixture tests when you ask me to.
category: dev
tags: [test]
---

Body.
EOF

mkdir -p "$pfix/notrigger-skill"
cat > "$pfix/notrigger-skill/SKILL.md" <<'EOF'
---
name: notrigger-skill
description: Formats and validates fixture output for the test suite here.
category: dev
tags: [test]
---

Body.
EOF

mkdir -p "$pfix/atimport-skill"
printf 'notes\n' > "$pfix/atimport-skill/note.md"
cat > "$pfix/atimport-skill/SKILL.md" <<'EOF'
---
name: atimport-skill
description: Valid fixture. Use when testing deprecated at-import detection here.
category: dev
tags: [test]
---

@./note.md
EOF

mkdir -p "$pfix/time-skill"
cat > "$pfix/time-skill/SKILL.md" <<'EOF'
---
name: time-skill
description: Valid fixture. Use when testing time-sensitive detection here.
category: dev
tags: [test]
---

Before August 2025, use the old API.
EOF

mkdir -p "$pfix/evalcount-skill/evals"
cat > "$pfix/evalcount-skill/SKILL.md" <<'EOF'
---
name: evalcount-skill
description: Valid fixture. Use when testing eval-count detection here.
category: dev
tags: [test]
---

Body.
EOF
cat > "$pfix/evalcount-skill/evals/evals.json" <<'EOF'
{"skill_name": "evalcount-skill", "evals": [{"id": 1}]}
EOF

mkdir -p "$pfix/reftoc-skill/reference"
cat > "$pfix/reftoc-skill/SKILL.md" <<'EOF'
---
name: reftoc-skill
description: Valid fixture. Use when testing reference-TOC detection here.
category: dev
tags: [test]
---

Body.
EOF
{ echo "# Big Reference"; for i in $(seq 1 130); do echo "line $i"; done; } > "$pfix/reftoc-skill/reference/big.md"

mkdir -p "$pfix/bodylen-skill"
{ cat <<'EOF'
---
name: bodylen-skill
description: Valid fixture. Use when testing the body length cap here.
category: dev
tags: [test]
---
EOF
  for i in $(seq 1 520); do echo "line $i"; done; } > "$pfix/bodylen-skill/SKILL.md"

mkdir -p "$pfix/cap-skill"
cap_desc="Use when testing the description cap. $(for _ in $(seq 1 400); do printf 'padding '; done)"
cat > "$pfix/cap-skill/SKILL.md" <<EOF
---
name: cap-skill
description: $cap_desc
category: dev
tags: [test]
---

Body.
EOF

# Advisory run: warnings are non-blocking, so exit status is 0.
padv="$("$CANON_DEV" lint "$pfix")" || fail "advisory prose warnings must not change exit code (expected 0)"
assert_contains "$padv" "noop-directive/SKILL.md: warning: SP-NOOP"
assert_contains "$padv" "person-skill/SKILL.md: warning: SP-DESC-PERSON"
assert_contains "$padv" "notrigger-skill/SKILL.md: warning: SP-DESC-TRIGGER"
assert_contains "$padv" "atimport-skill/SKILL.md: warning: SP-ATIMPORT"
assert_contains "$padv" "time-skill/SKILL.md: warning: SP-TIME"
assert_contains "$padv" "evalcount-skill/SKILL.md: warning: SP-EVALS-COUNT"
assert_contains "$padv" "reftoc-skill/reference/big.md: warning: SP-REF-TOC"
assert_contains "$padv" "bodylen-skill/SKILL.md: warning: SP-BODYLEN"
assert_contains "$padv" "cap-skill/SKILL.md: warning: SP-DESC-CAP"
assert_contains "$padv" "warning: SP-EVALS-MISSING"
assert_contains "$padv" "skills lint: clean ("
# No-op detector must skip quoted / backticked / negated occurrences.
[[ "$padv" != *"noop-safe/SKILL.md: warning: SP-NOOP"* ]] || fail "SP-NOOP should skip quoted/backticked/negated no-ops"

# --strict promotes every advisory warning to a blocking error.
strict_out="$(run_fail "$CANON_DEV" lint "$pfix" --strict)"
assert_contains "$strict_out" "issue(s) found."

# hidden consistency: a skill in another skill's depends: that isn't hidden.
hfix="$(mktemp -d)"
mkdir -p "$hfix/parent-skill" "$hfix/child-skill"
cat > "$hfix/parent-skill/SKILL.md" <<'EOF'
---
name: parent-skill
description: Valid fixture. Use when testing hidden-consistency detection here.
category: dev
tags: [test]
depends: [child-skill]
---
EOF
cat > "$hfix/child-skill/SKILL.md" <<'EOF'
---
name: child-skill
description: Valid fixture. Use when testing hidden-consistency detection here.
category: dev
tags: [test]
---
EOF
hidden_out="$(run_fail "$CANON_DEV" lint "$hfix")"
assert_contains "$hidden_out" "child-skill/SKILL.md: warning: SP-HIDDEN"

# Graceful degradation: no python3 → skip advisory layer, structural lint still runs.
deg_fix="$(mktemp -d)"
mkdir -p "$deg_fix/plain-skill/evals"
cat > "$deg_fix/plain-skill/SKILL.md" <<'EOF'
---
name: plain-skill
description: Valid fixture. Use when testing python3 degradation here.
category: dev
tags: [test]
---

Body.
EOF
cat > "$deg_fix/plain-skill/evals/evals.json" <<'EOF'
{"skill_name": "plain-skill", "evals": [{"id": 1}, {"id": 2}, {"id": 3}]}
EOF
deg_out="$(CANON_DEV_PYTHON=python3-nonexistent-xyz "$CANON_DEV" lint "$deg_fix")" || fail "structural lint must still run without python3"
assert_contains "$deg_out" "advisory prose checks skipped"
assert_contains "$deg_out" "skills lint: clean"
