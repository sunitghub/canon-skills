#!/usr/bin/env bash
# t-fff4 / t-7ab9: tools/platform-lib.sh's mktemp wrapper. macOS mktemp ignores TMPDIR for `mktemp -d` and bare `mktemp`: a suite that pinned
# TMPDIR still left folders under /var/folders/.../T, and canon's commands failed inside Claude Code's sandbox (sprint start/approve, gate
# snapshots). Protects every suite's hermetic scratch dirs and every canon command a sandboxed session runs.
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

# t-7ab9: one home. tests/helpers.sh gets the wrapper from platform-lib.sh, never a copy of its own.
grep -qE '^[[:space:]]*mktemp[[:space:]]*\(\)' "$ROOT/tests/helpers.sh" && fail "tests/helpers.sh defines its own mktemp(); it comes from tools/platform-lib.sh"
grep -qE '^mktemp\(\) \{' "$ROOT/tools/platform-lib.sh" || fail "tools/platform-lib.sh has no mktemp() wrapper"

# t-7ab9: every tools/ file with a bare `mktemp` reaches the wrapper. A file reaches it when it loads platform-lib.sh, ticket-root.sh (its line 5)
# or skills/lib.sh outside any function; a library loaded by others passes when every file that loads it reaches platform-lib.sh first.
# canon-dev.sh is contributor tooling, run on the maintainer's host only; platform-lib.sh owns the wrapper.
LOADS='^[[:space:]]*(source|[.])[[:space:]].*(platform-lib|ticket-root|skills/lib)[.]sh'   # [.], not \.: awk -v turns \. into .
top_level_load() {   # <file>: a LOADS line outside every function body
  awk -v re="$LOADS" '
    /^[A-Za-z_][A-Za-z0-9_:-]*\(\)[[:space:]]*\{/ { if ($0 !~ /\}[[:space:]]*$/) depth++; next }
    depth > 0 && /^\}/ { depth--; next }
    depth == 0 && $0 ~ re { found = 1 }
    END { exit !found }' "$1"
}
loads_before() {   # <loader> <lib rel path>: a platform-lib-reaching line before the lib's own source line
  awk -v re="$LOADS" -v lib="$2" '
    $0 ~ re { seen = 1 }
    $0 ~ /^[[:space:]]*(source|[.])[[:space:]]/ && index($0, lib) { if (!seen) bad = 1; any = 1 }
    END { exit (bad || !any) }' "$1"
}
LIBS=" gate-scope-lib.sh skills/cmd-refresh.sh skills/project.sh skills/prompts.sh "
n=0
while IFS= read -r f; do
  rel="${f#"$ROOT/tools/"}"
  case "$rel" in canon-dev.sh|platform-lib.sh) continue ;; esac
  n=$((n + 1))
  if [[ "$LIBS" == *" $rel "* ]]; then
    loaders="$(grep -rlE "^[[:space:]]*(source|\.)[[:space:]].*${rel//./\\.}" "$ROOT/tools" --exclude-dir=canon-go --exclude-dir=sprint-check-app --exclude='*.md' || true)"
    [[ -n "$loaders" ]] || fail "$rel is listed as a library but nothing under tools/ loads it"
    while IFS= read -r l; do top_level_load "$l" || loads_before "$l" "$rel" || fail "${l#"$ROOT/"} loads $rel without platform-lib.sh first: its bare mktemp ignores TMPDIR on macOS"; done <<< "$loaders"
  else
    top_level_load "$f" || fail "tools/$rel calls a bare mktemp but does not load platform-lib.sh outside a function (or add it to LIBS with its loaders)"
  fi
done < <(grep -rlE '\$\(mktemp( -d)?\)' "$ROOT/tools" --exclude-dir=canon-go --exclude-dir=sprint-check-app --exclude='*.md')
[[ "$n" -ge 10 ]] || fail "the bare-mktemp scan found only $n files: the scan itself is broken"
echo "test-helpers-tmpdir: ok"
