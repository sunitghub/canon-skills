#!/usr/bin/env bash
# sprint-manual-merged — t-788f: `sprint complete <id>` for a Manual cloud ticket merged here (sent --manual-after-merge, cloud copy
# closed, Check & merge done, left open for the person's test). Protects the one close that path has: it closes after the person's
# fresh all-pass manual-qa.md only when the merge commit's PR head is the graded commit plus late docs, the cloud's verdict is a real
# pass and nothing but [manual] criteria is unchecked; every other shape is refused and changes nothing. Also: a named id that is not the
# active sprint never closes the active sprint, and the active id keeps the full close.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"
CANON_HOME="$W/canon-home"; export CANON_HOME
trap 'rm -rf "$W"' EXIT
use_fresh_board "$W/board"   # the close's events go through the board binary (built before HOME moves)
unset CANON_TICKETS_DIR COCKPIT_AGENT   # the full run's stamp sets CANON_TICKETS_DIR for canon's own .tickets: this project's must be read
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main
P="$W/p"; mkdir "$P"; cd "$P"; git init -q
printf '.tickets/\n' > .gitignore; echo v1 > src.txt; git add .gitignore src.txt; git commit -qm init
id="$("$TKT" create "CSV export")"; t=".tickets/$id"; f="$t/ticket.md"

# the PR: the graded commit, then the cloud's late docs; merged with a merge commit (gh pr merge --merge)
git checkout -q -b pr; echo v2 > src.txt; git commit -qam graded; G="$(git rev-parse HEAD)"
echo row > LEARNINGS.md; git add LEARNINGS.md; git commit -qm sweep; L="$(git rev-parse HEAD)"
git checkout -q main; git merge -q --no-ff pr -m "Merge PR #2"; M="$(git rev-parse HEAD)"

field() { awk -v k="$1" -v v="$2" '/^---$/ && ++n == 2 { print k ": " v } { print }' "$f" > "$W/fm" && mv "$W/fm" "$f"; }
field runs github; field github acme/app#1; field manual true; field cloud_status closed; field merged "$M"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\npass: all met\n' "$G" > "$t/eval-report.md"
printf '# Acceptance\n\n## Criteria\n- [x] Export writes every todo\n- [ ] [manual] The file opens in a spreadsheet\n\n## Test Plan\n- [x] x\n\n## QA\n- [x] Tested locally\n' > "$t/acceptance.md"

