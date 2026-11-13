#!/usr/bin/env bash
# sprint-manual-mode (t-51c6) — a `manual: true` ticket closes on the user's recorded testing: `sprint check-evidence` (the pre-flight before the
# evaluator) refuses it until a fresh manual-qa.md exists, does not demand the full-suite stamp, and refuses Manual mode for a high-risk plan or
# for a gate-file diff in canon's own checkout. Protects: the close gate's pre-flight. Throwaway git repo; nothing touches the real tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/manual-mode.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C CANON_HOME="$WORK/home"
unset CANON_TICKETS_DIR
REPO="$WORK/repo"; ID=t-abcd; TD="$REPO/.tickets/$ID"; ED="$TD/evidence"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p "$TD" src; echo a > src/a.txt
printf -- '---\nid: %s\nstatus: in_progress\nmanual: true\n---\n# t\n' "$ID" > "$TD/ticket.md"
printf '# Acceptance\n\n## Criteria\n- [ ] plain\n' > "$TD/acceptance.md"
git add src && git commit -qm base

mq() { set +e; out="$(cd "$REPO" && bash "$ROOT/tools/sprint" manual-qa "$@" 2>&1)"; code=$?; set -e; }
ce() { set +e; out="$(cd "$REPO" && bash "$ROOT/tools/sprint" check-evidence "$@" 2>&1)"; code=$?; set -e; }

# no record: refused, says it is waiting for the user and how to record
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md missing: $ID is a Manual ticket (manual: true): waiting for your test"
assert_contains "$out" 'sprint manual-qa t-abcd --by "<name>" --step "<what>|pass"'
# a fresh record clears it, and no log or suite stamp is demanded
mq "$ID" --by Sunit --step "list looks right|pass"; ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "ok      manual-qa.md"
# a log that would refuse on a normal ticket is a note on a Manual one (the stamp is not required)
printf 'not a stamp\n' > "$ED/stray.log"; ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "note    "; assert_contains "$out" "not required: a Manual ticket closes on the user's testing"
sed -i.bak 's/^manual: true$/manual: false/' "$TD/ticket.md"; rm -f "$TD/ticket.md.bak"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  "   # the same stray log refuses on a ticket that is not Manual
sed -i.bak 's/^manual: false$/manual: true/' "$TD/ticket.md"; rm -f "$TD/ticket.md.bak" "$ED/stray.log"
# a stale or failing record still refuses
mq "$ID" --by Sunit --step "a|fail"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md failing"
mq "$ID" --by Sunit --step "a|pass"; echo b >> src/a.txt; git add src; git commit -qm change; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md stale"
mq "$ID" --by Sunit --step "a|pass"; ce "$ID"; assert_eq 0 "$code"
# a high-risk plan: Manual mode is refused (the full close keeps every gate)
printf '# Plan\n\n## Sign-off\nTier: high-risk | Risk: x\n' > "$TD/plan.md"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "Manual mode is refused: the plan's Tier is high-risk"; assert_contains "$out" "tkt manual t-abcd off"
printf '# Plan\n\n## Sign-off\nTier: normal | Risk: x\n' > "$TD/plan.md"; ce "$ID"; assert_eq 0 "$code"
# canon's own checkout: a gate-file diff against the base is refused; no base found is refused (fails closed); an untouched tree is fine
mkdir -p scripts tools; printf 'GATE_FILES=(tools/sprint tools/evidence.sh)\nGATE_PROMPTS=(skills/sprint/reference/eval.md)\n' > scripts/integrity-list.sh; echo x > tools/other.sh
git add scripts tools; git commit -qm "gate list"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "base (origin/main) cannot be found"
git update-ref refs/remotes/origin/main HEAD; mq "$ID" --by Sunit --step "a|pass"; ce "$ID"; assert_eq 0 "$code"
echo y >> tools/other.sh; git commit -qam "other"; mq "$ID" --by Sunit --step "a|pass"; ce "$ID"; assert_eq 0 "$code"
echo z >> tools/sprint; git add tools/sprint; git commit -qm "gate file"; mq "$ID" --by Sunit --step "a|pass"; ce "$ID"
assert_eq 1 "$code"; assert_contains "$out" "it changes a gate file or gate prompt (tools/sprint)"
git reset -q --hard HEAD~1; mkdir -p skills/sprint/reference; echo q > skills/sprint/reference/eval.md
mq "$ID" --by Sunit --step "a|pass"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "(skills/sprint/reference/eval.md)"   # an untracked or uncommitted prompt counts too
printf 'sprint-manual-mode: ok\n'
