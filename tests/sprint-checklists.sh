#!/usr/bin/env bash
# sprint-checklists (t-b531) — the one-page start/close checklists stay one page and stay tied to the full protocol: every section
# and step their "Read the detail when" table names exists in start.md / complete.md, each is within its tools/caps.tsv cap (900 words), and SKILL.md sends
# a sprint to the checklist first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
REF="$ROOT/skills/sprint/reference"
SKILL="$ROOT/skills/sprint/SKILL.md"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SPRINT_CHECK_NO_BROWSER=1   # an older board would take `caps` for a port and start (t-269d)
BOARD="$(build_board "$T")"   # the 900-word caps live in tools/caps.tsv and are measured by the board's cap meter (t-19bb)

for phase in start complete; do
  list="$REF/$phase-checklist.md"; full="$REF/$phase.md"
  [[ -f "$list" ]] || fail "sprint-checklists: $list is missing"
  cap_check "$BOARD" "$phase-checklist" "$list" >/dev/null
  table="$(awk '/^## Read the detail when/{f=1; next} f && /^## /{exit} f' "$list")"
  [[ "$(printf '%s\n' "$table" | grep -c '^| ')" -ge 4 ]] || fail "sprint-checklists: $phase-checklist.md has no 'Read the detail when' table"
  n=0
  while IFS= read -r q; do   # each "quoted section name" must be text in the full file
    [[ -n "$q" ]] || continue
    grep -qF -- "$q" "$full" || fail "sprint-checklists: $phase-checklist.md names \"$q\", which $phase.md does not contain"
    n=$((n + 1))
  done < <(printf '%s\n' "$table" | grep -o '"[^"]*"' | tr -d '"')
  (( n >= 5 )) || fail "sprint-checklists: $phase-checklist.md's table names only $n sections"
  while IFS= read -r s; do   # each "step N" must be a numbered step of the full file
    grep -qE "^ *$s\. \*\*" "$full" || fail "sprint-checklists: $phase-checklist.md names step $s, which $phase.md does not have"
  done < <(printf '%s\n' "$table" | grep -oE 'step [0-9]+' | awk '{print $2}' | sort -u)
  grep -qF "skills/sprint/reference/$phase-checklist.md" "$SKILL" || fail "sprint-checklists: SKILL.md does not point to $phase-checklist.md"
  grep -qF "$phase-checklist.md" "$full" || fail "sprint-checklists: $phase.md does not name $phase-checklist.md"
done

echo "PASS: sprint-checklists"
