#!/usr/bin/env bash
# tkt send-issue (t-a059): what it sends to GitHub, and every case it must refuse without touching ticket.md.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
stub="$(mktemp -d "${TMPDIR:-/tmp}/tkt-send-issue.XXXXXX")"
trap 'rm -rf "$project" "$stub"' EXIT
cd "$project"

# A stub gh that logs every call and plays a repo: STUB_VIS (PRIVATE or PUBLIC), STUB_FAIL=create fails issue create,
# STUB_FAIL=view fails repo view (signed out), STUB_FAIL=label fails label create, STUB_LABEL=empty lists no label
# (GitHub's label search lags a label created a second earlier). It saves the body it was given.
cat > "$stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "repo view")    [[ "${STUB_FAIL:-}" == view ]] && { echo "To get started with GitHub CLI, please run: gh auth login" >&2; exit 4; }; echo "${STUB_VIS:-PRIVATE}" ;;
  "label create") [[ "${STUB_FAIL:-}" == label ]] && { echo "HTTP 403" >&2; exit 1; }; exit 0 ;;
  "label list")   [[ "${STUB_LABEL:-}" == empty ]] || echo canon ;;
  "issue create") [[ "${STUB_FAIL:-}" == create ]] && { echo "HTTP 502: server error" >&2; exit 1; }
                  while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && cp "$2" "$STUB_BODY"; shift; done
                  echo "https://github.com/acme/app/issues/57" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$stub/gh"
export PATH="$stub:$PATH" STUB_LOG="$stub/log" STUB_BODY="$stub/body"
writes() { grep -cE '^(issue create|label create)' "$STUB_LOG" || true; }

git remote add origin https://github.com/acme/app.git
id="$("$TKT" create "Board burns a CPU core" -t task -p 1 -d "## Problem
The board uses a core while idle.")"
d=".tickets/$id"
printf '# Acceptance\n\n## Criteria\nThe checklist of behavior that must be true before the sprint can close.\n<!-- Add items -->\n\n- [ ] Idle CPU under 5%%\n  over 60 s\n\n## Test Plan\n- [ ] Measure before and after\n\n## QA\nEdge cases and sign-off.\n- [ ] Tested locally\n\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n\n## Results\nAll criteria met on the first run.\n' > "$d/acceptance.md"
printf '# Plan\n\n## Sign-off\n- [x] Plan approved\n\n## Approach\n1. Profile the idle board.\n2. Fix the hot loop.\n```\n<!-- kept: inside a fence -->\n## Files\n```\n<!-- dropped: outside a fence -->\n3. Measure again.\n\n## Files\n`server.py`\n\n## Decisions\n- none\n' > "$d/plan.md"
printf '# Research: x\n\n- The board polls every 8 s.\n' > "$d/research.md"
sig() { cksum < "$d/ticket.md"; }

# --dry-run: repo, visibility, title and body; no writing call.
: > "$STUB_LOG"
dry="$("$TKT" send-issue "$id" --dry-run)"
assert_contains "$dry" "repo: acme/app (PRIVATE)"
assert_contains "$dry" "title: $id: Board burns a CPU core"
assert_contains "$dry" "dry run: nothing was created"
[[ "$(writes)" == 0 ]] || fail "--dry-run made a writing gh call: $(cat "$STUB_LOG")"

