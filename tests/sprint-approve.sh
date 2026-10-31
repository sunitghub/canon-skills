#!/usr/bin/env bash
# sprint-approve — `sprint approve` pins ## Approach and the close plan gate refuses on drift (t-0865).
# Protects the sprint-close plan gate (_gate_plan_signoff).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

id="$("$SPRINT" start "Pin approval" | awk '/Sprint started:/ { print $3 }')"
plan=".tickets/$id/plan.md"
cat > "$plan" <<'PLAN'
# Plan

## Sign-off
Tier: normal | Risk: low

- [ ] Plan approved — proceed to implementation

## Approach
Do the thing.

## Files
- tools/sprint
PLAN

# The gate is called directly: a full `sprint complete` needs reviewer/evaluator reports.
# eval, not source <(...): macOS's bash 3.2 sources nothing from a process substitution.
gate() { ( eval "$(sed -n '/^_acceptance_section()/,/^}/p;/^_gate_plan_signoff()/,/^}/p;/^_approach_digest()/,/^}/p' "$SPRINT")"; _gate_plan_signoff "$id" "$plan" 2>&1 ); }

# 1. approve ticks the box and writes the pin under it
out="$("$SPRINT" approve "$id")"
assert_contains "$out" "pinned ## Approach"
assert_grep '^- \[x\] Plan approved' "$plan"
assert_grep '^Approved: sha256:[0-9a-f]{64} [0-9TZ:-]+$' "$plan"
first="$(grep -c '^Approved:' "$plan")"; assert_eq "1" "$first"

# 2. unchanged Approach passes
gate >/dev/null || fail "unchanged Approach must pass the plan gate"

# 3. Files-only (and Decisions) change passes
printf '\n- tests/sprint-approve.sh\n' >> "$plan"
gate >/dev/null || fail "a change only in ## Files must pass the plan gate"

# 4. changed Approach refuses and names sprint approve
sed -i.bak 's/Do the thing\./Do another thing./' "$plan"; rm -f "$plan.bak"
if out="$(gate)"; then fail "changed Approach must refuse"; fi
assert_contains "$out" "Approach changed after approval"
assert_contains "$out" "sprint approve $id"

# 5. re-approve updates the single Approved line and the gate passes again
"$SPRINT" approve "$id" >/dev/null
assert_eq "1" "$(grep -c '^Approved:' "$plan")"
gate >/dev/null || fail "re-approve must make the plan gate pass"

# 6. legacy tick (no Approved: line) passes with a warning
sed -i.bak '/^Approved:/d' "$plan"; rm -f "$plan.bak"
out="$(gate)" || fail "a ticked box with no pin must pass"
assert_contains "$out" "WARNING"

# 7. approve refuses a missing id, a missing plan, and a plan with no approval box
out="$(run_fail "$SPRINT" approve)"; assert_contains "$out" "Usage: sprint approve"
out="$(run_fail "$SPRINT" approve t-nope)"; assert_contains "$out" "no plan.md"
printf '# Plan\n\n## Sign-off\nTier: normal\n\n## Approach\nx\n\n## Files\n- [ ] Plan approved\n' > "$plan"   # box outside ## Sign-off
out="$(run_fail "$SPRINT" approve "$id")"; assert_contains "$out" "no '- [ ] Plan approved' box"

# 8. trailing spaces on Approach lines do not change the pin
printf '# Plan\n\n## Sign-off\n- [ ] Plan approved\n\n## Approach\nstep one\n' > "$plan"
"$SPRINT" approve "$id" >/dev/null
sed -i.bak 's/step one/step one   /' "$plan"; rm -f "$plan.bak"
gate >/dev/null || fail "trailing spaces in Approach must not trip the plan gate"

# 9. t-cc88: a capped file plan.md ## Files names prints one headroom line when under 10% is left (HANDOFF.md: 80 block-lines,
# tools/caps.tsv); exactly 10%, no row, an absent capped file and an older board print nothing; a failed read says so.
handoff() { { echo '<!-- canon:handoff:BEGIN -->'; for ((i = 0; i < $1; i++)); do echo "line $i"; done; echo '<!-- canon:handoff:END -->'; } > HANDOFF.md; }
approve_with() { printf '# Plan\n\n## Sign-off\n- [ ] Plan approved\n\n## Approach\nstep one\n\n## Files\n%s\n' "$1" > "$plan"; "$SPRINT" approve "$id"; }
caplines() { grep -v '^Approved ' <<< "$1" || true; }
echo notes > notes.md
handoff 75; out="$(approve_with '`HANDOFF.md`, `notes.md` (new)')"
assert_eq "HANDOFF.md: 75 of 80 lines, 5 left: make room first" "$(caplines "$out")"
assert_grep '^Approved: sha256:' "$plan"
handoff 82; out="$(approve_with '- HANDOFF.md')"   # a bare bullet
assert_eq "HANDOFF.md: 82 of 80 lines, over by 2: make room first" "$(caplines "$out")"
handoff 72; out="$(approve_with '`HANDOFF.md`')"; assert_eq "" "$(caplines "$out")"   # 8 left of 80: exactly 10%
out="$(approve_with '`notes.md`, `LEARNINGS.md`')"; assert_eq "" "$(caplines "$out")"   # no row; a row whose file is absent
echo 'no markers' > HANDOFF.md; out="$(approve_with '`HANDOFF.md`')"
[[ "$(caplines "$out")" == "HANDOFF.md: cap not measured: caps: handoff: no <!-- canon:handoff:BEGIN -->"* ]] || fail "unmeasured cap: $out"
# an older board (no `caps` in --help) is never asked: it would take the word for a port and serve
stub="$(mktemp -d)"; trap 'rm -rf "$project" "$stub"' EXIT
printf '#!/usr/bin/env bash\n[[ "$1" == --help ]] && { echo "usage: sprint-check [port]"; exit 0; }\ntouch "%s/called"; sleep 30\n' "$stub" > "$stub/board"; chmod +x "$stub/board"
handoff 75; out="$(SPRINT_CHECK_BIN="$stub/board" approve_with '`HANDOFF.md`')"
assert_eq "" "$(caplines "$out")"; [[ ! -e "$stub/called" ]] || fail "an older board was called with caps"
assert_grep '^- \[x\] Plan approved' "$plan"

echo "sprint-approve: ok"
