#!/usr/bin/env bash
# sprint-close-hint (t-bc1e) — `sprint close-hint <id>`, the line `sprint complete` prints after the cost line: why a close was slow, read from
# the activity log. Protects that line's triggers (over the tier's target, a re-stamp, a gate rejection), its one-line order, its scoping
# (this ticket, this project; evidence from a scratch clone counts) and that a bad or missing log prints nothing. Fixture logs only.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
SPRINT="$ROOT/tools/sprint"

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
P="$W/proj"; mkdir -p "$P/.tickets/t-abcd" && git -C "$P" init -q
export CANON_HOME="$W/home" HOME="$W/userhome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CANON_TICKETS_DIR CANON_CLOSE_TARGET_HIGH CANON_CLOSE_TARGET_NORMAL
mkdir -p "$CANON_HOME/events" "$HOME"
EV="$CANON_HOME/events/2026-11-20.jsonl"
tier() { printf '# Plan\n\n## Sign-off\n%s\n\n- [x] Plan approved\n' "${1:+Tier: $1 | Risk: x}" > "$P/.tickets/t-abcd/plan.md"; }
ev() {   # ev <HH:MM:SS> <kind> [project] [json data fields]
  printf '{"schema":1,"id":"x","ts":"2026-11-20T%s.000Z","kind":"%s","source":"t","project":"%s","data":{"ticket":"t-abcd"%s}}\n' \
    "$1" "$2" "${3:-$P}" "${4:+,$4}" >> "$EV"
}
hint() { (cd "$P" && bash "$SPRINT" close-hint "${1:-t-abcd}" 2>&1); }

# usage
set +e; out="$(cd "$P" && bash "$SPRINT" close-hint nope 2>&1)"; rc=$?; set -e; assert_eq 2 "$rc"; assert_contains "$out" "usage: sprint close-hint"
# no log at all, then a log with no close.started: nothing
tier normal; assert_eq "" "$(hint)"
ev 10:00:00 evidence.stamped "" '"name":"test-sh","exit":"0"'; ev 10:05:00 evidence.stamped "" '"name":"test-sh","exit":"0"'
assert_eq "" "$(hint)"

# a re-stamp, a failure, a rejection and gate runs, in the fixed order; a stamp from a scratch clone counts; the time part only when over
: > "$EV"
ev 10:00:00 close.started
ev 10:01:00 gate.started "" '"role":"reviewer"'
ev 10:02:00 evidence.stamped "/tmp/clone" '"name":"test-sh","exit":"1"'
ev 10:03:00 gate.rejected "" '"role":"evaluator","reason":"stale_evidence"'
ev 10:04:00 evidence.stamped "" '"name":"test-sh","exit":"0"'
ev 10:04:30 evidence.stamped "" '"name":"pre-gate","exit":"0"'
ev 10:05:00 gate.started "" '"role":"evaluator"'
ev 10:06:00 gate.started "" '"role":"evaluator"'
ev 10:20:00 sprint.completed
assert_eq "close: test-sh stamped 2x (1 failed), evaluator refused 1x (stale_evidence), reviewer 1 run, evaluator 2 runs" "$(hint)"

# over the target: normal (and bugfix, and no Tier at all) is 30 min, high-risk 60; the env overrides; a bad override falls back
sed -i.bak 's/T10:20:00/T10:45:00/' "$EV"; rm -f "$EV.bak"
assert_eq "close: 45 min (normal target 30): test-sh stamped 2x (1 failed), evaluator refused 1x (stale_evidence), reviewer 1 run, evaluator 2 runs" "$(hint)"
tier bugfix; assert_contains "$(hint)" "close: 45 min (bugfix target 30): "
tier ""; assert_contains "$(hint)" "close: 45 min (normal target 30): "
tier high-risk; assert_eq "close: test-sh stamped 2x (1 failed), evaluator refused 1x (stale_evidence), reviewer 1 run, evaluator 2 runs" "$(hint)"
out="$(CANON_CLOSE_TARGET_HIGH=40 hint)"; assert_contains "$out" "close: 45 min (high-risk target 40): "
sed -i.bak 's/T10:45:00/T11:05:00/' "$EV"; rm -f "$EV.bak"   # 65 min: over the default 60, so a bad override must fall back to 60, not compare as text
out="$(CANON_CLOSE_TARGET_HIGH=abc hint)"; assert_contains "$out" "close: 65 min (high-risk target 60): "

