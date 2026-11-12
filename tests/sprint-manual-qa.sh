#!/usr/bin/env bash
# sprint-manual-qa (t-aa24) — `sprint manual-qa` records the user's manual testing in .tickets/<id>/evidence/manual-qa.md, and
# `sprint check-evidence` (the pre-flight before the evaluator) lists it, refuses a stale, failing or malformed one, and refuses a dispatch
# whose [manual] criterion has no fresh record. Why: ToDo-Demo t-32ah ran the evaluator three times because the user's manual testing was
# visible to nobody. Runs in a throwaway git repo; nothing touches the real tree or the real .tickets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/manual-qa.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C CANON_HOME="$WORK/home"
unset CANON_TICKETS_DIR
REPO="$WORK/repo"; ID=t-abcd; TD="$REPO/.tickets/$ID"; ED="$TD/evidence"; MQ="$ED/manual-qa.md"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p "$TD" src; echo a > src/a.txt; echo '# t' > "$TD/ticket.md"
git add src && git commit -qm base
C1="$(git rev-parse HEAD)"

mq() { set +e; out="$(cd "$REPO" && bash "$ROOT/tools/sprint" manual-qa "$@" 2>&1)"; code=$?; set -e; }
ce() { set +e; out="$(cd "$REPO" && bash "$ROOT/tools/sprint" check-evidence "$@" 2>&1)"; code=$?; set -e; }
refused() { mq "$@"; assert_eq 1 "$code"; [[ ! -e "$MQ" ]] || fail "a refused manual-qa wrote a file: $*"; }
criteria() { printf '# Acceptance\n\n## Criteria\n%b\n## Test Plan\n- [ ] [manual] not a criterion: this is the Test Plan\n' "$1" > "$TD/acceptance.md"; }

# --- the writer: every refusal writes nothing and says why ---
mq; assert_eq 1 "$code"; assert_contains "$out" "usage: sprint manual-qa"
refused nope --by A --step "x|pass"; assert_contains "$out" "must look like t-abcd"
refused "$ID" --step "x|pass"; assert_contains "$out" "--by"
refused "$ID" --by A; assert_contains "$out" "at least one --step"
refused "$ID" --by A --step "no result"; assert_contains "$out" "<what>|pass"
refused "$ID" --by A --step "x|maybe"; assert_contains "$out" "pass, fail or n/a"
refused "$ID" --by A --step "   |pass"; assert_contains "$out" "needs a description"
refused "$ID" --by A --bogus; assert_contains "$out" "unknown argument"
refused "$ID" --by "  " --step "x|pass"; assert_contains "$out" "--by"
steps=(); for i in $(seq 61); do steps+=(--step "s$i|pass"); done
refused "$ID" --by A "${steps[@]}"; assert_contains "$out" "at most 60"
mq t-zzzz --by A --step "x|pass"; assert_eq 1 "$code"; assert_contains "$out" "no ticket folder"
ln -s "$WORK" "$ED"; refused "$ID" --by A --step "x|pass"; assert_contains "$out" "symlink"; rm "$ED"
mkdir -p "$ED"; ln -s "$WORK/elsewhere" "$MQ"; refused "$ID" --by A --step "x|pass"; assert_contains "$out" "not a plain file"
[[ ! -e "$WORK/elsewhere" ]] || fail "manual-qa wrote through a symlink"; rm "$MQ"; rmdir "$ED"

