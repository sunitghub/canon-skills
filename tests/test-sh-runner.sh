#!/usr/bin/env bash
# test-sh-runner (t-2633) — scripts/test.sh's own behaviour: `--list` (the one list of suites; scripts/test-hermetic.sh reads it), and
# the timing table every run prints. The table runs on a copy of the real runner whose suite list is replaced by fakes, with go and
# node kept off PATH. Nothing touches the real tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sh-runner.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export SPRINT_CHECK_NO_BROWSER=1   # tests/no-browser-in-tests.sh reads any sprint-check-go mention as a board start; none starts here
export LC_ALL=C TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

# --- --list ---------------------------------------------------------------------------------------------------------------------
LIST="$(bash "$ROOT/scripts/test.sh" --list)"
assert_eq "" "$(printf '%s\n' "$LIST" | sort | uniq -d)"                        # no suite listed twice
while IFS= read -r l; do [[ -e "$ROOT/$l" ]] || fail "test.sh --list names $l, which does not exist"; done <<< "$LIST"
# the dry pass reaches every invocation in the file: the .sh labels are the tests=( array, the .js labels every node line, plus the Go three
assert_eq "$(awk '/^tests=\(/{f=1;next} /^\)/{f=0} f' "$ROOT/scripts/test.sh" | grep -c 'tests/')" "$(printf '%s\n' "$LIST" | grep -c '\.sh$')"
assert_eq "$(grep -c '^  suite tests/[^ ]*\.js node "\$ROOT/tests/' "$ROOT/scripts/test.sh")" "$(printf '%s\n' "$LIST" | grep -c '\.js$')"
for g in tools/sprint-check-go tools/sprint-headless-json-go tools/cockpit-daemon; do assert_contains "$LIST" "$g"; done
assert_contains "$LIST" "tests/test-sh-runner.sh"
set +e; out="$(bash "$ROOT/scripts/test.sh" --help 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "usage: scripts/test.sh [--list]"
set +e; out="$(bash "$ROOT/scripts/test.sh" --bogus 2>&1)"; rc=$?; set -e; assert_eq 2 "$rc"; assert_contains "$out" "test.sh: unknown option --bogus"

# --- copies of the real runner with fake suites; go and node kept off PATH -----------------------------------------------------------
mkdir -p "$WORK/bin"
for b in bash sh git sort head tail mktemp grep sed awk cat rm sleep dirname cut wc tr comm ps pgrep uniq basename env ls; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$WORK/bin/$b"
done
runner_copy() {   # runner_copy <dir> <suite...>: the real test.sh with its tests=( list replaced by the given suites
  local d="$1"; shift
  mkdir -p "$d/scripts" "$d/tests"
  { awk '/^tests=\(/{exit} {print}' "$ROOT/scripts/test.sh"; echo 'tests=('; for t in "$@"; do echo "  \"\$ROOT/$t\""; done; echo ')'
    awk 'f; /^tests=\(/{s=1} s && /^\)/{f=1}' "$ROOT/scripts/test.sh"; } > "$d/scripts/test.sh"
}

# A failing run: twelve timed suites, the slowest first, the failing one timed and marked, the run's own exit code kept.
T="$WORK/runner"; names=(tests/slow.sh); for k in 01 02 03 04 05 06 07 08 09 10; do names+=("tests/t$k.sh"); done; names+=(tests/bad.sh)
runner_copy "$T" "${names[@]}"
printf 'sleep 2\necho slow-ok\n' > "$T/tests/slow.sh"; printf 'sleep 1\necho bad-runs; exit 3\n' > "$T/tests/bad.sh"
for k in 01 02 03 04 05 06 07 08 09 10; do echo 'true' > "$T/tests/t$k.sh"; done
set +e; out="$(PATH="$WORK/bin" bash "$T/scripts/test.sh" 2>&1)"; rc=$?; set -e
assert_eq 3 "$rc"                                                                  # the failing suite's own code
assert_contains "$out" "==> tests/slow.sh"; assert_contains "$out" "slow-ok"; assert_contains "$out" "==> tests/bad.sh"
assert_contains "$out" "== suite times (s), in run order"; assert_contains "$out" "== total "; assert_contains "$out" "for 12 suite(s)"
slowest="$(printf '%s\n' "$out" | sed -n '/^== slowest 10 (s)$/,/^== total/p' | sed '1d;$d')"
assert_eq 10 "$(printf '%s\n' "$slowest" | wc -l | tr -d ' ')"
[[ "$(printf '%s\n' "$slowest" | head -1)" =~ ^[2-9]\ tests/slow\.sh$ ]] || fail "test.sh: slowest 10 must start with the slow suite: $slowest"
[[ "$out" =~ (^|$'\n')[1-9][0-9]*\ tests/bad\.sh\ \(failed\) ]] || fail "test.sh: the failing suite's time is missing or zero: $out"

# A passing run: exit 0, each go/node skip line printed once (never from the dry pass), and --list unchanged by go/node being absent.
P="$WORK/pass"; runner_copy "$P" tests/a.sh tests/b.sh
echo 'echo a-ran' > "$P/tests/a.sh"; echo 'echo b-ran' > "$P/tests/b.sh"
set +e; out="$(PATH="$WORK/bin" bash "$P/scripts/test.sh" 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "a-ran"; assert_contains "$out" "b-ran"; assert_contains "$out" "All tests passed."
for skipped_line in "==> tools/sprint-check-go skipped (go absent)" "==> tools/sprint-headless-json-go skipped (go absent)" \
  "==> tools/cockpit-daemon skipped (go absent)" "==> tests/sprint-check-gherkin.js skipped (node absent)"; do
  assert_eq 1 "$(printf '%s\n' "$out" | grep -cxF "$skipped_line")"
done
set +e; out="$(PATH="$WORK/bin" bash "$P/scripts/test.sh" --list 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_eq 17 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"; [[ "$out" != *"==>"* ]] || fail "--list printed a run line: $out"

echo "test-sh-runner: ok"
