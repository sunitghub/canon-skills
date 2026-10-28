#!/usr/bin/env bash
# events-log (t-3137) — `canon log seal` and `canon log verify` through the real board binary and the shipped canon command. Protects
# the shipped command: the day-by-day words, the exit codes (1 for broken or missing), that a changed or deleted day is found and
# that putting it back makes the log intact again, and that an older board refuses instead of starting to serve.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
use_fresh_board "$W/bin"
mkdir -p "$W/userhome"
export CANON_HOME="$W/home" HOME="$W/userhome"   # HOME too: a writer that ignored CANON_HOME must not reach the real log
EV="$CANON_HOME/events"; mkdir -p "$EV"; chmod 700 "$EV"
CANON="$ROOT/tools/canon"
printf '{"a":1}\n{"a":2}\n' > "$EV/2020-01-01.jsonl"
printf '{"b":1}\n' > "$EV/2020-01-02.jsonl"
printf '{"c":1}\n' > "$EV/2020-01-03.jsonl"

out="$("$CANON" log verify)"
assert_contains "$out" "2020-01-01   unsealed"
assert_contains "$out" "0 intact, 0 broken, 0 missing, 3 unsealed"

out="$("$CANON" log seal)"; assert_eq "sealed 3 day(s)" "$out"
out="$("$CANON" log seal)"; assert_eq "sealed 0 day(s)" "$out"
out="$("$CANON" log verify)"
assert_contains "$out" "3 intact, 0 broken, 0 missing, 0 unsealed"
assert_contains "$out" "does not show who wrote it"

cp "$EV/2020-01-02.jsonl" "$W/keep.jsonl"
printf '{"b":2}\n' > "$EV/2020-01-02.jsonl"
set +e; out="$("$CANON" log verify)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "2020-01-02   broken"
cp "$W/keep.jsonl" "$EV/2020-01-02.jsonl"
"$CANON" log verify >/dev/null || fail "events-log: putting the day back did not make the log intact"

rm "$EV/2020-01-03.jsonl"
set +e; out="$("$CANON" log verify)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "2020-01-03   missing"

set +e; "$CANON" log nonsense >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code"

# an older board takes an unknown first word for a port and would serve: canon asks --help first and refuses
printf '#!/bin/sh\necho "usage: old board"\n' > "$W/old-board"; chmod +x "$W/old-board"
set +e; out="$(SPRINT_CHECK_BIN="$W/old-board" "$CANON" log verify 2>&1)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "is older than this command"
assert_contains "$("$CANON" completion bash)" "verify seal"
echo "events-log: ok"
