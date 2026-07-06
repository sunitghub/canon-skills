#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"
TKT="$TOOLS_DIR/tkt"
SPRINT="$TOOLS_DIR/sprint"
SKILLS="$ROOT/tools/skills.sh"
CANON_DEV="$ROOT/tools/canon-dev.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2"
  [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain '$needle'; got: $haystack"
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_dir_exists() {
  [[ -d "$1" ]] || fail "expected directory to exist: $1"
}

assert_grep() {
  local pattern="$1" file="$2"
  grep -qE "$pattern" "$file" || fail "expected $file to match $pattern"
}

assert_count() {
  local expected="$1" pattern="$2" file="$3" actual
  actual="$(grep -cF "$pattern" "$file" 2>/dev/null || true)"
  assert_eq "$expected" "$actual"
}

make_project() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

run_ok() {
  "$@"
}

run_fail() {
  local output rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "expected command to fail: $*"
  printf '%s\n' "$output"
}

# build_tickets_fixture <dir> — seeds <dir>/.tickets with t-placeholder (no
# plan approval, no Sign-off section) and t-ready (approved plan) — the
# minimal pair that exercises acceptance_has_items/plan_has_approach/
# plan_approved computation. Shared by sprint-check-server.sh and
# sprint-check-api-parity.sh so both test against one fixture definition.
build_tickets_fixture() {
  local dir="$1"
  mkdir -p "$dir/.tickets/t-placeholder" "$dir/.tickets/t-ready"

  cat > "$dir/.tickets/t-placeholder/ticket.md" <<'EOF'
---
id: t-placeholder
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Placeholder plan
EOF
  cat > "$dir/.tickets/t-placeholder/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Has criteria

## Test Plan
- [x] Has tests
EOF
  cat > "$dir/.tickets/t-placeholder/plan.md" <<'EOF'
# Plan

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->

## Decisions
EOF

  cat > "$dir/.tickets/t-ready/ticket.md" <<'EOF'
---
id: t-ready
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Ready plan
EOF
  cat > "$dir/.tickets/t-ready/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Has criteria

## Test Plan
- [x] Has tests
EOF
  cat > "$dir/.tickets/t-ready/plan.md" <<'EOF'
# Plan

## Sign-off
- [x] Plan approved

## Approach
Use the smallest board-side check that catches untouched templates.

## Decisions
EOF
}
