#!/usr/bin/env bash
# sprint-decisions (t-79bf) — `sprint decisions related|archive|mark`, the related lookup `sprint start` prints, and the row-length line
# `sprint complete` prints. Protects the commands that keep DECISIONS.md readable at any size (it is read by what applies, never whole, and an
# archive move or a fragment marker is a command, not a hand edit), in a scratch project that is not canon (no canon-only path).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # sprint start and complete write events through the board binary

project="$(make_project)"
rcfile="$(mktemp)"; trap 'rm -rf "$project" "$rcfile"' EXIT
cd "$project"
S="$SPRINT"
D=DECISIONS.md; A=DECISIONS-archive.md
rc() { set +e; out="$("$@" 2>&1)"; code=$?; set -e; }
first_id() { local o; o="$("$S" decisions related "$@")"; printf '%s' "${o%% *}"; }   # the id of the newest row that names the arguments

row() { printf '| %s | **`%s`: %s** | %s |\n' "$1" "$2" "$3" "$4"; }
rm -f "$D" "$A"
{
  printf '# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n'
  row 2026-11-07 t-aa01 'the count lives in static/board-logbook.js and nowhere else.' 'one owner'
  row 2026-11-06 t-bb02 'the daemon reads tools/canon-go/internal/board/main.go only.' 'a reason with a backslash \n and a pipe-free text'
  row 2026-11-05 t-cc03 'a composite: spinner and button; the button part is live. `a.sh` and ab are named.' 'two topics superseded-by: 2026-11-06 (the spinner part)'
  row 2026-11-04 t-dd04 'nothing about files at all.' 'unrelated'
  printf '\n## 2026-10-22 — t-ee05: a section entry, not a row (mentions static/board-logbook.js)\nProse about the same file.\n'
} > "$D"
printf '# Decisions — Archive\n\n| Date | Decision | Reason |\n|---|---|---|\n| 2026-01-01 | **`t-old1`: archived (static/board-logbook.js)** | gone |\n' > "$A"

# --- related: a path by its text or its basename, an id, several tokens (any), no match, short tokens, the archive and sections are not read ---
rc "$S" decisions related static/board-logbook.js; assert_eq 0 "$code"
assert_contains "$out" "2026-11-07  \`t-aa01\`: the count lives in static/board-logbook.js"
[[ "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")" == 1 ]] || fail "related: a path named by one row listed another row, a section or the archive: $out"
rc "$S" decisions related tools/sprint-check-app/static/board-logbook.js; assert_contains "$out" "t-aa01"   # not the full path: its basename
rc "$S" decisions related t-bb02; assert_contains "$out" "t-bb02"; [[ "$out" != *"t-aa01"* ]] || fail "related: an id matched another row"
rc "$S" decisions related main.go board-logbook.js; assert_eq 2 "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")"
rc "$S" decisions related ab x/ab; assert_contains "$out" "No DECISIONS.md row names"   # under 3 characters: never a match
rc "$S" decisions related nothing-names-this.xyz; assert_eq 0 "$code"; assert_eq "No DECISIONS.md row names nothing-names-this.xyz." "$out"
rc "$S" decisions related a.sh; assert_contains "$out" "t-cc03"; assert_contains "$out" "[fragment superseded]"
rc "$S" decisions related; assert_eq 2 "$code"; assert_contains "$out" "usage: sprint decisions related"
rc "$S" decisions related --bogus x; assert_eq 2 "$code"; assert_contains "$out" "unknown option"
rc "$S" decisions related --limit x y; assert_eq 2 "$code"; assert_contains "$out" "--limit needs a number"
rc "$S" decisions; assert_eq 2 "$code"; assert_contains "$out" "usage: sprint decisions related"
before="$(cat "$D" "$A" | cksum)"; rc "$S" decisions related static/board-logbook.js; [[ "$(cat "$D" "$A" | cksum)" == "$before" ]] || fail "related wrote a file"
mv "$D" "$D.bak"; rc "$S" decisions related x.sh; assert_eq 0 "$code"; assert_eq "No DECISIONS.md in this project." "$out"; mv "$D.bak" "$D"

# the cap: 15 rows naming one file list 12 and say how many more; --all lists all; --limit sets it
cp "$D" "$D.keep"
for i in $(seq 1 15); do row "2026-10-$(printf '%02d' "$i")" "t-f$(printf '%03d' "$i")" "a common file, common-file.sh, row $i." 'r' >> "$D"; done
rc "$S" decisions related common-file.sh; assert_eq 12 "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")"; assert_contains "$out" "... and 3 more rows name them"
rc "$S" decisions related common-file.sh --all; assert_eq 15 "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")"; [[ "$out" != *"more rows"* ]] || fail "--all printed a more line"
rc "$S" decisions related common-file.sh --limit 2; assert_eq 2 "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")"; assert_contains "$out" "... and 13 more rows"
cp "$D.keep" "$D"; rm "$D.keep"