events() { cat "$CANON_HOME"/events/*.jsonl 2>/dev/null | grep -c '"kind":"\(sprint.completed\|close.confirmed\)"' || true; }
snap() { cat "$f" "$t/acceptance.md"; events; }
refused() {   # refused <what the output names> — the close refuses, naming it, and changes nothing
  local before after rc=0 out
  before="$(snap)"; out="$("$SPRINT" complete "$id" 2>&1)" || rc=$?
  after="$(snap)"
  [[ "$rc" == 1 ]] || fail "expected a refusal ($1), got rc $rc: $out"
  assert_contains "$out" "$1"
  [[ "$before" == "$after" ]] || fail "a refusal ($1) changed the ticket, acceptance.md or the events"
}

# no test recorded yet; then an n/a-only record; then a failing one
refused "the person's test is not recorded (manual-qa.md is absent"
"$SPRINT" manual-qa "$id" --by tester --step "opened it|n/a" >/dev/null
refused "with no pass step"
"$SPRINT" manual-qa "$id" --by tester --step "opened it|fail" >/dev/null
refused "manual-qa.md is failing"
"$SPRINT" manual-qa "$id" --by tester --step "opened it in Numbers|pass" >/dev/null

# each shape it must refuse (put back after each)
cp "$f" "$W/f.ok"; cp "$t/eval-report.md" "$W/e.ok"; cp "$t/acceptance.md" "$W/a.ok"
sed -i.bak 's/^manual: true$/manual: false/' "$f"; rm -f "$f.bak";                     refused "it is not a Manual ticket"; cp "$W/f.ok" "$f"
sed -i.bak 's/^cloud_status: closed$/cloud_status: in_progress/' "$f"; rm -f "$f.bak";  refused "its cloud copy did not close"; cp "$W/f.ok" "$f"
sed -i.bak '/^merged: /d' "$f"; rm -f "$f.bak";                                         refused "it is not merged yet"; cp "$W/f.ok" "$f"
sed -i.bak 's/^status: open$/status: closed/' "$f"; rm -f "$f.bak";                     refused "its status is closed, not open"; cp "$W/f.ok" "$f"   # in_progress would make it the active sprint: the full close
printf 'evaluator-run-id: 1-1\ngraded-head: %s\nfail: not yet\n' "$G" > "$t/eval-report.md";  refused "eval-report.md has no pass: verdict line"
sed -i.bak 's/^eval_override: false$/eval_override: true/' "$f"; rm -f "$f.bak";        refused "eval-report.md has no pass: verdict line"   # an override never passes here
cp "$W/f.ok" "$f"; cp "$W/e.ok" "$t/eval-report.md"
sed -i.bak 's/^- \[x\] Export writes every todo$/- [ ] Export writes every todo/' "$t/acceptance.md"; rm -f "$t/acceptance.md.bak"
refused "acceptance.md has unchecked items other than [manual] criteria"; cp "$W/a.ok" "$t/acceptance.md"
# a code commit after the graded head in the PR: not the graded code
git checkout -q -b pr2 "$L"; echo v3 > src.txt; git commit -qam "late code"; git checkout -q main
git merge -q --no-ff pr2 -m "Merge PR #3"; M2="$(git rev-parse HEAD)"
"$SPRINT" manual-qa "$id" --by tester --step "opened it in Numbers|pass" >/dev/null
sed -i.bak "s/^merged: .*/merged: $M2/" "$f"; rm -f "$f.bak";                           refused "is not the graded ${G:0:7} plus late docs only"
# a squash merge: no PR head to check
echo v4 > other.txt; git add other.txt; git commit -qm "squashed PR #4"; S="$(git rev-parse HEAD)"   # a squash merge lands on main as one commit
"$SPRINT" manual-qa "$id" --by tester --step "opened it in Numbers|pass" >/dev/null
sed -i.bak "s/^merged: .*/merged: $S/" "$f"; rm -f "$f.bak";                            refused "has no PR head to check (a squash or rebase merge)"
cp "$W/f.ok" "$f"
# merged: in the PR #n form (no merge commit recorded), and a merge this checkout does not hold (the test would be of older code)
sed -i.bak "s/^merged: .*/merged: PR #2/" "$f"; rm -f "$f.bak";                         refused "is not a merge commit in this repository"; cp "$W/f.ok" "$f"
git checkout -q "$G~1"; "$SPRINT" manual-qa "$id" --by tester --step "opened it in Numbers|pass" >/dev/null
refused "is not in this checkout's HEAD"; git checkout -q main
# a stale record: tracked code changed after the test was recorded
git reset -q --hard "$M"; "$SPRINT" manual-qa "$id" --by tester --step "opened it in Numbers|pass" >/dev/null
echo v5 > src.txt; git commit -qam "after the test";                                    refused "manual-qa.md is stale"
git reset -q --hard "$M"; "$SPRINT" manual-qa "$id" --by tester --step "opened it in Numbers|pass" >/dev/null

# another sprint is active: a named id that cannot take this path never closes it
other="$("$TKT" create "Other work")"; "$TKT" start "$other" >/dev/null
sed -i.bak 's/^manual: true$/manual: false/' "$f"; rm -f "$f.bak"
rc=0; out="$("$SPRINT" complete "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a named non-active id closed something: $out"
assert_contains "$out" "it is not the active sprint ($other)"
assert_grep '^status: in_progress$' ".tickets/$other/ticket.md"
cp "$W/f.ok" "$f"

# the active sprint's own id keeps the full close (its gates refuse here: no plan.md), never this path
rc=0; out="$("$SPRINT" complete "$other" 2>&1)" || rc=$?
[[ "$rc" != 0 && "$out" != *"manual-after-merge"* ]] || fail "sprint complete <active id> did not take the full close: $out"
assert_contains "$out" "Missing required sprint file"
# the close: ticks the [manual] criteria, closes the ticket, records the two events with tier manual-merged
out="$("$SPRINT" complete "$id" 2>&1)" || fail "the manual-after-merge close refused: $out"
assert_contains "$out" "Sprint completed: $id (manual-after-merge"
assert_grep '^status: closed$' "$f"
assert_grep "^- \[x\] \[manual\] The file opens in a spreadsheet — manual-qa.md [0-9-]*$" "$t/acceptance.md"
assert_eq 2 "$(events)"
grep -h '"kind":"close.confirmed"' "$CANON_HOME"/events/*.jsonl | grep '"tier":"manual-merged"' >/dev/null || fail "close.confirmed has no tier manual-merged"
assert_grep '^status: in_progress$' ".tickets/$other/ticket.md"   # the active sprint is untouched

echo "sprint-manual-merged: ok"
