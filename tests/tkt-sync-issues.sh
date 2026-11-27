#!/usr/bin/env bash
# t-4cd8: tkt sync-issues turns open issues labelled canon into tickets, through import-issue's parser; it skips pull
# requests, linked issues and send-issue's own issues, reads GitHub only, and untrusted text never picks an id or a path.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
stub="$(mktemp -d "${TMPDIR:-/tmp}/tkt-sync.XXXXXX")"
trap 'rm -rf "$project" "$stub"' EXIT
# t-9641: a real sync emits github.synced through the board binary. Build it from this tree (an installed one may not know
# the kind) and keep every event in this run's own home: CANON_HOME and HOME both, so a broken override cannot reach ~/.canon.
use_fresh_board "$stub"
export CANON_HOME="$stub/canon-home" HOME="$stub/home"; mkdir -p "$HOME"
# jx <python expr over d>: the expression on the JSON read from stdin, compact JSON (a str prints raw).
jx() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v,separators=(",",":"),ensure_ascii=False))' "$1"; }
synced() { cat "$CANON_HOME"/events/*.jsonl 2>/dev/null | grep -cF '"kind":"github.synced"' || true; }
cd "$project"
git remote add origin https://github.com/acme/app.git

# A stub gh playing GitHub's REST listing: it prints $stub/list, the TSV the --jq would make (number, kind, labels, title
# and body base64-encoded), built by mklist from $stub/issue-N (title line, then body). There is no per-issue answer: the
# labels and the text must come from one snapshot. STUB_FAIL=list fails the listing. Every call is logged.
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[[ "$1" == api ]] || { echo "unexpected gh call: $*" >&2; exit 9; }
for a in "$@"; do
  case "$a" in
    repos/acme/app/issues\?*) [[ "${STUB_FAIL:-}" == list ]] && { echo "HTTP 502" >&2; exit 1; }
      # STUB_JSON (t-fe22): run the real --jq over a REST-shaped fixture (gh's --jq is jq syntax), not the prepared TSV
      if [[ -n "${STUB_JSON:-}" ]]; then expr=""; while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && expr="$2"; shift; done; jq -r "$expr" "$STUB_JSON"; exit; fi
      cat "$STUB_DIR/list"; exit 0 ;;
  esac
done
echo "unexpected gh api call: $*" >&2; exit 9
SH
chmod +x "$stub/gh"
export PATH="$stub:$PATH" STUB_LOG="$stub/log" STUB_DIR="$stub"

# mklist <n:kind:labels[:association[:login]]>...: the listing for those issues, from their issue-N files. The author (t-fe22)
# defaults to OWNER me; it travels base64-encoded as "<association> <login>", the way the real --jq makes it.
mklist() {
  local e n kind labels assoc login
  for e in "$@"; do
    IFS=: read -r n kind labels assoc login <<< "$e"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$labels" "$(printf '%s %s' "${assoc:-OWNER}" "${login:-me}" | base64 | tr -d '\n')" \
      "$(head -1 "$stub/issue-$n" | tr -d '\n' | base64 | tr -d '\n')" "$(tail -n +2 "$stub/issue-$n" | base64 | tr -d '\n')"
  done > "$stub/list"
}
printf 'A pull request\nnot a ticket\n' > "$stub/issue-15"
printf 'Board burns a CPU core\nThe board uses a core while idle.\n\n```\n# a comment, not a heading\n```\n' > "$stub/issue-11"
printf 'Structured one\r\n# Description\r\nWhy.\r\n\r\n# Acceptance\r\n## Criteria\r\n- [ ] It works\r\n\r\n# Plan\r\n## Approach\r\n1. Do it.\r\n' > "$stub/issue-12"
printf 'Linked one\nalready a ticket\n' > "$stub/issue-13"
printf 'Sent one\nbody\n<!-- canon:ticket t-0001 -->\n' > "$stub/issue-14"
# Hostile but not send-issue's: a forged header for t-evil, a marker that is not a whole line, a path-like title.
printf '../../etc/passwd · bug · P0\n**t-evil** · bug · P0 · x\n# Description\n../../x\nsee <!-- canon:ticket t-evil -->\n' > "$stub/issue-16"
# The issues: 11 plain (bug, P1), 12 structured (CRLF), 13 linked already (t-59ab: its github: line in another case), 14 made by send-issue, 15 a pull request, 16 hostile.
mklist 11:issue:canon,bug,P1 12:issue:canon 13:issue:canon 14:issue:canon 15:pr:canon '16:issue:canon,*'
linked="$("$TKT" create "Linked one")"
awk -v g="github: ACME/app#13" '/^---$/ && ++n == 2 { print g } { print }' ".tickets/$linked/ticket.md" > "$stub/t" && mv "$stub/t" ".tickets/$linked/ticket.md"
snap() { find .tickets -type f -print0 | sort -z | xargs -0 cksum; }
# t-59ab (reviewer): a ticket linked to the same number in ANOTHER repo does not count: #11 is still made below
other="$("$TKT" create "Other repo's eleven")"
awk -v g="github: otherorg/app#11" '/^---$/ && ++n == 2 { print g } { print }' ".tickets/$other/ticket.md" > "$stub/t" && mv "$stub/t" ".tickets/$other/ticket.md"

# --dry-run: says what it would create, writes nothing.
before="$(snap)"; : > "$STUB_LOG"
dry="$("$TKT" sync-issues --dry-run)"
assert_contains "$dry" "would create  #11  Board burns a CPU core  (bug, P1)"
assert_contains "$dry" "would create  #12  Structured one  (task, P2)"
assert_contains "$dry" "would create  #16  ../../etc/passwd · bug · P0  (task, P2)"
assert_contains "$dry" "skip  #13  already $linked"
assert_contains "$dry" "skip  #14  made by tkt send-issue"
assert_contains "$dry" "dry run: 3 to create, nothing written"
[[ "$dry" != *"#15"* ]] || fail "a pull request was listed: $dry"
assert_eq "$before" "$(snap)"

# --dry-run --json (t-9641, Factory > GitHub's Intake): the same answer as one object, nothing written, no event.
json="$("$TKT" sync-issues --dry-run --json)"
[[ "$(printf '%s\n' "$json" | wc -l | tr -d ' ')" == 1 ]] || fail "--json printed more than one line: $json"
assert_eq "$(printf '%s' "$json" | jx '{"repo":d["repo"],"label":d["label"]}')" '{"repo":"acme/app","label":"canon"}'
assert_eq "$(printf '%s' "$json" | jx '[[w["issue"],w["type"],w["priority"]] for w in d["waiting"]]')" '[[11,"bug",1],[12,"task",2],[16,"task",2]]'
assert_eq "$(printf '%s' "$json" | jx 'd["waiting"][2]["title"]')" '../../etc/passwd · bug · P0'
assert_eq "$(printf '%s' "$json" | jx '[k["issue"] for k in d["skipped"]]')" '[13,14]'
assert_contains "$(printf '%s' "$json" | jx 'd["skipped"][0]["reason"]')" "already $linked"
assert_eq "$before" "$(snap)"
assert_eq 0 "$(synced)"
rc=0; err="$("$TKT" sync-issues --json 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "--json without --dry-run should exit 1, got $rc"
assert_contains "$err" "--json needs --dry-run"
assert_eq "$before" "$(snap)"

# The run: three tickets, linked to their issues, typed from labels; only GET reads on GitHub.
: > "$STUB_LOG"
out="$("$TKT" sync-issues)"
assert_contains "$out" "sync-issues: 3 created"
# t-9641: one github.synced for the run, for this project, with the count made.
assert_eq 1 "$(synced)"
ev="$(cat "$CANON_HOME"/events/*.jsonl | grep -F '"kind":"github.synced"' | tail -1)"
assert_eq "$(printf '%s' "$ev" | jx '[d["source"],d["data"]["count"]]')" '["tkt","3"]'
assert_eq "$(printf '%s' "$ev" | jx 'd["project"]')" "$(cd "$project" && pwd -P)"
grep -v '^api ' "$STUB_LOG" && fail "a gh call other than api: $(cat "$STUB_LOG")"
grep -qE -- '(-X|--method)' "$STUB_LOG" && fail "a non-GET gh api call: $(cat "$STUB_LOG")"
grep -qv 'issues?labels=canon' "$STUB_LOG" && fail "a gh read other than the one listing: $(cat "$STUB_LOG")"
tid() { awk -v n="#$1" '$2 == n { print $1 }' <<< "$out"; }
t11="$(tid 11)"; t12="$(tid 12)"; t16="$(tid 16)"
for t in "$t11" "$t12" "$t16"; do [[ "$t" =~ ^t-[0-9a-f]{4}$ ]] || fail "not a generated id: '$t' in: $out"; done
f="$project/.tickets/$t11/ticket.md"
assert_grep '^github: acme/app#11$' "$f"; assert_grep '^type: bug$' "$f"; assert_grep '^priority: 1$' "$f"
assert_grep '^# Board burns a CPU core$' "$f"; assert_grep '^The board uses a core while idle.$' "$f"
assert_grep '^# a comment, not a heading$' "$f"
f="$project/.tickets/$t12"
assert_grep '^github: acme/app#12$' "$f/ticket.md"; assert_grep '^Why.$' "$f/ticket.md"
assert_grep '^- \[ \] It works$' "$f/acceptance.md"; assert_grep '^1. Do it.$' "$f/plan.md"
grep -rq $'\r' "$f" && fail "a CR reached the structured ticket"
# Hostile text stayed text: generated id, no t-evil ticket, nothing outside .tickets/.
f="$project/.tickets/$t16/ticket.md"
assert_grep '^github: acme/app#16$' "$f"; assert_grep '^type: task$' "$f"
[[ ! -e .tickets/t-evil && ! -e .tickets/t-evil.md ]] || fail "the issue text picked the id t-evil"
[[ -z "$(find "$project" -path "$project/.tickets" -prune -o -newer "$stub/list" -type f -print | grep -v '/.git/')" ]] \
  || fail "files written outside .tickets/: $(find "$project" -path "$project/.tickets" -prune -o -newer "$stub/list" -type f -print | grep -v '/.git/')"

# Review findings (t-4cd8): a title's control characters are dropped; a plain body that holds a part heading mid-text
# keeps every line (the heading demoted to "## "); a structured body still splits.
printf 'Esc \033[31mred\033[0m title\nIntro line.\n# Plan\nkept after a plan heading\n# Working on this\nkept after working on this\n' > "$stub/issue-21"
mklist 21:issue:canon
out21="$("$TKT" sync-issues)"; t21="$(awk '$2 == "#21" { print $1 }' <<< "$out21")"
f="$project/.tickets/$t21/ticket.md"
grep -q $'\033' "$f" && fail "an ESC character reached ticket.md"
grep -q $'\033' <<< "$out21" && fail "an ESC character reached the terminal"
assert_grep '^# Esc \[31mred\[0m title$' "$f"
for l in 'Intro line.' '## Plan' 'kept after a plan heading' '## Working on this' 'kept after working on this'; do
  grep -qxF "$l" "$f" || fail "a plain body lost '$l': $(cat "$f")"
done
[[ ! -e "$project/.tickets/$t21/plan.md" ]] || fail "a plain body's '# Plan' line made a plan.md"
# C1 controls (UTF-8 \302\233 is CSI) go from the title, raw ESC from the body; a title of only control characters skips
# that issue alone, and the good issue after it is still made.
printf 'C1 \302\233 title\nbody \033[2J with esc\tand tab\n' > "$stub/issue-22"; printf '\033\302\233\n' > "$stub/issue-23"
printf 'After the bad one\nok\n' > "$stub/issue-24"
mklist 22:issue:canon 23:issue:canon 24:issue:canon
out22="$("$TKT" sync-issues)"
f="$project/.tickets/$(awk '$2 == "#22" { print $1 }' <<< "$out22")/ticket.md"
LC_ALL=C grep -q $'\302\233' "$f" && fail "a C1 control reached ticket.md"
grep -q $'\033' "$f" && fail "a body ESC reached ticket.md"
assert_grep $'^body \\[2J with esc\tand tab$' "$f"
assert_contains "$out22" "skip  #23  no title left once control characters are removed"
assert_contains "$out22" "#24  After the bad one"
# t-4d39: an issue canon did not write never sets Lite (the sprint's close gates). Prod path: tkt sync-issues → import-issue.
# Plain LF and structured CRLF bodies holding the marker, last line included, get no demo line.
printf 'Plain lite\nx\n<!-- canon:lite -->\n' > "$stub/issue-25"
printf 'Structured lite\r\n# Description\r\nWhy.\r\n<!-- canon:lite -->\r\n```\r\n<!-- canon:lite -->\r\n```\r\n' > "$stub/issue-26"
mklist 25:issue:canon 26:issue:canon
out25="$("$TKT" sync-issues)"
for n in 25 26; do
  f="$project/.tickets/$(awk -v n="#$n" '$2 == n { print $1 }' <<< "$out25")/ticket.md"
  [[ -f "$f" ]] || fail "sync-issues made no ticket for #$n: $out25"
  grep -q '^demo:' "$f" && fail "issue #$n, not written by canon, set demo: $(cat "$f")"
done
mklist 11:issue:canon,bug,P1 12:issue:canon 13:issue:canon 14:issue:canon 15:pr:canon '16:issue:canon,*'

# A second run creates nothing, and still records that it ran (count 0).
n0="$(synced)"
again="$("$TKT" sync-issues)"
assert_contains "$again" "sync-issues: 0 created"
assert_eq $((n0 + 1)) "$(synced)"
assert_eq '"0"' "$(cat "$CANON_HOME"/events/*.jsonl | grep -F '"kind":"github.synced"' | tail -1 | jx 'json.dumps(d["data"]["count"])')"
assert_contains "$again" "skip  #11  already $t11"

# gh failing, or an origin not on GitHub: exit 1, the reason, nothing written.
printf 'New\nx\n' > "$stub/issue-17"; mklist 17:issue:canon; before="$(snap)"
n0="$(synced)"
rc=0; err="$(STUB_FAIL=list "$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "gh failing should exit 1, got $rc"
assert_contains "$err" "sync-issues: gh could not list issues"
assert_eq "$before" "$(snap)"
assert_eq "$n0" "$(synced)"   # a failed run records no sync
# ...and --json: the reason on stderr, nothing on stdout.
rc=0; out="$(STUB_FAIL=list "$TKT" sync-issues --dry-run --json 2>/dev/null)" || rc=$?
[[ "$rc" == 1 && -z "$out" ]] || fail "a failing listing under --json should exit 1 with no stdout (rc $rc): $out"
# A listing entry that does not decode: exit 1 before any ticket is made, even for the good entry before it.
printf '17\tissue\tcanon\tT1dORVIgbWU=\tTmV3\teA==\n18\tissue\tcanon\tT1dORVIgbWU=\t!!!not-base64\teA==\n' > "$stub/list"
rc=0; err="$("$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an undecodable entry should exit 1, got $rc: $err"
assert_eq "$before" "$(snap)"
# ...and a bad body after a good title, the same.
printf '17\tissue\tcanon\tT1dORVIgbWU=\tTmV3\t!!!not-base64\n' > "$stub/list"
rc=0; err="$("$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an undecodable body should exit 1, got $rc: $err"
assert_eq "$before" "$(snap)"

# --only (t-b045, the Cockpit's GitHub Sync table): the selection narrows what is created, never widens it.
printf 'Pick one\nx\n' > "$stub/issue-31"; printf 'Pick two\nx\n' > "$stub/issue-32"
mklist 31:issue:canon 32:issue:canon 11:issue:canon 14:issue:canon 15:pr:canon
before="$(snap)"; : > "$STUB_LOG"
# a value that is not a list of positive integers, or a number this run would not create (already a ticket, send-issue's own, a pull
# request, not listed), refuses with exit 1 and writes nothing, even when a valid number comes with it
for bad in abc 0 -3 "31," "31,,32" "11" "14" "15" "999" "31,999"; do
  rc=0; err="$("$TKT" sync-issues --only "$bad" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "--only '$bad' should exit 1, got $rc: $err"
  assert_eq "$before" "$(snap)"
done
rc=0; err="$("$TKT" sync-issues --only 2>&1)" || rc=$?; [[ "$rc" == 1 ]] || fail "--only with no value should exit 1, got $rc"
assert_contains "$err" "--only takes issue numbers"
rc=0; err="$("$TKT" sync-issues --bogus 2>&1)" || rc=$?; [[ "$rc" == 1 ]] || fail "an unknown option should exit 1, got $rc"
assert_contains "$err" "Usage: tkt sync-issues [--dry-run [--json]] [--only <number>[,<number>...]]"
rc=0; err="$("$TKT" sync-issues --only 999 2>&1)" || rc=$?
assert_contains "$err" "sync-issues: #999 is not waiting"   # the refusal names the number
out="$("$TKT" sync-issues --only 32,32)"   # a repeated number makes one ticket
assert_contains "$out" "#32  Pick two"; assert_contains "$out" "sync-issues: 1 created"
[[ "$(grep -rl '^github: acme/app#32$' .tickets | wc -l | tr -d ' ')" == 1 ]] || fail "--only 32,32 should make exactly one ticket for #32"
[[ -z "$(grep -rl '^github: acme/app#31$' .tickets || true)" ]] || fail "--only 32 also made a ticket for #31"
assert_contains "$("$TKT" sync-issues --dry-run)" "would create  #31  Pick one  (task, P2)"   # the unticked issue stays waiting
out="$("$TKT" sync-issues --only 31)"   # the first issue of the listing is selectable on its own
assert_contains "$out" "#31  Pick one"
[[ "$(grep -rl '^github: acme/app#31$' .tickets | wc -l | tr -d ' ')" == 1 ]] || fail "--only 31 should make exactly one ticket for #31"
# a repeated flag is refused (it used to replace the first, so --only 31 --only 32 made only #32); a comma list is the way
b0="$(snap)"; rc=0; err="$("$TKT" sync-issues --only 31 --only 32 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a repeated --only should exit 1, got $rc: $err"
assert_contains "$err" "--only may be given once"; assert_eq "$b0" "$(snap)"
# the preview names a closed local ticket so the issue can be closed on GitHub, and every skipped row carries its title and ticket
f11="$(grep -rl '^github: acme/app#11$' .tickets)"; f11="${f11%%$'\n'*}"   # the first match; no early-exit reader under pipefail
sed -i.bak 's/^status: .*/status: closed/' "$f11"; rm -f "$f11.bak"
pj="$("$TKT" sync-issues --dry-run --json)"
assert_eq "$(printf '%s' "$pj" | jx '[k["reason"] for k in d["skipped"] if k["issue"]==11]')" "[\"already $t11 (closed here): close #11 on GitHub\"]"
assert_eq "$(printf '%s' "$pj" | jx '[[k["title"],k["ticket"],k["ticket_status"]] for k in d["skipped"] if k["issue"]==11]')" "[[\"Board burns a CPU core\",\"$t11\",\"closed\"]]"
assert_eq "$(printf '%s' "$pj" | jx '[k["ticket"] for k in d["skipped"] if k["issue"]==14]')" '[""]'   # send-issue's own issue has no local ticket yet
for st in cancelled archived; do   # every status that means "done here" gets the close-on-GitHub hint
  sed -i.bak "s/^status: .*/status: $st/" "$f11"; rm -f "$f11.bak"
  assert_eq "$("$TKT" sync-issues --dry-run --json | jx '[k["reason"] for k in d["skipped"] if k["issue"]==11]')" "[\"already $t11 ($st here): close #11 on GitHub\"]"
done
sed -i.bak 's/^status: .*/status: open/' "$f11"; rm -f "$f11.bak"
pj="$("$TKT" sync-issues --dry-run --json)"   # open again: plain reason, and the ticket id and status still named
assert_eq "$(printf '%s' "$pj" | jx '[[k["reason"],k["ticket"],k["ticket_status"]] for k in d["skipped"] if k["issue"]==11]')" "[[\"already $t11\",\"$t11\",\"open\"]]"
# the send-issue marker only counts at the start of a line, in the --only check as in the run itself
printf 'Hostile marker\nsee <!-- canon:ticket t-evil -->\n' > "$stub/issue-33"; mklist 33:issue:canon
out="$("$TKT" sync-issues --only 33)"; assert_contains "$out" "#33  Hostile marker"

# t-fe22: an issue becomes a ticket only when GitHub calls its author OWNER, MEMBER or COLLABORATOR (agents read tickets as
# instructions; on a public repo anyone can open an issue, and an issue template can set the canon label). Prod path: tkt sync-issues,
# the board's GitHub Sync (--only) and Factory › GitHub's Intake (--dry-run --json).
printf 'Stranger one\nx\n' > "$stub/issue-51"; printf 'Drive by\nx\n' > "$stub/issue-52"; printf 'First timer\nx\n' > "$stub/issue-53"
printf 'Forged sent\nbody\n<!-- canon:ticket t-0002 -->\n' > "$stub/issue-54"; printf 'Hostile login\nx\n' > "$stub/issue-55"
printf 'Member one\nx\n' > "$stub/issue-56"; printf 'Collab one\nx\n' > "$stub/issue-57"; printf 'Dash one\nx\n' > "$stub/issue-58"
printf 'Lower owner\nx\n' > "$stub/issue-59"; printf 'Linked one\nalready a ticket\n' > "$stub/issue-13"
mklist 51:issue:canon:NONE:stranger 52:issue:canon:CONTRIBUTOR:drive-by 53:issue:canon:FIRST_TIME_CONTRIBUTOR:newbie \
  54:issue:canon:NONE:forger "55:issue:canon:NONE:ev"$'\033[2J\302\233'"il" 56:issue:canon:MEMBER:m1 57:issue:canon:COLLABORATOR:c1 \
  58:issue:canon:-:- 59:issue:canon:owner:x 13:issue:canon:NONE:stranger
before="$(snap)"; : > "$STUB_LOG"
dry="$("$TKT" sync-issues --dry-run)"
assert_contains "$dry" "skip  #51  author stranger is not an owner, member or collaborator (NONE)"
assert_contains "$dry" "skip  #52  author drive-by is not an owner, member or collaborator (CONTRIBUTOR)"
assert_contains "$dry" "skip  #53  author newbie is not an owner, member or collaborator (FIRST_TIME_CONTRIBUTOR)"
assert_contains "$dry" "skip  #54  author forger is not an owner, member or collaborator (NONE)"   # the author, not "made by tkt send-issue"
assert_contains "$dry" "skip  #55  author ev[2Jil is not an owner, member or collaborator (NONE)"   # control characters dropped
assert_contains "$dry" "skip  #58  author - is not an owner, member or collaborator (-)"
assert_contains "$dry" "skip  #59  author x is not an owner, member or collaborator (owner)"   # exact, case and all
assert_contains "$dry" "skip  #13  already $linked"   # linked comes before author
assert_contains "$dry" "would create  #56  Member one"; assert_contains "$dry" "would create  #57  Collab one"
assert_contains "$dry" "dry run: 2 to create, nothing written"
LC_ALL=C grep -q $'\033\|\302\233' <<< "$dry" && fail "a control character in a login reached the terminal"
pj="$("$TKT" sync-issues --dry-run --json)"
assert_eq "$(printf '%s' "$pj" | jx '[w["issue"] for w in d["waiting"]]')" '[56,57]'
assert_eq "$(printf '%s' "$pj" | jx '[k["reason"] for k in d["skipped"] if k["issue"]==52]')" '["author drive-by is not an owner, member or collaborator (CONTRIBUTOR)"]'
for bad in 51 54 58 "56,51"; do
  rc=0; err="$("$TKT" sync-issues --only "$bad" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "--only $bad (an untrusted author) should exit 1, got $rc: $err"
  assert_contains "$err" "is from an author who is not an owner, member or collaborator"
done
assert_eq "$before" "$(snap)"
out="$("$TKT" sync-issues)"
assert_contains "$out" "sync-issues: 2 created"
for n in 51 52 53 54 55 58 59; do [[ -z "$(grep -rl "^github: acme/app#$n\$" .tickets || true)" ]] || fail "an untrusted author's #$n became a ticket"; done
for n in 56 57; do [[ -n "$(grep -rl "^github: acme/app#$n\$" .tickets || true)" ]] || fail "a trusted author's #$n made no ticket: $out"; done
[[ "$(grep -c 'issues?labels=canon' "$STUB_LOG")" == 7 && "$(wc -l < "$STUB_LOG" | tr -d ' ')" == 7 ]] || fail "one listing per run (7 runs), nothing else: $(cat "$STUB_LOG")"
# The real --jq (needs jq): a REST-shaped fixture with every association shape, a null user and a missing field, plus a few hundred
# random shapes (control bytes, CR, spaces, unicode, ../). Output stays one JSON object; only the three associations are waiting.
if command -v jq >/dev/null 2>&1; then
  python3 - "$stub/rest.json" <<'PY2'
import json, random, sys
random.seed(7)
fixed = [("OWNER", "me"), ("MEMBER", "m"), ("COLLABORATOR", "c"), ("CONTRIBUTOR", "x"), ("FIRST_TIME_CONTRIBUTOR", "x"),
         ("FIRST_TIMER", "x"), ("MANNEQUIN", "x"), ("NONE", "x"), ("", "x"), (None, "x"), ("MISSING", None), ("OWNER", None)]
alpha = ["OWNER", "MEMBER", "COLLABORATOR", "owner", " OWNER", "OWNER ", "OWNER\r", "OWNER\tX", "\x1b[2J", " ", "../", "OW\nNER", "", "MEMBER ", "COLLAB"]
out = []
for i, (a, l) in enumerate(fixed + [(random.choice(alpha) + random.choice(["", "x", "é"]), random.choice(["", "me", "a b", "\x1b", "\x00", "../x", "\r"])) for _ in range(300)]):
    it = {"number": 100 + i, "labels": [{"name": "canon"}], "title": "T%d" % i, "body": "b"}
    if a != "MISSING": it["author_association"] = a
    it["user"] = None if l is None else {"login": l}
    out.append(it)
json.dump(out, open(sys.argv[1], "w"))
PY2
  pj="$(STUB_JSON="$stub/rest.json" "$TKT" sync-issues --dry-run --json)" || fail "sync-issues failed on the REST fixture"
  [[ "$(printf '%s\n' "$pj" | wc -l | tr -d ' ')" == 1 ]] || fail "--json printed more than one line on the fuzz fixture"
  python3 - "$stub/rest.json" "$pj" <<'PY2' || fail "the real --jq let an untrusted author through"
import json, sys
src = {i["number"]: i for i in json.load(open(sys.argv[1]))}
d = json.loads(sys.argv[2])
ok = {"OWNER", "MEMBER", "COLLABORATOR"}
w = [x["issue"] for x in d["waiting"]]
assert w[:3] == [100, 101, 102], w[:3]
for n in w: assert src[n].get("author_association") in ok, (n, src[n])
for n, i in src.items():
    if i.get("author_association") in ok: assert n in w, n
for k in d["skipped"]: assert k["reason"].startswith("author "), k
for k in d["skipped"]:
    if k["issue"] in (108, 109, 110): assert k["reason"].endswith("(-)"), k   # empty, null, missing association
assert 111 in w   # a trusted association with no user still passes; its login prints as "-"
PY2
else echo "  note: jq not found; the real --jq checks did not run" >&2; fi
# Every path that makes a ticket from GitHub runs the one rule, and the board has no issue read of its own.
sec="$(awk '/^cmd_import_issue\(\)/,/^}/' "$ROOT/tools/tkt")"; [[ "$sec" == *'_trusted_author "$assoc"'* ]] || fail "cmd_import_issue does not call _trusted_author"
sec="$(awk '/^cmd_sync_issues\(\)/,/^}/' "$ROOT/tools/tkt")"; [[ "$sec" == *'_trusted_author "$assoc"'* ]] || fail "cmd_sync_issues does not call _trusted_author"
[[ -z "$(grep -lE 'gh.*api.*issues' "$ROOT"/tools/canon-go/internal/board/*.go | grep -v '_test.go$' || true)" ]] || fail "the board reads GitHub issues itself"
# The shipped docs state the rule.
for d in tools/ticket.md docs/setup.md; do
  for w in OWNER MEMBER COLLABORATOR; do grep -q "$w" "$ROOT/$d" || fail "$d does not name $w in the author rule"; done
done

# A project with no .tickets/ yet: a dry run, or a run that fails, creates nothing at all (not even .tickets/).
bare="$(mktemp -d "${TMPDIR:-/tmp}/tkt-sync-bare.XXXXXX")"; (cd "$bare" && git init -q && git remote add origin https://github.com/acme/app.git)
mklist 11:issue:canon,bug,P1
(cd "$bare" && "$TKT" sync-issues --dry-run >/dev/null) || fail "dry run in a bare project failed"
(cd "$bare" && STUB_FAIL=list "$TKT" sync-issues >/dev/null 2>&1) && fail "a failing listing should exit 1"
[[ ! -e "$bare/.tickets" ]] || fail "a dry or failed run created .tickets/: $(find "$bare/.tickets")"
rm -rf "$bare"

# Nothing labelled: --json gives empty lists; a real run still records a sync with count 0.
: > "$stub/list"
assert_eq '{"repo":"acme/app","label":"canon","waiting":[],"skipped":[]}' "$("$TKT" sync-issues --dry-run --json)"
n0="$(synced)"; "$TKT" sync-issues --dry-run >/dev/null
assert_eq "$n0" "$(synced)"   # t-9641 eval: a dry run with nothing labelled records no sync (the board's preview runs it)
"$TKT" sync-issues >/dev/null
assert_eq $((n0 + 1)) "$(synced)"
# a listing that repeats an issue (gh --paginate can) makes one ticket for it, with or without --only
printf 'Twice listed\nx\n' > "$stub/issue-41"; mklist 41:issue:canon 41:issue:canon
out="$("$TKT" sync-issues --only 41)"; assert_contains "$out" "sync-issues: 1 created"
[[ "$(grep -rl '^github: acme/app#41$' .tickets | wc -l | tr -d ' ')" == 1 ]] || fail "a repeated listing entry made more than one ticket for #41"
printf 'Twice listed again\nx\n' > "$stub/issue-42"; mklist 42:issue:canon 42:issue:canon
out="$("$TKT" sync-issues)"; assert_contains "$out" "sync-issues: 1 created"
# --only with nothing waiting at all (an empty listing, or only a pull request) refuses with exit 1, writes nothing and records no sync
n1="$(synced)"; before="$(snap)"
for l in "" "15:pr:canon"; do
  if [[ -n "$l" ]]; then mklist "$l"; else : > "$stub/list"; fi
  for flags in "--only 5" "--dry-run --only 5" "--dry-run --json --only 15"; do
    rc=0; err="$("$TKT" sync-issues $flags 2>&1)" || rc=$?
    [[ "$rc" == 1 ]] || fail "sync-issues $flags with nothing waiting should exit 1, got $rc: $err"
    assert_contains "$err" "is not waiting"
  done
done
assert_eq "$n1" "$(synced)"; assert_eq "$before" "$(snap)"

git remote set-url origin https://gitlab.com/acme/app.git; : > "$STUB_LOG"
rc=0; err="$("$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 && ! -s "$STUB_LOG" ]] || fail "a GitLab origin should exit 1 before any gh call (rc $rc)"
assert_contains "$err" "origin is not a GitHub repo"

echo "tkt-sync-issues: ok"
