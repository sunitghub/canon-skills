#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# The real skills/ must always lint clean.
clean_output="$("$SKILLS" lint)"
assert_contains "$clean_output" "skills lint: clean"

# Fixtures with known violations must be caught.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Valid skill — must not be flagged.
cat > "$fixture/good-skill.md" <<'EOF'
---
name: good-skill
description: Exercise the linter with a structurally valid skill fixture
category: dev
tags: [test]
---
EOF

# name does not match filename + unknown category.
cat > "$fixture/bad-skill.md" <<'EOF'
---
name: wrong-name
description: Name does not match filename
category: nonsense
tags: [x]
---
EOF

# Missing description + empty tags.
cat > "$fixture/missing-fields.md" <<'EOF'
---
name: missing-fields
category: dev
tags: []
---
EOF

# Nested skill — violates the flat-location rule.
mkdir -p "$fixture/sub"
cat > "$fixture/sub/nested.md" <<'EOF'
---
name: nested
description: Should not live in a subdirectory
category: dev
tags: [x]
---
EOF

# Sibling import not declared in depends + a depends entry that resolves nowhere.
cat > "$fixture/graph-skill.md" <<'EOF'
---
name: graph-skill
description: Import not declared, plus a stale dep
category: dev
tags: [x]
depends: [no-such-skill]
---
@./good-skill.md
EOF

# One-job violation: a leaf skill chains actions with "and then".
cat > "$fixture/chained.md" <<'EOF'
---
name: chained
description: Map the subsystem and then edit every file it touches
category: dev
tags: [x]
---
EOF

# Vague: description too short to convey scope.
cat > "$fixture/terse.md" <<'EOF'
---
name: terse
description: Does things
category: dev
tags: [x]
---
EOF

out="$(run_fail "$SKILLS" lint "$fixture")"
assert_contains "$out" "name 'wrong-name' does not match filename"
assert_contains "$out" "category 'nonsense' not in"
assert_contains "$out" "missing required field 'description'"
assert_contains "$out" "missing required field 'tags'"
assert_contains "$out" "must live flat under skills/"
assert_contains "$out" "imports '@./good-skill.md' but 'good-skill' is not in depends"
assert_contains "$out" "depends entry 'no-such-skill' does not resolve"
assert_contains "$out" "chained.md: description chains actions ('and then')"
assert_contains "$out" "terse.md: description too short"
[[ "$out" != *"good-skill.md:"* ]] || fail "valid skill should not be flagged"