# --- mark: one row, in place; the cell shape; \r kept; refusals ---
id="$(first_id t-aa01)"
cp "$D" "$D.before"
rc "$S" decisions mark "$id" 2026-11-08 'the "count" part, not the \n owner'; assert_eq 0 "$code"; assert_contains "$out" "marked $id"
assert_eq 1 "$(diff "$D.before" "$D" | grep -c '^>')"; assert_eq 1 "$(diff "$D.before" "$D" | grep -c '^<')"
grep -qF 'one owner superseded-by: 2026-11-08 (the "count" part, not the \n owner) |' "$D" || fail "mark: the cell is not Reason + superseded-by: date (fragment): $(grep 't-aa01' "$D")"
[[ "$(wc -l < "$D")" == "$(wc -l < "$D.before")" ]] || fail "mark changed the line count"
rc "$S" decisions related t-aa01; assert_contains "$out" "[fragment superseded]"
rc "$S" decisions mark "$id" 2026-11-08 'the "count" part, not the \n owner'; assert_eq 2 "$code"   # the row id changed with its text: the old id is gone
rc "$S" decisions mark deadbeef 2026-11-08 x; assert_eq 2 "$code"; assert_contains "$out" "no DECISIONS.md row has the id deadbeef"
rc "$S" decisions mark xyz 2026-11-08 x; assert_eq 2 "$code"; assert_contains "$out" "8-hex row id"
nid="$(first_id t-bb02)"
rc "$S" decisions mark "$nid" 2026-13-1 x; assert_eq 2 "$code"; assert_contains "$out" "YYYY-MM-DD"
rc "$S" decisions mark "$nid" 2026-11-08 'a | pipe'; assert_eq 2 "$code"; assert_contains "$out" "without a |"
rc "$S" decisions mark "$nid" 2026-11-08 ""; assert_eq 2 "$code"
cmp -s "$D" <(cat "$D") || true
# a CRLF row keeps its \r
cp "$D" "$D.lf"; sed -i.b 's/$/\r/' "$D"; rm -f "$D.b"
cid="$(first_id t-bb02)"
rc "$S" decisions mark "$cid" 2026-11-08 'crlf part'; assert_eq 0 "$code"
[[ "$(LC_ALL=C grep 't-bb02' "$D" | od -c)" == *'\r'* ]] || fail "mark dropped a \\r"
[[ "$(LC_ALL=C grep -c 'superseded-by: 2026-11-08 (crlf part) |' "$D")" == 1 ]] || fail "mark: the CRLF row did not get the marker"
cp "$D.lf" "$D"; rm "$D.lf" "$D.before"

