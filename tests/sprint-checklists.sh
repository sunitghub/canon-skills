#!/usr/bin/env bash
# sprint-checklists (t-b531) — the one-page start/close checklists stay one page and stay tied to the full protocol: every section
# and step their "Read the detail when" table names exists in start.md / complete.md, each is at most 900 words, and SKILL.md sends
# a sprint to the checklist first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
REF="$ROOT/skills/sprint/reference"
SKILL="$ROOT/skills/sprint/SKILL.md"
CAP=900

for phase in start complete; do
  list="$REF/$phase-checklist.md"; full="$REF/$phase.md"
  [[ -f "$list" ]] || fail "sprint-checklists: $list is missing"
  words="$(wc -w < "$list" | tr -d ' ')"
  (( words <= CAP )) || fail "sprint-checklists: $phase-checklist.md is $words words, over the $CAP-word cap"
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

# t-e75d — close step 10 never reports "pushed" for a commit that stayed local: both pages an agent executes at close carry
# the no-remote sentence and the "pushed only after a push that succeeded" rule.
for f in "$REF/complete-checklist.md" "$REF/complete.md"; do
  grep -qF -- 'No remote is configured: committed locally, nothing pushed' "$f" || fail "sprint-checklists: ${f#"$ROOT"/} lost the no-remote sentence from close step 10 (t-e75d)"
  grep -qF -- 'only after a push that succeeded' "$f" || fail "sprint-checklists: ${f#"$ROOT"/} lost the 'pushed only after a push that succeeded' rule from close step 10 (t-e75d)"
done

echo "PASS: sprint-checklists"
