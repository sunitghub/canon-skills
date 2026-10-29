#!/usr/bin/env bash
# samples-events (t-4371) — protects the activity log's documented read rules (docs/plugins.md "Where events are": file name order,
# line order, drop a seen id, resume by file name + byte offset, a new day is a new file) that every event reader relies on. It runs
# samples/events/tail-closes against a fixture events folder and asserts the exact output, so a format change or a reader that
# breaks the rules fails here. Hermetic: CANON_HOME, HOME, TMPDIR and XDG_CONFIG_HOME are pinned to a temp dir.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
SAMPLE="${TAIL_CLOSES:-$ROOT/samples/events/tail-closes/tail-closes}"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export CANON_HOME="$W/home/.canon" HOME="$W/home" TMPDIR="$W" XDG_CONFIG_HOME="$W/xdg"
mkdir -p "$CANON_HOME/events"
E="$CANON_HOME/events"
canary="$HOME/.canon/canary"; : >"$canary"

ev() { # ev <id> <ts> <kind> <ticket> : one v1 event line
  printf '{"schema":1,"id":"%s","ts":"%s","kind":"%s","source":"tkt","project":"/p/app","data":{"ticket":"%s"}}\n' "$1" "$2" "$3" "$4"
}
# day 1: a close, another kind, a duplicate id (a second writer), a merge written late (ts out of order), a close at 23:59
{ ev a1 2026-10-20T08:00:00.000Z close.confirmed t-0001
  ev a2 2026-10-20T08:01:00.000Z ticket.created t-0002
  ev a1 2026-10-20T08:00:00.000Z close.confirmed t-0001
  ev a3 2026-10-20T09:30:00.000Z github.merged t-0003
  ev a4 2026-10-20T09:00:00.000Z close.confirmed t-0004
  ev a5 2026-10-20T23:59:59.900Z close.confirmed t-0005; } >"$E/2026-10-20.jsonl"
# day 2 (written first on disk, read second by name): the midnight rollover
{ ev b1 2026-10-21T00:00:00.100Z github.merged t-0006
  ev a5 2026-10-20T23:59:59.900Z close.confirmed t-0005
  printf 'not json at all\n'
  ev b2 2026-10-21T00:05:00.000Z close.confirmed t-0007; } >"$E/2026-10-21.jsonl"

want="2026-10-20T08:00:00.000Z close.confirmed /p/app t-0001
2026-10-20T09:30:00.000Z github.merged /p/app t-0003
2026-10-20T09:00:00.000Z close.confirmed /p/app t-0004
2026-10-20T23:59:59.900Z close.confirmed /p/app t-0005
2026-10-21T00:00:00.100Z github.merged /p/app t-0006
2026-10-21T00:05:00.000Z close.confirmed /p/app t-0007"

got="$("$SAMPLE")" || fail "tail-closes exited non-zero on the fixture"
# exact output: file then line order (not ts order), once per id, only the two kinds
[[ "$got" == "$want" ]] || fail "output differs from the fixture's expected lines:
--- got
$got
--- want
$want"

# resume: a saved file + offset reads only what was appended, across a day boundary, drops an id seen in an earlier run, and never reads a half-written line
S="$W/state"
first="$("$SAMPLE" --state "$S")"; [[ "$first" == "$want" ]] || fail "first run with --state differs from a run without it"
size="$(wc -c <"$E/2026-10-21.jsonl" | tr -d ' ')"
read -r sname soff <"$S"
[[ "$sname $soff" == "2026-10-21.jsonl $size" ]] || fail "state starts '$sname $soff', expected '2026-10-21.jsonl $size'"
[[ -z "$("$SAMPLE" --state "$S")" ]] || fail "a second run with nothing new printed lines (re-read from the start)"
ev b3 2026-10-21T10:00:00.000Z close.confirmed t-0008 >>"$E/2026-10-21.jsonl"
ev b2 2026-10-21T00:05:00.000Z close.confirmed t-0007 >>"$E/2026-10-21.jsonl"
ev c1 2026-10-22T00:00:01.000Z github.merged t-0009 >"$E/2026-10-22.jsonl"
printf '{"schema":1,"id":"c2","ts":"2026-10-22T00:00:02.000Z","kind":"close.conf' >>"$E/2026-10-22.jsonl"
got="$("$SAMPLE" --state "$S")"
want2="2026-10-21T10:00:00.000Z close.confirmed /p/app t-0008
2026-10-22T00:00:01.000Z github.merged /p/app t-0009"
[[ "$got" == "$want2" ]] || fail "resume output differs:
--- got
$got
--- want
$want2"
# the half line is read once it is finished
printf 'irmed","source":"tkt","project":"/p/app","data":{"ticket":"t-0010"}}\n' >>"$E/2026-10-22.jsonl"
got="$("$SAMPLE" --state "$S")"
[[ "$got" == "2026-10-22T00:00:02.000Z close.confirmed /p/app t-0010" ]] || fail "the finished line was not read: '$got'"

# a bad option and a missing folder fail loudly
if "$SAMPLE" --bogus >/dev/null 2>&1; then fail "an unknown option exited 0"; fi
if "$SAMPLE" --events "$W/nope" >/dev/null 2>&1; then fail "a missing events folder exited 0"; fi

[[ -f "$canary" ]] || fail "the canary in the pinned HOME is gone"
echo "samples-events: ok"
