#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"
TKT="$TOOLS_DIR/tkt"
SPRINT="$TOOLS_DIR/sprint"
SKILLS="$ROOT/tools/skills.sh"

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