# --- the record: exact shape, sanitising, replace ---
long="$(head -c 250 /dev/zero | tr '\0' z)"
mq "$ID" --by "Sunit  Joshi" --step "Add a todo with Enter|pass" --step "tab|pipe|and
newline|fail" --step "${long}|n/a" --step "Delete removes it | PASS "
assert_eq 0 "$code"; assert_contains "$out" "manual-qa: wrote .tickets/$ID/evidence/manual-qa.md (4 steps: 2 pass, 1 fail, 1 n/a) at HEAD ${C1:0:7}"
assert_eq "# Manual QA: $ID" "$(sed -n 1p "$MQ")"
[[ "$(sed -n 2p "$MQ")" =~ ^HEAD\ $C1\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "line 2 is not HEAD <sha> <time>: $(sed -n 2p "$MQ")"
[[ "$(sed -n 3p "$MQ")" == "By: Sunit  Joshi on "* ]] || fail "line 3 is not By: <who> on <machine>: $(sed -n 3p "$MQ")"
assert_eq "| Step | Result |" "$(sed -n 5p "$MQ")"; assert_eq "|---|---|" "$(sed -n 6p "$MQ")"
assert_eq "| Add a todo with Enter | pass |" "$(sed -n 7p "$MQ")"
assert_eq "| tab/pipe/and newline | fail |" "$(sed -n 8p "$MQ")"   # every | becomes /, a newline a space
assert_eq "| $(head -c 200 /dev/zero | tr '\0' z) | n/a |" "$(sed -n 9p "$MQ")"   # cut at 200
assert_eq "| Delete removes it | pass |" "$(sed -n 10p "$MQ")"      # trimmed, result lower-cased
assert_eq 10 "$(wc -l < "$MQ" | tr -d ' ')"
mq "$ID" --by B --step "only|pass"; assert_eq 0 "$code"; assert_eq 7 "$(wc -l < "$MQ" | tr -d ' ')"; assert_contains "$(sed -n 3p "$MQ")" "By: B on"   # replaced
[[ -z "$(ls -A "$ED" | grep -v '^manual-qa.md$' || true)" ]] || fail "manual-qa left a temp file: $(ls -A "$ED")"

# --- the pre-flight ---
rm "$MQ"
# no [manual] criterion, no record: exactly as before
criteria "- [ ] one\n- [ ] two\n"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "no stamped logs"
# a [manual] criterion (the number counts all criteria; the Test Plan's tag is not a criterion) and no record: refused with the question
criteria "- [ ] one\n- [x] [manual] The list looks right in a browser\n- [ ] three\n"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md missing: criterion 2 is tagged [manual] (The list looks right in a browser)"
assert_contains "$out" "sprint manual-qa $ID --by"; assert_contains "$out" "do not dispatch it yet"
# a fresh record clears it
mq "$ID" --by Sunit --step "list looks right|pass" --step "dark mode|n/a"; assert_eq 0 "$code"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "ok      manual-qa.md (HEAD ${C1:0:7} = graded, by Sunit, 2 steps: 1 pass)"
assert_contains "$out" "check-evidence: ok (1 log(s) fresh with exit 0 or covered, plus the user's manual QA)"
# with a log: both listed, both counted
printf 'HEAD %s 2026-10-14T10:00:00Z\nexit 0\n' "$C1" > "$ED/a.log"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "ok      fresh a.log"; assert_contains "$out" "ok      manual-qa.md"
# a bad log still refuses and the record stays ok
printf 'HEAD %s 2026-10-14T10:00:00Z\nexit 3\n' "$C1" > "$ED/a.log"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  fresh a.log exit=3"; assert_contains "$out" "ok      manual-qa.md"; rm "$ED/a.log"
# a record on a ticket with no [manual] criterion is still listed
criteria "- [ ] one\n"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "ok      manual-qa.md"
# stale: the code changed after the user tested it (a ticket-folder change does not count)
echo "late" > "$TD/notes.md"; ce "$ID"; assert_eq 0 "$code"
echo b >> src/a.txt; git commit -qam code
criteria "- [ ] [manual] looks right\n"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md stale: recorded at ${C1:0:7} by Sunit; tracked files changed since"
assert_contains "$out" "ask them to re-test"
mq "$ID" --by Sunit --step "re-tested|pass"; ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "ok      manual-qa.md"
# failing step: refused on any ticket
mq "$ID" --by Sunit --step "a|pass" --step "b|fail"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md failing: 1 failing step(s) recorded by Sunit"
# a malformed or hand-edited record is refused, named
mq "$ID" --by Sunit --step "a|pass"
sed -i.bak '2s/.*/HEAD whatever/' "$MQ"; rm -f "$MQ.bak"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md bad: line 2 is not 'HEAD <sha> <UTC time>'"
mq "$ID" --by Sunit --step "a|pass"; printf '| rogue row without a result |\n' >> "$MQ"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md bad: a table row is not"
mq "$ID" --by Sunit --step "a|pass"; rm "$MQ"; ln -s "$WORK/x" "$MQ"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  manual-qa.md bad: it is a symlink"; rm "$MQ"
# an id other than the ticket's in line 1
printf '# Manual QA: t-zzzz\nHEAD %s 2026-10-14T10:00:00Z\nBy: A on m\n\n| Step | Result |\n|---|---|\n| a | pass |\n' "$(git rev-parse HEAD)" > "$MQ"
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "bad: line 1 is not '# Manual QA: $ID'"; rm "$MQ"

printf 'sprint-manual-qa: ok\n'
