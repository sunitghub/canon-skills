#!/usr/bin/env bash
# pipeline-events — t-bcc1: every node of the resolved pipeline has an event that ends it (or marks it skipped), and something in canon
# emits that event. The Sprint progress card draws a row done only from its own end event (ROW_END in sprint-progress-card.js), so a
# node with no end kind, or a kind nothing writes, would never turn done: the Windows run drew rows from their position instead (t-pnu4).
# Protects the rail's Sprint progress card and the pipeline's coverage rule.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

CARD="$ROOT/tools/sprint-check-app/static/sprint-progress-card.js"
# the card's own table, read from the module (one owner): "<node> <kind>" per line
table="$(node --input-type=module -e "
  const { ROW_END } = await import('$(printf '%s' "$CARD" | sed "s/'/\\\\'/g")');
  for (const [id, kinds] of Object.entries(ROW_END)) for (const k of kinds) console.log(id + ' ' + k);
")"
[[ -n "$table" ]] || fail "pipeline-events: ROW_END could not be read from $CARD"
nodes="$("$ROOT/tools/pipeline.sh" resolve --full | awk -F'\t' '{ print $2 }')"
[[ -n "$nodes" ]] || fail "pipeline-events: tools/pipeline.sh resolve --full listed no node"

# emitted <kind>: a `canon_event <kind>` call in a shell tool, or a Go emit call naming it (`.emit("<kind>"` / `Emit("<kind>"`), outside
# the tests. A bare string is not enough: the board's readers name every kind too (t-bcc1 reviewer: the check could not fail).
emitted() {
  local k="$1" re
  re="${k//./\\.}"
  grep -rqE "canon_event[[:space:]]+$re([[:space:]]|$)" "$ROOT/tools" "$ROOT/scripts" --exclude-dir=canon-go --exclude-dir=node_modules 2>/dev/null && return 0
  grep -rqE "[.]?[Ee]mit[A-Za-z]*\\(\"$re\"" "$ROOT/tools/canon-go" --include='*.go' --exclude='*_test.go' 2>/dev/null
}

missing=""
while read -r n; do
  kinds="$(awk -v n="$n" '$1 == n { print $2 }' <<< "$table")"
  if [[ -z "$kinds" ]]; then missing+="  $n: no end kind in ROW_END"$'\n'; continue; fi
  for k in $kinds; do emitted "$k" || missing+="  $n: nothing emits $k"$'\n'; done
done <<< "$nodes"
[[ -z "$missing" ]] || fail $'pipeline-events: a pipeline node the card can never draw done:\n'"$missing"

# the check has teeth: a node with no entry and a kind nothing emits are both reported
emitted "no.such_kind" && fail "pipeline-events: emitted() found an emitter for a kind nobody writes"
emitted "sprint.started" || fail "pipeline-events: emitted() missed sprint start's emitter"
emitted "implement.started" || fail "pipeline-events: emitted() missed the daemon's Go emit of implement.started"
emitted "plan.written" && fail "pipeline-events: emitted() counted plan.written, which is only declared and read"

echo "pipeline-events: ok ($(wc -l <<< "$nodes" | tr -d ' ') nodes)"
