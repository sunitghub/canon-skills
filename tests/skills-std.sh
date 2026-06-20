#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# The real skills/ must always lint clean.
clean_output="$("$CANON_DEV" lint)"
assert_contains "$clean_output" "skills lint: clean"

# Fixtures with known violations must be caught.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Valid skill in directory format — must not be flagged.
mkdir -p "$fixture/good-skill"
cat > "$fixture/good-skill/SKILL.md" <<'EOF'
---
name: good-skill
description: Exercise the linter with a structurally valid skill fixture
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
