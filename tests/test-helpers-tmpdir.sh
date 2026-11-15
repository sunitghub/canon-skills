#!/usr/bin/env bash
# t-fff4: tests/helpers.sh's mktemp wrapper. Protects every suite's hermetic scratch dirs (the evaluator's runs too): macOS mktemp
# ignores TMPDIR for `mktemp -d` and bare `mktemp`, so a suite that pinned TMPDIR still left folders under /var/folders/.../T.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(command mktemp -d "${TMPDIR:-/tmp}/helpers-tmpdir.XXXXXX")"; W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
for pin in "$W/a" "$W/b/"; do   # a TMPDIR with and without the trailing slash macOS gives it
  mkdir -p "$pin"; base="${pin%/}"
  d="$(TMPDIR="$pin" mktemp -d)"; [[ "$d" == "$base/"* && -d "$d" && "$d" != *//* ]] || fail "mktemp -d with TMPDIR=$pin made $d"
  f="$(TMPDIR="$pin" mktemp)"; [[ "$f" == "$base/"* && -f "$f" && "$f" != *//* ]] || fail "bare mktemp with TMPDIR=$pin made $f"
  p="$(TMPDIR="$pin" make_project)"; [[ "$p" == "$base/"* && -d "$p/.git" ]] || fail "make_project with TMPDIR=$pin made $p"
done
t="$(TMPDIR="$W/a" mktemp -d "$W/given.XXXXXX")"; [[ "$t" == "$W/given."* && -d "$t" && "$t" != *$'\n'* ]] || fail "a template was not passed through alone: $t"
o="$(TMPDIR="$W/a" mktemp "$W/one.XXXXXX")"; [[ "$o" == "$W/one."* && -f "$o" && "$o" != *$'\n'* ]] || fail "a one-argument template was not passed through alone: $o"
u="$(env -u TMPDIR bash -c 'source "$1"; mktemp -d' _ "$ROOT/tests/helpers.sh")"   # unset: the real mktemp, wherever it puts it
[[ -d "$u" ]] || fail "mktemp -d with TMPDIR unset made nothing: $u"; rm -rf "$u"
echo "test-helpers-tmpdir: ok"