# Send: exact calls, body in the ticket's sections and order, github: recorded only after success.
: > "$STUB_LOG"
out="$("$TKT" send-issue "$id")"
assert_contains "$out" "Sent $id as https://github.com/acme/app/issues/57"
assert_contains "$out" "type: Work on Issue#57"
grep -qx "label create canon --repo acme/app --color 6C5CF7 --description A canon ticket --force" "$STUB_LOG" || fail "label not created: $(cat "$STUB_LOG")"
grep -qx "issue create --repo acme/app --title $id: Board burns a CPU core --label canon --body-file .*" "$STUB_LOG" || fail "wrong issue create call: $(cat "$STUB_LOG")"
assert_grep "^github: acme/app#57$" "$d/ticket.md"
assert_grep "^runs: github$" "$d/ticket.md"                          # t-718b: out on GitHub, not just linked
# The issue has the ticket's tree as the board lists it: every section of ticket.md, acceptance.md and plan.md, then Research.
order="$(awk '/^```/ { fence = !fence; next } !fence && /^#{1,2} /' "$STUB_BODY" | tr '\n' '|')"
assert_eq "# Description|## Problem|# Acceptance|## Criteria|## Test Plan|## QA|## Wrapup Gates|## Results|# Plan|## Sign-off|## Approach|## Files|## Decisions|# Research|# Working on this|" "$order"
assert_grep '^| eval | ran | pass |$' "$STUB_BODY"                     # a table section keeps its rows
assert_grep '^All criteria met on the first run.$' "$STUB_BODY"     # and a prose section its text
assert_grep '^- \[ \] Tested locally$' "$STUB_BODY"
assert_grep '^- \[x\] Plan approved$' "$STUB_BODY"
assert_grep '^- \[ \] Idle CPU under 5%$' "$STUB_BODY"
assert_grep '^  over 60 s$' "$STUB_BODY"
assert_grep '^1. Profile the idle board.$' "$STUB_BODY"
# t-8543: a fenced block is kept as written: its comment and its "## " line stay, inside Approach, not a section of their own.
approach="$(awk '/^```/ { fence = !fence } !fence && /^## Approach$/ { f = 1; next } !fence && /^## Files$/ { f = 0 } f' "$STUB_BODY")"
assert_eq $'1. Profile the idle board.\n2. Fix the hot loop.\n```\n<!-- kept: inside a fence -->\n## Files\n```\n3. Measure again.' "$(printf '%s' "$approach" | awk 'NF { s = 1 } s' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
assert_grep '^- The board polls every 8 s.$' "$STUB_BODY"
assert_grep "^<!-- canon:ticket $id -->\$" "$STUB_BODY"
# t-67c5: "Working on this" is a numbered list in work order; each line is asserted whole (t-b2e5 plan mode, t-1cf4 approval and branch).
grep -qxF "1. Run \`sprint import-issue <this issue number>\` first: it rebuilds .tickets/$id/ from the sections above and starts the" "$STUB_BODY" \
  || fail "the issue lacks the import first line (t-67c5)"
grep -qxF "   sprint. Edit no file before it has run. If gh cannot read this issue, save its text to a file and add \`--body-file <file>\`." "$STUB_BODY" \
  || fail "the issue lacks the import: edit nothing before it line (t-67c5)"
grep -qxF "2. Plan with canon's own approval, not plan mode: plan mode has been observed to reach the close gates and stop them." "$STUB_BODY" \
  || fail "the issue lacks the plan mode warning line (t-67c5)"
grep -qxF "   Write the plan into .tickets/$id/plan.md, then stop and wait for the user's approval before editing any file but the" "$STUB_BODY" \
  || fail "the issue lacks the wait for approval line (t-67c5)"
grep -qxF "   ticket's docs. If Acceptance or Plan above read \"(none yet)\", stop and tell the user; do not draft them yourself." "$STUB_BODY" \
  || fail "the issue lacks the stop on (none yet) line (t-67c5)"
grep -qxF "3. Work on a new branch, never main: push that branch and open a PR with \`Fixes #<this issue number>\`. Do not push to main or force-push anything." "$STUB_BODY" \
  || fail "the issue lacks the branch, never main line (t-67c5)"
grep -qxF "4. Build it and run the tests; tick each acceptance item only when it is true." "$STUB_BODY" \
  || fail "the issue lacks the build and test line (t-67c5)"
grep -qxF "5. Run \`sprint complete\`: a fresh reviewer and a fresh evaluator are dispatched, and neither is skipped or written by hand." "$STUB_BODY" \
  || fail "the issue lacks the gates line (t-67c5)"
grep -qxF "6. Run \`tkt export $id\` and push nothing else for it: export prints where the ticket went." "$STUB_BODY" \
  || fail "the issue lacks the export line (t-67c5)"
grep -qxF "If a step cannot be done, say so in the PR description; do not skip it silently." "$STUB_BODY" \
  || fail "the issue lacks the closing line line (t-67c5)"
# t-1465: GitHub hides a bare <placeholder> as an HTML tag, so in "Working on this" each sits inside a code span.
work="$(awk '/^# Working on this$/ { f = 1; next } /^<!-- canon:ticket / { f = 0 } f' "$STUB_BODY")"
assert_contains "$work" '`Fixes #<this issue number>`'
bare="$(printf '%s\n' "$work" | sed 's/`[^`]*`//g' | grep -o '<[a-z][^>]*>' || true)"
[[ -z "$bare" ]] || fail "placeholders outside a code span in Working on this: $bare"
grep -q 'The checklist of behavior\|Edge cases and sign-off\|Add items' "$STUB_BODY" && fail "template prompts or comments leaked into the issue"
[[ "$(grep -c '^## Problem$' "$STUB_BODY")" == 1 ]] || fail "the ticket's own Problem heading was doubled"