# --- archive: the whole row, byte for byte, to the archive's end; nothing else moves; refusals change nothing ---
did="$(first_id t-dd04)"
rc "$S" decisions archive "$did"; assert_eq 2 "$code"; assert_contains "$out" "--by <t-xxxx>"
rc "$S" decisions archive "$did" --by nope; assert_eq 2 "$code"
rc "$S" decisions archive deadbeef --by t-zzzz; assert_eq 2 "$code"; assert_contains "$out" "no DECISIONS.md row has the id deadbeef"
rc "$S" decisions archive notanid --by t-zzzz; assert_eq 2 "$code"
cp "$D" "$D.before"; cp "$A" "$A.before"
LC_ALL=C grep 't-dd04' "$D" > "$project/the-row.txt"
rc "$S" decisions archive "$did" --by t-zzzz; assert_eq 0 "$code"; assert_contains "$out" "archived $did (by t-zzzz)"
[[ "$(cat "$project/the-row.txt")" == "$(tail -1 "$A")" ]] || fail "archive: the row is not the last line of the archive, byte for byte"
! grep -q 't-dd04' "$D" || fail "archive: the row is still in DECISIONS.md"
[[ "$(cat "$D.before" "$A.before" | LC_ALL=C sort | cksum)" == "$(cat "$D" "$A" | LC_ALL=C sort | cksum)" ]] || fail "archive: a sorted-line diff of both files shows more than the one row moved"
assert_eq "$(( $(wc -l < "$D.before") - 1 ))" "$(wc -l < "$D" | tr -d ' ')"; assert_eq "$(( $(wc -l < "$A.before") + 1 ))" "$(wc -l < "$A" | tr -d ' ')"
rc "$S" decisions related t-dd04; assert_contains "$out" "No DECISIONS.md row names"   # the archive is not read
# two identical rows share an id: refused, both stay
cp "$D" "$D.before"; cat "$project/the-row.txt" "$project/the-row.txt" >> "$D"; cp "$D" "$D.dup"; cp "$A" "$A.before"
did="$(first_id t-dd04)"
rc "$S" decisions archive "$did" --by t-zzzz; assert_eq 2 "$code"; assert_contains "$out" "matches 2 rows; nothing was changed"
cmp -s "$D" "$D.dup" && cmp -s "$A" "$A.before" || fail "a refused archive changed a file"
cp "$D.before" "$D"; rm -f "$D.dup" "$D.before" "$A.before"
# no archive file yet: one is made with its header; a symbolic link is refused
rm "$A"; did="$(first_id t-cc03)"
rc "$S" decisions archive "$did" --by t-zzzz; assert_eq 0 "$code"; assert_grep '^# Decisions — Archive$' "$A"; assert_grep '^\| Date \| Decision \| Reason \|$' "$A"
ln -s "$A" "$project/link-archive"; mv "$A" "$A.real"; ln -s "$A.real" "$A"
did="$(first_id t-aa01)"
rc "$S" decisions archive "$did" --by t-zzzz; assert_eq 2 "$code"; assert_contains "$out" "symbolic link"
rm "$A"; mv "$A.real" "$A"; rm -f "$project/link-archive" "$project/the-row.txt"
mv "$D" "$D.real"; ln -s "$D.real" "$D"; rc "$S" decisions mark "$did" 2026-11-08 x; assert_eq 2 "$code"; assert_contains "$out" "symbolic link"; rm "$D"; mv "$D.real" "$D"

# --- sprint start: the rows that name what the ticket names (at most 8), nothing otherwise, its output otherwise unchanged ---
start_out() { set +e; out="$("$S" start "$1" 2>&1)"; printf '%s' "$?" > "$rcfile"; set -e; "$TKT" close "$(awk '/Sprint started:/ { print $3 }' <<<"$out")" --no-sprint >/dev/null 2>&1 || true; }
for i in $(seq 1 12); do row "2026-09-$(printf '%02d' "$i")" "t-g$(printf '%03d' "$i")" "the start lookup file, start-lookup.sh, row $i." 'r' >> "$D"; done
start_out "fix start-lookup.sh and t-aa01"; assert_eq 0 "$(cat "$rcfile")"
assert_contains "$out" "Sprint started:"; assert_contains "$out" "Related decisions (read these, not the whole DECISIONS.md"
assert_eq 8 "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")"
start_out "a title that names nothing in the file"; assert_eq 0 "$(cat "$rcfile")"; [[ "$out" != *"Related decisions"* ]] || fail "start printed a lookup for a ticket that names nothing: $out"
mv "$D" "$D.bak"; start_out "touch start-lookup.sh"; [[ "$out" != *"Related decisions"* && "$out" != *"No such file"* ]] || fail "start complained with no DECISIONS.md: $out"
assert_eq 0 "$(cat "$rcfile")"; rm -f "$D"; mv "$D.bak" "$D"

# --- guards and edges (each was a surviving mutant of the first version) ---
rc "$S" help; assert_contains "$out" "sprint decisions related <path|t-xxxx>..."; assert_contains "$out" "mark <row-id>"
# ids differ for distinct rows of the same length; a token of exactly 3 characters (or a 3-character basename) matches, 2 does not
cp "$D" "$D.keep"
row 2026-08-01 t-ia01 'aaaa tkx here.' r >> "$D"; row 2026-08-02 t-ib01 'bbbb tky here.' r >> "$D"
[[ "$(first_id t-ia01)" != "$(first_id t-ib01)" ]] || fail "two different rows of the same length got the same id"
rc "$S" decisions related tkx; assert_contains "$out" "t-ia01"; rc "$S" decisions related x/tky; assert_contains "$out" "t-ib01"
rc "$S" decisions related tk; assert_contains "$out" "No DECISIONS.md row names"
# the rule is cut at 160 characters, and a row without superseded-by has no fragment tag
row 2026-08-03 t-ic01 "$(head -c 400 /dev/zero | tr '\0' w) lengthneedle.sh" r >> "$D"
rc "$S" decisions related lengthneedle.sh; [[ "$(wc -c <<<"$out" | tr -d ' ')" -le 190 ]] || fail "related printed more than the rule's first 160 characters: $out"
rc "$S" decisions related t-bb02; [[ "$out" != *"[fragment superseded]"* ]] || fail "an unmarked row was tagged as a superseded fragment"
cp "$D.keep" "$D"; rm "$D.keep"
# --limit: a number of 1 or more, with its value
rc "$S" decisions related x.sh --limit 0; assert_eq 2 "$code"; assert_contains "$out" "--limit needs a number"
rc "$S" decisions related x.sh --limit 5x; assert_eq 2 "$code"
rc "$S" decisions related x.sh --limit; assert_eq 2 "$code"; assert_contains "$out" "--limit needs a number"
# archive and mark: the row id, --by, the date and the fragment are exact; no readable file is a refusal
good="$(first_id t-bb02)"
for bad in "${good}x" "x${good}" "${good:0:7}" "${good}0" "0${good}" "ABCDEF12"; do
  rc "$S" decisions archive "$bad" --by t-zzzz; assert_eq 2 "$code"; assert_contains "$out" "8-hex row id"
  rc "$S" decisions mark "$bad" 2026-11-08 x; assert_eq 2 "$code"; assert_contains "$out" "8-hex row id"
