#!/usr/bin/env bash
# t-4cd8: tkt sync-issues turns open issues labelled canon into tickets, through import-issue's parser; it skips pull
# requests, linked issues and send-issue's own issues, reads GitHub only, and untrusted text never picks an id or a path.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
stub="$(mktemp -d "${TMPDIR:-/tmp}/tkt-sync.XXXXXX")"
trap 'rm -rf "$project" "$stub"' EXIT
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
    repos/acme/app/issues\?*) [[ "${STUB_FAIL:-}" == list ]] && { echo "HTTP 502" >&2; exit 1; }; cat "$STUB_DIR/list"; exit 0 ;;
  esac
done
echo "unexpected gh api call: $*" >&2; exit 9
SH
chmod +x "$stub/gh"
export PATH="$stub:$PATH" STUB_LOG="$stub/log" STUB_DIR="$stub"
T=$'\t'

# mklist <n:kind:labels>...: the listing for those issues, from their issue-N files.
mklist() {
  local e n kind labels
  for e in "$@"; do
    IFS=: read -r n kind labels <<< "$e"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$labels" \
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
# The issues: 11 plain (bug, P1), 12 structured (CRLF), 13 linked already, 14 made by send-issue, 15 a pull request, 16 hostile.
mklist 11:issue:canon,bug,P1 12:issue:canon 13:issue:canon 14:issue:canon 15:pr:canon '16:issue:canon,*'
linked="$("$TKT" create "Linked one")"
awk -v g="github: acme/app#13" '/^---$/ && ++n == 2 { print g } { print }' ".tickets/$linked/ticket.md" > "$stub/t" && mv "$stub/t" ".tickets/$linked/ticket.md"
snap() { find .tickets -type f -print0 | sort -z | xargs -0 cksum; }

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

# The run: three tickets, linked to their issues, typed from labels; only GET reads on GitHub.
: > "$STUB_LOG"
out="$("$TKT" sync-issues)"
assert_contains "$out" "sync-issues: 3 created"
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

# A second run creates nothing.
again="$("$TKT" sync-issues)"
assert_contains "$again" "sync-issues: 0 created"
assert_contains "$again" "skip  #11  already $t11"

# gh failing, or an origin not on GitHub: exit 1, the reason, nothing written.
printf 'New\nx\n' > "$stub/issue-17"; mklist 17:issue:canon; before="$(snap)"
rc=0; err="$(STUB_FAIL=list "$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "gh failing should exit 1, got $rc"
assert_contains "$err" "sync-issues: gh could not list issues"
assert_eq "$before" "$(snap)"
# A listing entry that does not decode: exit 1 before any ticket is made, even for the good entry before it.
printf '17\tissue\tcanon\tTmV3\teA==\n18\tissue\tcanon\t!!!not-base64\teA==\n' > "$stub/list"
rc=0; err="$("$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an undecodable entry should exit 1, got $rc: $err"
assert_eq "$before" "$(snap)"
git remote set-url origin https://gitlab.com/acme/app.git; : > "$STUB_LOG"
rc=0; err="$("$TKT" sync-issues 2>&1)" || rc=$?
[[ "$rc" == 1 && ! -s "$STUB_LOG" ]] || fail "a GitLab origin should exit 1 before any gh call (rc $rc)"
assert_contains "$err" "origin is not a GitHub repo"

echo "tkt-sync-issues: ok"
