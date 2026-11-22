#!/usr/bin/env bash
# sprint-wrapup-row — t-bcc1: `sprint wrapup-row <id> <gate> ran|skipped "<notes>"` writes one row of acceptance.md's ## Wrapup Gates
# table and emits wrapup.gate_finished, so the Sprint progress card draws each inline gate from its own event (hand-written rows emitted
# none, and the Windows run's card drew skipped gates as passed). Protects `sprint wrapup-row` and the event the card reads.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # canon_event writes through the board binary: build it, never the installed one (t-bcc1 reviewer)

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
export CANON_HOME="$W/canon-home"
project="$(make_project)"; project="$(cd "$project" && pwd -P)"
trap 'rm -rf "$W" "$project"' EXIT
unset COCKPIT_AGENT COCKPIT_TICKET COPILOT_CLI CLAUDECODE CANON_TICKETS_DIR
cd "$project"
git commit -q --allow-empty -m init
id="$("$SPRINT" start "Wrapup rows" | awk '/Sprint started:/ { print $3 }')"
acc=".tickets/$id/acceptance.md"
section() { awk '/^##[[:space:]]+Wrapup Gates[[:space:]]*$/ { f = 1; next } /^##[[:space:]]/ { f = 0 } f && /^\|/' "$acc"; }
wr() { set +e; out="$("$SPRINT" wrapup-row "$@" 2>&1)"; code=$?; set -e; }

# 1. no section yet: the section, its header and the row are added; the event names the gate and the result
wr "$id" doc-audit skipped "no docs changed"
assert_eq 0 "$code"
assert_contains "$out" "$id: Wrapup Gates row doc-audit: skipped"
assert_eq $'| Gate | Status | Notes |\n|---|---|---|\n| doc-audit | skipped | no docs changed |' "$(section)"
ev="$(event_line wrapup.gate_finished "$id")"
assert_contains "$ev" '"gate":"doc-audit"'
assert_contains "$ev" '"result":"skipped"'

# 2. a second gate is appended to the table; the same gate again replaces its row in place; `|` in notes is escaped
wr "$id" code-simplifier ran "inline: nothing to simplify"
wr "$id" doc-audit ran 'tools/doc-check: exit 0 | 3 files'
assert_eq 0 "$code"
assert_eq $'| Gate | Status | Notes |\n|---|---|---|\n| doc-audit | ran | tools/doc-check: exit 0 \\| 3 files |\n| code-simplifier | ran | inline: nothing to simplify |' "$(section)"
assert_contains "$(event_line wrapup.gate_finished "$id")" '"result":"ran"'

# 3. text after the table and a later section stay where they are; a new row goes at the table's end
printf '\nA note under the table.\n\n## Later\nkeep me\n' >> "$acc"
wr "$id" break-it skipped "normal tier"
assert_eq "| break-it | skipped | normal tier |" "$(section | tail -1)"
assert_contains "$(cat "$acc")" $'A note under the table.\n\n## Later\nkeep me'
[[ "$(grep -c '^## Wrapup Gates' "$acc")" == 1 ]] || fail "a second Wrapup Gates section was added"

# 4. refusals: nothing written, no event
before="$(cat "$acc")"; n="$(cat "$CANON_HOME"/events/*.jsonl | grep -c wrapup.gate_finished)"
for args in "$id|Doc-Audit|ran|x" "$id|doc audit|ran|x" "$id|doc-audit|passed|x" "$id|doc-audit|ran|$(printf 'two\nlines')" "t-zzzz|doc-audit|ran|x"; do
  IFS='|' read -r a b c d <<< "$args"
  [[ "$args" == *lines* ]] && d=$'two\nlines'
  wr "$a" "$b" "$c" "$d"
  assert_eq 1 "$code"
done
wr "$id" doc-audit ran
assert_eq 1 "$code"; assert_contains "$out" 'Usage: sprint wrapup-row <id> <gate> ran|skipped "<notes>"'
assert_eq "$before" "$(cat "$acc")"
assert_eq "$n" "$(cat "$CANON_HOME"/events/*.jsonl | grep -c wrapup.gate_finished)"

# 5. --help lists it
assert_contains "$("$SPRINT" --help 2>&1 || true)" 'sprint wrapup-row <id> <gate> ran|skipped "<notes>"'

echo "sprint-wrapup-row: ok"