# exactly at the target is on time; a spec check (before approval) is never a close gate run
tier normal; : > "$EV"
ev 10:00:00 close.started; ev 10:01:00 gate.started "" '"role":"speccheck"'; ev 10:02:00 gate.started "" '"role":"evaluator"'
ev 10:02:30 evidence.stamped "" '"name":"y","exit":"0"'; ev 10:03:00 evidence.stamped "" '"name":"y","exit":"0"'; ev 10:30:00 sprint.completed
assert_eq "close: y stamped 2x, evaluator 1 run" "$(hint)"
# reached through a symlinked folder (macOS /var -> /private/var, or a linked checkout), the events' physical path still matches
ln -s "$P" "$W/link"; out="$(cd "$W/link" && bash "$SPRINT" close-hint t-abcd 2>&1)"; assert_eq "close: y stamped 2x, evaluator 1 run" "$out"

# on time, no re-stamp, no rejection: nothing, gate runs alone never print
tier normal; : > "$EV"
ev 10:00:00 close.started; ev 10:02:00 evidence.stamped "" '"name":"test-sh","exit":"0"'; ev 10:03:00 gate.started "" '"role":"evaluator"'; ev 10:10:00 sprint.completed
assert_eq "" "$(hint)"
# only over time still prints, with just the time and the gate runs
sed -i.bak 's/T10:10:00/T10:31:00/' "$EV"; rm -f "$EV.bak"
assert_eq "close: 31 min (normal target 30): evaluator 1 run" "$(hint)"

# another project's gate events and another ticket's events never count; the last close.started starts the window
: > "$EV"
ev 09:00:00 close.started; ev 09:01:00 evidence.stamped "" '"name":"old","exit":"0"'; ev 09:02:00 evidence.stamped "" '"name":"old","exit":"0"'
ev 10:00:00 close.started
ev 10:01:00 gate.rejected "/elsewhere" '"role":"evaluator","reason":"stale_evidence"'
printf '{"schema":1,"id":"x","ts":"2026-11-20T10:02:00.000Z","kind":"evidence.stamped","source":"t","project":"%s","data":{"ticket":"t-ffff","name":"test-sh","exit":"0"}}\n' "$P" >> "$EV"
printf '{"schema":1,"id":"x","ts":"2026-11-20T10:03:00.000Z","kind":"evidence.stamped","source":"t","project":"%s","data":{"ticket":"t-ffff","name":"test-sh","exit":"0"}}\n' "$P" >> "$EV"
ev 10:05:00 sprint.completed
assert_eq "" "$(hint)"

# a malformed line is skipped; a gzipped day file is read; an unreadable events folder prints nothing and exits 0
printf 'not json "ticket":"t-abcd" garbage\n{"ts":"bad","kind":"evidence.stamped","data":{"ticket":"t-abcd"}}\n' >> "$EV"
ev 10:01:00 evidence.stamped "" '"name":"x","exit":"0"'
gzip -c "$EV" > "$CANON_HOME/events/2026-11-19.jsonl.gz"; : > "$EV"
ev 10:02:00 evidence.stamped "" '"name":"x","exit":"0"'; ev 10:06:00 sprint.completed
assert_eq "close: x stamped 2x" "$(hint)"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$CANON_HOME/events"; set +e; out="$(hint)"; rc=$?; set -e; chmod 755 "$CANON_HOME/events"
  assert_eq 0 "$rc"; assert_eq "" "$out"
fi
# a hostile field never reaches the terminal as written
: > "$EV"; ev 10:00:00 close.started
ev 10:01:00 evidence.stamped "" '"name":"a\u001b[31m","exit":"0"'; ev 10:02:00 evidence.stamped "" '"name":"a\u001b[31m","exit":"0"'; ev 10:03:00 sprint.completed
out="$(hint)"; [[ "$out" != *$'\033'* && "$out" == "close: a?u001b?31m stamped 2x" ]] || fail "close-hint: a field was printed unsanitized: $out"

echo "sprint-close-hint: ok"
