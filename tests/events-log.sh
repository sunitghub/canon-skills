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
assert_contains "$out" "2020-01-01   unsealed  (closed, not sealed yet)"
assert_contains "$out" "0 intact, 0 broken, 0 missing, 3 unsealed"

out="$("$CANON" log seal)"; assert_eq "sealed 3 day(s)" "$out"
out="$("$CANON" log seal)"; assert_eq "sealed 0 day(s)" "$out"
out="$("$CANON" log verify)"
assert_contains "$out" "3 intact, 0 broken, 0 missing, 0 unsealed"
assert_contains "$out" "does not show who wrote it"

cp "$EV/2020-01-02.jsonl" "$W/keep.jsonl"; cp "$EV/2020-01-03.jsonl" "$W/keep3.jsonl"
printf '{"b":2}\n' > "$EV/2020-01-02.jsonl"
set +e; out="$("$CANON" log verify)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "2020-01-02   broken"
cp "$W/keep.jsonl" "$EV/2020-01-02.jsonl"
"$CANON" log verify >/dev/null || fail "events-log: putting the day back did not make the log intact"

rm "$EV/2020-01-03.jsonl"
set +e; out="$("$CANON" log verify)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "2020-01-03   missing  (sealed but its file is gone)"
assert_contains "$out" "2 intact, 0 broken, 1 missing, 0 unsealed"
printf '{"b":2}\n' > "$EV/2020-01-02.jsonl"   # one broken and one missing at once
out="$("$CANON" log verify || true)"
assert_contains "$out" "2020-01-02   broken  (does not match its seal)"
assert_contains "$out" "1 intact, 1 broken, 1 missing, 0 unsealed"
cp "$W/keep.jsonl" "$EV/2020-01-02.jsonl"; cp "$W/keep3.jsonl" "$EV/2020-01-03.jsonl"
"$CANON" log verify >/dev/null || fail "events-log: restoring the days did not make the log intact"

set +e; out="$("$CANON" log nonsense 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "usage: canon log verify | seal"
set +e; out="$("$CANON" log 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; assert_contains "$out" "usage: canon log verify | seal"

# seal that cannot finish exits 1 and says why: the seal file is a link
mkdir -p "$W/other"; : > "$W/other/target"
printf '{"d":1}\n' > "$EV/2020-01-04.jsonl"
mv "$EV/seals.jsonl" "$W/seals.keep"; ln -s "$W/other/target" "$EV/seals.jsonl"
set +e; out="$("$CANON" log seal 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "canon log seal:"
rm "$EV/seals.jsonl"; mv "$W/seals.keep" "$EV/seals.jsonl"

# a fresh install has no log: nothing to check is not a failure
CANON_HOME="$W/empty-home" "$CANON" log verify | grep -F "no activity log yet" >/dev/null || fail "events-log: a missing log was not said"

# an older board takes an unknown first word for a port and would serve: canon asks --help first and refuses
printf '#!/bin/sh\necho "usage: old board"\n' > "$W/old-board"; chmod +x "$W/old-board"
set +e; out="$(SPRINT_CHECK_BIN="$W/old-board" "$CANON" log verify 2>&1)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "is older than this command"
assert_contains "$("$CANON" completion bash)" "verify seal"
echo "events-log: ok"