# Already sent: refused, ticket unchanged, no gh call.
: > "$STUB_LOG"; before="$(sig)"
rc=0; again="$("$TKT" send-issue "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a second send should exit 1, got $rc"
assert_contains "$again" "already sent: acme/app#57"
[[ "$(writes)" == 0 && "$(sig)" == "$before" ]] || fail "a second send called gh or changed the ticket"

# t-718b: linked only (sync-issues, import-issue, or a take-back that left the issue open): no second issue for it.
awk '!/^runs: /' "$d/ticket.md" > "$d/t" && mv "$d/t" "$d/ticket.md"
: > "$STUB_LOG"; before="$(sig)"
rc=0; again="$("$TKT" send-issue "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "sending a linked ticket should exit 1, got $rc"
assert_contains "$again" "already linked to acme/app#57"
[[ "$(writes)" == 0 && "$(sig)" == "$before" ]] || fail "sending a linked ticket called gh or changed it"

# t-c131: a heading with text after its name is its own section, listed once under its full heading with its lines.
id4="$("$TKT" create "Suffixed heading" -t task -p 3)"
printf '# Plan\n\n## Approach (draft)\n1. Sketch it.\n2. Refine it.\n\n## Files\n`a.sh`\n' > ".tickets/$id4/plan.md"
printf '# Acceptance\n\n## Criteria (draft)\n- [ ] Still counts as criteria\n' > ".tickets/$id4/acceptance.md"
"$TKT" send-issue "$id4" >/dev/null 2> "$stub/suffixed.err"
grep -q 'no acceptance criteria' "$stub/suffixed.err" && fail "a '## Criteria (draft)' section was not read as the Criteria section"
assert_eq "## Approach (draft)|## Files|" "$(awk '/^# Plan$/ { f = 1; next } /^# / { f = 0 } f && /^## /' "$STUB_BODY" | tr '\n' '|')"
assert_eq $'1. Sketch it.\n2. Refine it.' "$(awk '/^## Approach \(draft\)$/ { f = 1; next } /^## / { f = 0 } f && NF' "$STUB_BODY")"

# t-c131: ticket files with CRLF line endings list each section once, under its name with no CR, with its lines.
id5="$("$TKT" create "Crlf ticket" -t task -p 3)"
printf '# Acceptance\n\n## Criteria\n- [ ] Works on Windows\n\n## QA\n- [ ] Tested locally\n' | sed 's/$/\r/' > ".tickets/$id5/acceptance.md"
printf '# Plan\n\n## Approach\n1. Handle CRLF.\n\n## Files\n`b.sh`\n' | sed 's/$/\r/' > ".tickets/$id5/plan.md"
"$TKT" send-issue "$id5" >/dev/null
assert_eq "## Criteria|## QA|" "$(awk '/^# Acceptance$/ { f = 1; next } /^# / { f = 0 } f && /^## /' "$STUB_BODY" | tr '\n' '|')"
assert_eq "## Approach|## Files|" "$(awk '/^# Plan$/ { f = 1; next } /^# / { f = 0 } f && /^## /' "$STUB_BODY" | tr '\n' '|')"
assert_grep '^- \[ \] Works on Windows$' "$STUB_BODY"
assert_grep '^1. Handle CRLF.$' "$STUB_BODY"
[[ "$(grep -c $'\r' "$STUB_BODY" || true)" == 0 ]] || fail "a CR reached the issue body"

# Public repo: refused without --public (ticket unchanged), sent with it.
id2="$("$TKT" create "Public one" -t bug -p 2)"
export STUB_VIS=PUBLIC; : > "$STUB_LOG"; before="$(cksum < ".tickets/$id2/ticket.md")"
rc=0; pub="$("$TKT" send-issue "$id2" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a public repo should be refused, got $rc"
assert_contains "$pub" "acme/app is PUBLIC"
[[ "$(writes)" == 0 && "$(cksum < ".tickets/$id2/ticket.md")" == "$before" ]] || fail "a refused public send called gh or changed the ticket"
# A dry run previews it without --public (nothing is created; the board asks from the PUBLIC in its repo: line).
dry="$("$TKT" send-issue "$id2" --dry-run)"; assert_contains "$dry" "repo: acme/app (PUBLIC)"
[[ "$(writes)" == 0 && "$(cksum < ".tickets/$id2/ticket.md")" == "$before" ]] || fail "a public dry run called gh or changed the ticket"
"$TKT" send-issue "$id2" --public >/dev/null
assert_grep "^github: acme/app#57$" ".tickets/$id2/ticket.md"
unset STUB_VIS

