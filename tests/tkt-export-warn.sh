#!/usr/bin/env bash
# tkt export warns, never refuses, on a ticket with no acceptance criteria or an unapproved plan (t-1cf4).
# A tracked .tickets/ makes export stop after the warnings, so no gh or network is involved.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-export-warn.XXXXXX")"
trap 'rm -rf "$W"' EXIT
git -C "$W" init -q; cd "$W"
id="$("$TKT" create "Warn on blank" -t task -p 3)"
d=".tickets/$id"

# Blank: both warnings, exit 0.
printf '# Acceptance\n\n## Criteria\nThe checklist of behavior that must be true before the sprint can close.\n- [ ]\n' > "$d/acceptance.md"
printf '# Plan\n\n## Sign-off\n- [ ] Plan approved\n' > "$d/plan.md"
rc=0; out="$("$TKT" export "$id" 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "a blank ticket's export should still exit 0, got $rc"
assert_contains "$out" "no acceptance criteria"
assert_contains "$out" "is not approved"
assert_contains "$out" "commit it on the PR branch"

# One criterion, plan approved: nothing extra.
printf '# Acceptance\n\n## Criteria\n- [ ] It works\n' > "$d/acceptance.md"
printf '# Plan\n\n## Sign-off\n- [x] Plan approved\n' > "$d/plan.md"
out="$("$TKT" export "$id" 2>&1)"
[[ "$out" != *WARNING* ]] || fail "a complete ticket warned: $out"

# Each warning stands alone.
printf '# Plan\n\n## Sign-off\n- [ ] Plan approved\n' > "$d/plan.md"
out="$("$TKT" export "$id" 2>&1)"
assert_contains "$out" "is not approved"; [[ "$out" != *"no acceptance"* ]] || fail "criteria warned with one present"
echo "tkt-export-warn: ok"
