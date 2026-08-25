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

# _etime_to_seconds <etime> — converts ps -o etime='s "[[dd-]hh:]mm:ss" format
# to a plain integer count of seconds. Portable across BSD (macOS) and GNU
# (Linux) ps, which both use this same format for -o etime.
_etime_to_seconds() {
  local etime="$1" days=0 rest hh mm ss
  if [[ "$etime" == *-* ]]; then
    days="${etime%%-*}"
    rest="${etime#*-}"
  else
    rest="$etime"
  fi
  IFS=: read -r a b c <<< "$rest"
  if [[ -n "$c" ]]; then
    hh="$a"; mm="$b"; ss="$c"
  else
    hh=0; mm="$a"; ss="$b"
  fi
  echo $(( 10#$days*86400 + 10#$hh*3600 + 10#$mm*60 + 10#$ss ))
}

# sweep_stale_stub_processes [max_age_seconds] [root] — kills any bare
# `python3 -` process (t-2a71: the test-stub-daemon pattern spawned by
# `exec python3 - <<PY ... PY`, indistinguishable from anything else by argv
# alone) whose cwd is <root> (default: this repo's root) AND whose age
# exceeds max_age_seconds (default 300 — a generous ceiling above any single
# test run's real duration). A trap-based `cleanup EXIT` inside the test
# script itself cannot help here: it never runs at all if the process is
# SIGKILLed or its parent shell is torn down non-gracefully, which is exactly
# how these leak. Both gates are required — cwd alone would risk killing an
# unrelated python3 REPL a developer is running by hand in this same repo;
# age alone would risk killing a genuinely concurrent, still-legitimate test
# run's own live stub. On any doubt, this skips rather than kills — a missed
# sweep just means "still leaked, try again next run" (recoverable); a
# wrongful kill destroys someone's in-progress work (not recoverable).
sweep_stale_stub_processes() {
  command -v pgrep >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1 || return 0
  local max_age="${1:-300}" root="${2:-$ROOT}"
  local pid etime secs cwd
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')" || continue
    [[ -n "$etime" ]] || continue
    secs="$(_etime_to_seconds "$etime")"
    [[ "$secs" -gt "$max_age" ]] || continue
    cwd="$(lsof -p "$pid" 2>/dev/null | awk '$4=="cwd"{print $NF}')"
    [[ "$cwd" == "$root" ]] || continue
    kill "$pid" 2>/dev/null || true
  done < <(pgrep -f '^python3 -$' 2>/dev/null || true)
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
