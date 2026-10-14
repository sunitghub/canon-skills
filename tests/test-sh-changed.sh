#!/usr/bin/env bash
# test-sh-changed (t-2633) — scripts/test.sh's --changed selection (scripts/test-select.sh) and its timing table. Selection runs on a
# throwaway git repo shaped like canon (tests/, tools/, a Go package dir, the neutral-path list); the timing table runs a copy of the
# real scripts/test.sh with two fake suites. Nothing touches the real tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sh-changed.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
REPO="$WORK/repo"; mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p tests tools/sprint-check-go scripts
cp "$ROOT/tools/evidence-neutral.sh" tools/; cp "$ROOT/scripts/test-select.sh" scripts/
printf 'bash "$ROOT/tools/alpha.sh"\n' > tests/a.sh                  # names a tool
printf 'bash "$ROOT/tools/beta.sh"\n' > tests/b.sh                   # names a tool that names another
printf 'const g = "gamma.txt";\n' > tests/c.js                       # names a data file by its base name
printf 'source "$(dirname "$0")/delta.sh"\n' > tools/beta.sh         # one level up: beta names delta
echo alpha > tools/alpha.sh; echo delta > tools/delta.sh; echo gamma > tools/gamma.txt
echo 'package main' > tools/sprint-check-go/main.go
echo orphan > tools/orphan.sh                                        # named by nothing
echo helper > tests/not-a-suite.sh                                   # in tests/, but not a suite test.sh runs
echo l > LEARNINGS.md
git add -A && git commit -qm base
BASE="$(git rev-parse HEAD)"
LABELS="$WORK/labels"; printf '%s\n' tests/a.sh tests/b.sh tests/c.js tools/sprint-check-go > "$LABELS"

source "$REPO/scripts/test-select.sh"
selected() {   # selected <base>: the labels select_suite picks, space-joined, or FULL:<reason>
  local l out=""
  select_init "$REPO" "$1" "$LABELS" || return $?
  while IFS= read -r l; do if select_suite "$l"; then out+="${out:+ }$l"; fi; done < "$LABELS"
  if [[ -n "$SELECT_FULL" ]]; then out="FULL[$out]"; fi
  select_cleanup; printf '%s' "$out"
}
reset() { git reset -q --hard "$BASE"; git clean -qfd; }

reset; echo more >> tools/alpha.sh; git commit -qam alpha
assert_eq "tests/a.sh" "$(selected "$BASE")"                                     # a committed change to a tool its suite names
reset; echo more >> tools/delta.sh
assert_eq "tests/b.sh" "$(selected "$BASE")"                                     # a working-tree change, one level up
reset; echo more >> tools/gamma.txt
assert_eq "tests/c.js" "$(selected "$BASE")"                                     # a base-name mention
reset; echo '// x' >> tests/c.js
assert_eq "tests/c.js" "$(selected "$BASE")"                                     # a changed suite runs itself
reset; echo '// x' >> tools/sprint-check-go/main.go
assert_eq "tools/sprint-check-go" "$(selected "$BASE")"                          # a Go package by its directory
reset; echo more >> LEARNINGS.md; git commit -qam learnings
assert_eq "" "$(selected "$BASE")"                                               # evidence-neutral only: nothing to run
reset; echo more >> tools/orphan.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tools/sprint-check-go]" "$(selected "$BASE")"   # named by nothing: everything
reset; echo more >> tests/not-a-suite.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tools/sprint-check-go]" "$(selected "$BASE")"   # in tests/ but no suite: everything
reset; echo more >> tools/alpha.sh; echo more >> tools/orphan.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tools/sprint-check-go]" "$(selected "$BASE")"   # one unmapped path is enough
reset; echo new > tools/untracked.sh
assert_eq "" "$(selected "$BASE")"                                               # untracked files are not seen ...
git add -N tools/untracked.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tools/sprint-check-go]" "$(selected "$BASE")"   # ... until intent-added
reset
set +e; out="$(selected not-a-ref 2>&1)"; rc=$?; set -e
assert_eq 2 "$rc"; assert_contains "$out" "'not-a-ref' is not a commit"
assert_eq "" "$(ls "$TMPDIR" | grep '^test-select\.' || true)"                  # select_cleanup removes its temp files

# --- the real scripts/test.sh: --list, --changed wiring, the timing table --------------------------------------------------------
LIST="$(bash "$ROOT/scripts/test.sh" --list)"
assert_eq "" "$(printf '%s\n' "$LIST" | sort | uniq -d)"                        # no suite listed twice
assert_contains "$LIST" "tests/test-sh-changed.sh"
while IFS= read -r l; do [[ -e "$ROOT/$l" ]] || fail "test.sh --list names $l, which does not exist"; done <<< "$LIST"
set +e; out="$(bash "$ROOT/scripts/test.sh" --bogus 2>&1)"; rc=$?; set -e; assert_eq 2 "$rc"; assert_contains "$out" "unknown option --bogus"
set +e; out="$(cd "$REPO" && bash "$ROOT/scripts/test.sh" --changed not-a-ref 2>&1)"; rc=$?; set -e; assert_eq 2 "$rc"

# A copy of the real runner whose suite list is two fakes: one slow, one failing. go and node are kept off PATH so only the fakes run.
T="$WORK/runner"; mkdir -p "$T/scripts" "$T/tests" "$T/tools" "$WORK/bin"
cp "$ROOT/scripts/test.sh" "$ROOT/scripts/test-select.sh" "$T/scripts/"; cp "$ROOT/tools/evidence-neutral.sh" "$T/tools/"
awk '/^tests=\(/{print; print "  \"$ROOT/tests/slow.sh\""; print "  \"$ROOT/tests/bad.sh\""; skip=1; next} skip && /^\)/{skip=0} !skip' \
  "$ROOT/scripts/test.sh" > "$T/scripts/test.sh"
printf 'sleep 1\necho slow-ok\n' > "$T/tests/slow.sh"; printf 'echo bad-runs; exit 3\n' > "$T/tests/bad.sh"
for b in bash sh git sort head tail mktemp grep sed awk cat rm sleep dirname cut wc tr comm ps pgrep uniq basename env; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$WORK/bin/$b"
done
set +e; out="$(PATH="$WORK/bin" bash "$T/scripts/test.sh" 2>&1)"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || fail "test.sh: a failing suite must fail the run: $out"
assert_contains "$out" "==> tests/slow.sh"; assert_contains "$out" "==> tests/bad.sh"; assert_contains "$out" "slow-ok"
assert_contains "$out" "== suite times (s), in run order"; assert_contains "$out" "tests/bad.sh (failed)"
assert_contains "$out" "== slowest 10 (s)"
slow_line="$(printf '%s\n' "$out" | sed -n '/^== slowest 10/,$p' | grep -m1 'tests/slow.sh')"
[[ "$slow_line" =~ ^[1-9][0-9]*\ tests/slow\.sh$ ]] || fail "test.sh: the slow suite's time is missing or zero: '$slow_line'"
[[ "$out" != *"PARTIAL RUN"* ]] || fail "test.sh: a full run must not call itself partial"

echo "test-sh-changed: ok"