# Missing acceptance, plan and research: "(none yet)", and a warning.
id3="$("$TKT" create "Bare" -t task -p 3)"
"$TKT" send-issue "$id3" --dry-run > "$stub/bare" 2> "$stub/bare.err"
[[ "$(grep -c '^(none yet)$' "$stub/bare")" == 3 ]] || fail "expected Acceptance, Plan and Research to read (none yet): $(cat "$stub/bare")"
assert_grep "no acceptance criteria" "$stub/bare.err"

# gh fails on create, or is signed out: exit 1, the error shown, ticket byte-identical.
for mode in create view; do
  export STUB_FAIL=$mode; before="$(cksum < ".tickets/$id3/ticket.md")"
  rc=0; err="$("$TKT" send-issue "$id3" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "gh failing on $mode should exit 1, got $rc"
  [[ "$mode" == create ]] && assert_contains "$err" "HTTP 502" || assert_contains "$err" "gh auth login"
  [[ "$(cksum < ".tickets/$id3/ticket.md")" == "$before" ]] || fail "ticket changed although gh failed on $mode"
done
unset STUB_FAIL

# t-1465: the label. A successful create is enough, though the search does not list the new label yet; a failed create
# with no label listed still sends the issue, without --label (an empty label list must not break bash 3.2's set -u).
id4="$("$TKT" create "Label lag" -t task -p 3)"
export STUB_LABEL=empty; : > "$STUB_LOG"
"$TKT" send-issue "$id4" >/dev/null 2>"$stub/lag.err" || fail "send with a lagging label search failed: $(cat "$stub/lag.err")"
grep -q "^issue create .* --label canon --body-file " "$STUB_LOG" || fail "a created label was not used: $(cat "$STUB_LOG")"
grep -q "could not create" "$stub/lag.err" && fail "warned although the label was created"
id5="$("$TKT" create "No label" -t task -p 3)"
export STUB_FAIL=label; : > "$STUB_LOG"
"$TKT" send-issue "$id5" >/dev/null 2>"$stub/nolabel.err" || fail "send without a label failed: $(cat "$stub/nolabel.err")"
grep -q "^issue create " "$STUB_LOG" || fail "no issue was created without the label: $(cat "$STUB_LOG")"
grep -q "^issue create .*--label" "$STUB_LOG" && fail "--label passed although the label could not be made: $(cat "$STUB_LOG")"
assert_grep "could not create the canon label; sending without it" "$stub/nolabel.err"
assert_grep "^github: acme/app#57$" ".tickets/$id5/ticket.md"
unset STUB_FAIL STUB_LABEL

# No gh on PATH: refused with the install hint, ticket byte-identical. The real gh is hidden by a PATH of links to
# everything else in the dirs that hold it.
nogh="$stub/nogh"; mkdir "$nogh"; path_nogh=""
IFS=: read -ra dirs <<<"$PATH"
for dir in "${dirs[@]}"; do
  [[ "$dir" == "$stub" ]] && continue
  if [[ -x "$dir/gh" ]]; then
    for f in "$dir"/*; do [[ "${f##*/}" == gh || -e "$nogh/${f##*/}" ]] || ln -s "$f" "$nogh/${f##*/}"; done
  else path_nogh="$path_nogh:$dir"; fi
done
before="$(cksum < ".tickets/$id3/ticket.md")"
rc=0; ng="$(PATH="$nogh$path_nogh" "$TKT" send-issue "$id3" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "no gh should exit 1, got $rc: $ng"
assert_contains "$ng" "send-issue: needs the GitHub CLI"
[[ "$(cksum < ".tickets/$id3/ticket.md")" == "$before" ]] || fail "ticket changed although gh is missing"
PATH="$nogh$path_nogh" command -v gh >/dev/null && fail "the test PATH still finds gh"

# Origins: ssh forms parse; anything not on GitHub is refused before any gh call.
for u in git@github.com:acme/app.git ssh://git@github.com/acme/app; do
  git remote set-url origin "$u"
  assert_contains "$("$TKT" send-issue "$id3" --dry-run 2>/dev/null)" "repo: acme/app (PRIVATE)"
done
git remote set-url origin https://gitlab.com/acme/app.git; : > "$STUB_LOG"
rc=0; gl="$("$TKT" send-issue "$id3" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a GitLab origin should be refused, got $rc"
assert_contains "$gl" "origin is not a GitHub repo"
[[ ! -s "$STUB_LOG" ]] || fail "gh was called for a non-GitHub origin"

echo "tkt-send-issue: ok"