done
for by in "--bx t-zzzz" "--by t-zzzzz" "--by xt-zzzz" "--by tzzzz" "--by T-ZZZZ"; do
  rc "$S" decisions archive "$good" $by; assert_eq 2 "$code"; assert_contains "$out" "--by <t-xxxx>"
done
for d in 2026-11-081 x2026-11-08 2026-1-08 26-11-08; do rc "$S" decisions mark "$good" "$d" x; assert_eq 2 "$code"; assert_contains "$out" "YYYY-MM-DD"; done
rc "$S" decisions mark "$good" 2026-11-08 $'a\nb'; assert_eq 2 "$code"; assert_contains "$out" "without a |"
rc "$S" decisions mark "$good" 2026-11-08 $'a\rb'; assert_eq 2 "$code"
rc "$S" decisions mark "$good"; assert_eq 2 "$code"
mv "$D" "$D.bak"; rc "$S" decisions archive "$good" --by t-zzzz; assert_eq 2 "$code"; assert_contains "$out" "no readable DECISIONS.md"
rc "$S" decisions mark "$good" 2026-11-08 x; assert_eq 2 "$code"; assert_contains "$out" "no readable DECISIONS.md"; mv "$D.bak" "$D"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$D"; rc "$S" decisions mark "$good" 2026-11-08 x; chmod 644 "$D"; assert_eq 2 "$code"; assert_contains "$out" "no readable DECISIONS.md"
fi
# the same mark twice: the second names the row by its new id and is refused as a duplicate
rc "$S" decisions mark "$good" 2026-11-08 'dup part'; assert_eq 0 "$code"
again="$(first_id t-bb02)"; [[ "$again" != "$good" ]] || fail "a marked row kept its id"
rc "$S" decisions mark "$again" 2026-11-08 'dup part'; assert_eq 2 "$code"; assert_contains "$out" "already carries superseded-by: 2026-11-08 (dup part)"
assert_eq 1 "$(grep -c 'dup part' "$D")"
# an archive with no final newline, and an empty one: the moved row starts its own line
before="$(grep -c '' "$D")"; printf '# Decisions — Archive\n\n| Date | Decision | Reason |\n|---|---|---|\n| 2026-01-01 | **`t-old1`: no newline at the end** | gone |' > "$A"
rc "$S" decisions archive "$again" --by t-zzzz; assert_eq 0 "$code"
[[ "$(tail -2 "$A" | head -1)" == '| 2026-01-01 | **`t-old1`: no newline at the end** | gone |' && "$(tail -1 "$A")" == *"t-bb02"* ]] || fail "archive: the moved row was glued to an archive that had no final newline: $(tail -3 "$A")"
row 2026-06-01 t-ie01 'for the empty archive.' r >> "$D"
: > "$A"; id2="$(first_id t-ie01)"; rc "$S" decisions archive "$id2" --by t-zzzz; assert_eq 0 "$code"; assert_eq 1 "$(grep -c 't-ie01' "$A")"
[[ "$(grep -c '' "$D")" == "$((before - 1))" ]] || fail "the two archives moved something other than one row each"
# the start lookup reads only file names with a known extension of 6 or more characters, and ticket ids; not other words
row 2026-07-01 t-id01 'the notes live in notes.txt and in a.sh and in plain words.' r >> "$D"
start_out "see notes.txt and a.sh now"; assert_eq 0 "$(cat "$rcfile")"; [[ "$out" != *"Related decisions"* ]] || fail "start looked up a token it should not extract: $out"
# --- sprint complete: one non-blocking line for a long row of the closing ticket ---
close_with() { # <title> <row length: 0 none | N>: a trivial-tier close; the output of sprint complete, its status in $rcfile
  local o id; o="$("$S" start "$1" 2>&1)"; id="$(awk '/Sprint started:/ { print $3 }' <<<"$o")"
  [[ "$id" =~ ^t-[0-9a-f]{4}$ ]] || fail "sprint start gave no ticket id for $1: $o"
  printf '# Summary\n| Item | Status |\n|---|---|\n| x | delivered |\n' > ".tickets/$id/summary.md"
  printf '# Acceptance\n## Criteria\n- [x] Done.\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| security-review | ran | no trust boundary touched |\n' > ".tickets/$id/acceptance.md"
  printf '# Plan\n## Sign-off\nTier: trivial | Risk: one-liner\n- [x] Plan approved \xe2\x80\x94 proceed to implementation\n## Approach\nNone needed.\n' > ".tickets/$id/plan.md"
  long() { head -c 700 /dev/zero | tr '\0' z; }
  case "${3:-std}" in
    std) [[ "$2" == 0 ]] || row 2026-11-08 "$id" "$(head -c "$2" /dev/zero | tr '\0' z)" 'r' >> "$D" ;;
    late) printf '| 2026-11-08 | an unrelated start, then `%s` in the middle of %s | r |\n' "$id" "$(long)" >> "$D" ;;   # the id is not the row's rule
    plain) printf '| 2026-11-08 | **%s: %s** | r |\n' "$id" "$(long)" >> "$D" ;;                                          # no backticks around the id
    four) for _ in 1 2 3 4; do row 2026-11-08 "$id" "$(long)" 'r' >> "$D"; done ;;
  esac
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m fixture
  set +e; local c; c="$("$S" complete 2>&1)"; printf '%s' "$?" > "$rcfile"; set -e; printf '%s\n' "$c"
}
out="$(close_with "long row" 700)"; assert_eq 0 "$(cat "$rcfile")"; assert_contains "$out" "closed"
assert_contains "$out" "DECISIONS.md: the row for t-"; assert_contains "$out" "characters; keep a row to its rule, its falsifier and the ticket id (about 400)"
out="$(close_with "short row" 100)"; assert_eq 0 "$(cat "$rcfile")"; [[ "$out" == *"closed"* && "$out" != *"keep a row to its rule"* ]] || fail "a short row printed the length line: $out"
out="$(close_with "no row" 0)"; assert_eq 0 "$(cat "$rcfile")"; [[ "$out" == *"closed"* && "$out" != *"keep a row to its rule"* ]] || fail "a close with no row printed the length line: $out"
out="$(close_with "late mention" 0 late)"; assert_eq 0 "$(cat "$rcfile")"; [[ "$out" == *"closed"* && "$out" != *"keep a row to its rule"* ]] || fail "a row that merely mentions the id printed the length line: $out"
out="$(close_with "plain id" 0 plain)"; assert_eq 0 "$(cat "$rcfile")"; [[ "$out" == *"closed"* && "$out" != *"keep a row to its rule"* ]] || fail "a row whose id has no backticks printed the length line: $out"
out="$(close_with "four rows" 0 four)"; assert_eq 0 "$(cat "$rcfile")"; assert_eq 3 "$(grep -c 'keep a row to its rule' <<<"$out")"   # at most 3 lines
chmod 000 "$D"; out="$(close_with "unreadable" 0)"; chmod 644 "$D"
assert_eq 0 "$(cat "$rcfile")"; [[ "$out" == *"closed"* && "$out" != *"keep a row to its rule"* && "$out" != *"can't open"* ]] || fail "an unreadable DECISIONS.md changed the close: $out"
git update-ref -d "$(git symbolic-ref HEAD)"

# --- size: a 500 KB file answers in under 2 seconds ---
{ printf '# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n'; for i in $(seq 1 400); do row 2026-01-01 "t-h$(printf '%03d' "$i")" "$(head -c 1200 /dev/zero | tr '\0' q) big-file-needle-$i.sh" 'r'; done; } > "$D"
[[ "$(wc -c < "$D")" -gt 480000 ]] || fail "the size fixture is too small"
t0=$SECONDS; rc "$S" decisions related big-file-needle-399.sh; t1=$SECONDS
assert_eq 1 "$(grep -c '^[0-9a-f]\{8\}  ' <<<"$out")"; [[ $((t1 - t0)) -lt 2 ]] || fail "related took $((t1 - t0)) s on a 500 KB file"

echo "sprint-decisions: ok (related, mark, archive with its refusals, the start lookup, the complete line, a 500 KB file; in a non-canon project)"
