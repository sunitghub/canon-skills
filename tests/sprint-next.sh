#!/usr/bin/env bash
# sprint-next — `sprint next <id>` prints the ticket's one next pipeline step and the earlier steps passed over (t-2bfe).
# Protects the shipped `sprint next` command (start-checklist.md step 9) and its fail-loud paths: a pipeline the reader refuses and a
# canon-go with no walk exit 2 and name the fix, never a next line.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

project="$(make_project)"
stub="$(mktemp -d)"
trap 'rm -rf "$project" "$stub"' EXIT
cd "$project"

id="$("$SPRINT" start "Walk me" | awk '/Sprint started:/ { print $3 }')"
plan=".tickets/$id/plan.md"
printf '# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved\n\n## Approach\nDo it.\n' > "$plan"
then_line="then: the close is not walked yet; follow skills/sprint/reference/complete-checklist.md (t-6a4d)"

# 1. a fresh ticket: the spec check is next, its note names this ticket
out="$("$SPRINT" next "$id")"
assert_eq "next: spec-check (agent) — the spec check has not run: dispatch canon-spec-checker with sprint gate-prompt $id speccheck before the brief (start-checklist.md step 9)" "$out"

# 2. the verdict is written: approval is next
printf '# Spec check: %s\n\n## Verdict\nREADY — no gap\n' "$id" > ".tickets/$id/spec-review.md"
out="$("$SPRINT" next "$id")"
assert_eq "next: approve-plan (you) — show the person the brief and wait for their explicit approval, then run sprint approve $id (start-checklist.md step 11)" "$out"

# 3. a ticked box is not approval; the pin is
sed -i.bak 's/- \[ \] Plan approved/- [x] Plan approved/' "$plan"; rm -f "$plan.bak"
assert_contains "$("$SPRINT" next "$id")" "next: approve-plan (you)"
"$SPRINT" approve "$id" >/dev/null
assert_eq "next: build (step) — -
$then_line" "$("$SPRINT" next "$id")"

# 4. approved earlier with the spec check gone: the build is next, after a missed line
rm ".tickets/$id/spec-review.md"
out="$("$SPRINT" next "$id")"
assert_contains "$out" "missed: spec-check — the spec check has not run"
assert_contains "$out" "next: build (step)"

# 5. a pipeline the reader refuses: exit 2 naming the file, no next line
mkdir -p canon-config; printf 'extends: canon-default\noff: [nope]\n' > canon-config/pipeline.yaml
set +e; out="$("$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "unknown node 'nope'"; ! grep -q '^next:' <<< "$out" || fail "a refused pipeline printed a next line: $out"
# t-2bfe C2: a project file cannot set an assertion
printf 'extends: canon-default\nproduces: spec.verdict\n' > canon-config/pipeline.yaml
set +e; out="$("$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "canon-config/pipeline.yaml: line 2"
rm -rf canon-config

# 6. a canon-go with no walk (an older install): exit 2 naming canon update, the binary never asked to walk
printf '#!/usr/bin/env bash\n[[ "$1" == --help ]] && { echo "usage: canon-go validate <ticket dir | artifact file>"; exit 0; }\ntouch "%s/called"\n' "$stub" > "$stub/canon-go"
chmod +x "$stub/canon-go"
set +e; out="$(SPRINT_CHECK_BIN="$stub/canon-go" "$SPRINT" next "$id" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "has no walk (run canon update)"
[[ ! -e "$stub/called" ]] || fail "an older canon-go was asked to walk"

# 7. usage
set +e; out="$("$SPRINT" next 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "usage: sprint next <ticket-id>"
set +e; out="$("$SPRINT" next t-zzzz 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "no ticket folder .tickets/t-zzzz"

echo "sprint-next: ok"
