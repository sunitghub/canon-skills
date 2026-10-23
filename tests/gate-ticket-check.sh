#!/usr/bin/env bash
# gate-ticket-check.sh — the canon CI gate's ticket check (t-89b0): no ticket id fails; a ticket whose plan was already
# approved on the base may not have its graded docs changed by the PR; otherwise the PR's own docs are graded with a
# warning. Prod path: the canon-gate workflow (tools/canon-gate-template.yml).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/tools/gate-ticket-check"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "gate-ticket-check: FAIL — $*" >&2; exit 1; }
g() { git -C "$WORK/r" "$@"; }

git init -q "$WORK/r"; g config user.email t@t; g config user.name t; g commit -q --allow-empty -m init
doc() { mkdir -p "$WORK/r/.tickets/$1"; printf '%s\n' "$3" > "$WORK/r/.tickets/$1/$2"; }
approved_plan='# Plan
## Sign-off
Tier: normal | Risk: x
- [x] Plan approved — proceed to implementation'
doc t-aaaa ticket.md "id: t-aaaa"; doc t-aaaa plan.md "$approved_plan"; doc t-aaaa acceptance.md "- [ ] C1"
doc t-bbbb ticket.md "id: t-bbbb"                                              # created on main, not yet planned
g add -A; g commit -q -m base; BASE="$(g rev-parse HEAD)"

run() {  # run <body> → sets out, rc
  set +e; out="$(cd "$WORK/r" && printf '%s' "$1" | "$TOOL" "$BASE" 2>&1)"; rc=$?; set -e
}

# 1. No ticket id: fail, never a silent pass.
run "Fixes a typo"
[[ $rc -ne 0 && "$out" == *"::error::No canon ticket id"* ]] || fail "no id must fail: rc=$rc $out"
run "see kit-abcd for context"   # a t-xxxx inside another word is not an id
[[ $rc -ne 0 ]] || fail "an id embedded in a word must not count: $out"

# 2. Approved on the base and unchanged: graded against the base docs.
run "Closes: t-aaaa"
[[ $rc -eq 0 && "$out" == *"id=t-aaaa"* && "$out" != *"::warning::"* ]] || fail "approved, unchanged: rc=$rc $out"

# 3. Approved on the base, PR changes each graded doc in turn: fail naming it.
for f in acceptance.md plan.md ticket.md; do
  g checkout -q -B pr "$BASE"; printf 'edited\n' >> "$WORK/r/.tickets/t-aaaa/$f"; g commit -qam "edit $f"
  run "Closes: t-aaaa"
  [[ $rc -ne 0 && "$out" == *"::error::"*"already approved"*".tickets/t-aaaa/$f"* ]] || fail "changing approved $f must fail: rc=$rc $out"
done
g checkout -q -B pr "$BASE"; printf 'notes\n' > "$WORK/r/.tickets/t-aaaa/research.md"; g add -A; g commit -qm research
run "Closes: t-aaaa"
[[ $rc -eq 0 ]] || fail "a non-graded doc (research.md) may change: $out"

# 4. No approved plan on the base (created there, planned in the PR) and a ticket new in the PR: graded, with a warning.
g checkout -q -B pr "$BASE"; doc t-bbbb plan.md "$approved_plan"; doc t-bbbb acceptance.md "- [ ] C1"; doc t-cccc ticket.md "id: t-cccc"
g add -A; g commit -qm plan
for t in t-bbbb t-cccc; do
  run "Closes: $t"
  [[ $rc -eq 0 && "$out" == *"::warning::$t's plan and criteria were authored in this PR"* && "$out" == *"id=$t"* ]] || fail "$t authored in the PR: rc=$rc $out"
done

# 5. A malformed or unknown base is refused.
for b in "" "HEAD" "--output=x" "0000000000000000000000000000000000000000"; do
  set +e; out="$(cd "$WORK/r" && printf 'Closes: t-aaaa' | "$TOOL" "$b" 2>&1)"; rc=$?; set -e
  [[ $rc -ne 0 && "$out" == *"::error::gate-ticket-check: base"* ]] || fail "base '$b' must be refused: rc=$rc $out"
done

echo "gate-ticket-check: ok (no id fails; approved-on-base docs pinned per file; PR-authored criteria graded with a warning; bad base refused)"
