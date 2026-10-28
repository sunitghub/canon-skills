#!/usr/bin/env bash
# tkt send-issue (t-a059): what it sends to GitHub, and every case it must refuse without touching ticket.md.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
stub="$(mktemp -d "${TMPDIR:-/tmp}/tkt-send-issue.XXXXXX")"
use_fresh_board "$stub/bin"   # t-4c09: the audit event goes through the board binary
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
The board uses a core while idle.

## Outcome
<!-- What is true when this is done? -->")"
d=".tickets/$id"
printf '# Acceptance\n\n## Criteria\nThe checklist of behavior that must be true before the sprint can close.\n<!-- Add items -->\n\n- [ ] Idle CPU under 5%%\n  over 60 s\n\n## Test Plan\n- [ ] Measure before and after\n\n## QA\nEdge cases and sign-off.\n- [ ] Tested locally\n\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n\n## Results\nAll criteria met on the first run.\n' > "$d/acceptance.md"
printf '# Plan\n\n## Sign-off\n- [x] Plan approved\n\n## Approach\n1. Profile the idle board.\n2. Fix the hot loop.\n```\n<!-- kept: inside a fence -->\n## Files\n```\n<!-- dropped: outside a fence -->\n3. Measure again.\n\n## Files\n`server.py`\n\n## Decisions\n- none\n' > "$d/plan.md"
printf '# Research: x\n\n- The board polls every 8 s.\n' > "$d/research.md"
sig() { cksum < "$d/ticket.md"; }

# --dry-run: repo, visibility, title and body; no writing call.
: > "$STUB_LOG"
dry="$("$TKT" send-issue "$id" --dry-run 2>"$stub/dry.err")"
assert_contains "$dry" "repo: acme/app (PRIVATE)"
[[ ! -s "$stub/dry.err" ]] || fail "a ticket with criteria and an approach warned: $(cat "$stub/dry.err")"
assert_contains "$dry" "title: $id: Board burns a CPU core"
assert_contains "$dry" "dry run: nothing was created"
[[ "$(writes)" == 0 ]] || fail "--dry-run made a writing gh call: $(cat "$STUB_LOG")"
[[ ! -e ".tickets/$id/github.md" ]] || fail "--dry-run wrote the GitHub trail (t-1dec)"

# Send: exact calls, body in the ticket's sections and order, github: recorded only after success.
: > "$STUB_LOG"
out="$("$TKT" send-issue "$id")"
assert_contains "$out" "Sent $id as https://github.com/acme/app/issues/57"
# t-093a: the printed start line names the issue and the ticket, points at "Working on this" and keeps the branch rule; the
# board copies this line, so it is the prompt's one owner.
printed="Work on Issue#57 for ticket $id. Read its section \"Working on this\" thoroughly before starting and follow it step by step. Work on a new branch, never main."
printf '%s\n' "$out" | grep -xF "$printed" >/dev/null || fail "send-issue did not print the start line: $out"
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
# t-093a: a blank Acceptance or Plan is drafted the way sprint start does, then the session waits for approval.
grep -qxF "   If Acceptance or Plan above read \"(none yet)\", draft them the way \`sprint start\` does (.tickets/$id/acceptance.md and" "$STUB_BODY" \
  || fail "the issue lacks the draft on (none yet) line (t-093a)"
grep -qxF "   plan.md). Then stop and wait for the user's approval of the plan before editing anything else." "$STUB_BODY" \
  || fail "the issue lacks the wait for approval line (t-093a)"
grep -qxF "3. Work on a new branch, never main: push that branch and open a PR with \`Fixes #<this issue number>\`. Do not push to main or force-push anything." "$STUB_BODY" \
  || fail "the issue lacks the branch, never main line (t-67c5)"
grep -qxF "4. Build it and run the tests; tick each acceptance item only when it is true." "$STUB_BODY" \
  || fail "the issue lacks the build and test line (t-67c5)"
grep -qxF "5. Run \`sprint complete\`: a fresh reviewer and a fresh evaluator are dispatched, and neither is skipped or written by hand." "$STUB_BODY" \
  || fail "the issue lacks the gates line (t-67c5)"
grep -qxF "6. Run \`tkt export $id\` and push nothing else for it: export prints where the ticket went." "$STUB_BODY" \
  || fail "the issue lacks the export line (t-67c5)"
grep -qxF "   If \`sprint complete\` could not pass, still run \`tkt export $id\`, and say in the PR which step failed and why." "$STUB_BODY" \
  || fail "the issue lacks the export-anyway line (t-d0a5)"
# t-093a: the list ends by telling the session to stop, so it does not offer to watch the PR.
grep -qxF "7. Then stop. Do not merge the PR, watch it, or act on CI results or review comments: the merge happens on the user's machine" "$STUB_BODY" \
  || fail "the issue lacks the stop step (t-093a)"
# t-41ff: the commands run as written: the real id, and --pr with the N the session is told to fill in.
grep -qxF "   (\`tkt import-results $id --pr <N>\`, then \`tkt merge-pr $id\`, N being the PR number). Reply with both commands, N filled in," "$STUB_BODY" \
  || fail "the issue lacks the stop step's second line with runnable commands (t-093a, t-41ff)"
grep -qxF "   and say you are done." "$STUB_BODY" || fail "the issue lacks the stop step's last line (t-41ff)"
grep -qxF "If a step cannot be done, say so in the PR description; do not skip it silently." "$STUB_BODY" \
  || fail "the issue lacks the closing line line (t-67c5)"
# t-1465: GitHub hides a bare <placeholder> as an HTML tag, so in "Working on this" each sits inside a code span.
work="$(awk '/^# Working on this$/ { f = 1; next } /^<!-- canon:ticket / { f = 0 } f' "$STUB_BODY")"
assert_contains "$work" '`Fixes #<this issue number>`'
bare="$(printf '%s\n' "$work" | sed 's/`[^`]*`//g' | grep -o '<[a-z][^>]*>' || true)"
[[ -z "$bare" ]] || fail "placeholders outside a code span in Working on this: $bare"
grep -q 'The checklist of behavior\|Edge cases and sign-off\|Add items' "$STUB_BODY" && fail "template prompts or comments leaked into the issue"
[[ "$(grep -c '^## Problem$' "$STUB_BODY")" == 1 ]] || fail "the ticket's own Problem heading was doubled"
grep -q '^## Outcome$' "$STUB_BODY" && fail "a Description section holding only a comment reached the issue (t-093a)"

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

# t-093a: the Description keeps text before the first heading, a filled section's lines in order, and a section whose
# only text is a fenced block (a "## " line and a comment inside a fence are content); a comment-only section goes.
id6="$("$TKT" create "Fenced description" -t task -p 3 -d "Seen on the Mac.

## Problem
Line one.
Line two.

## Repro
\`\`\`
## not a heading
<!-- a comment in the log -->
\`\`\`

## Constraints
<!-- Limits the solution must respect. -->")"
desc="$("$TKT" send-issue "$id6" --dry-run 2>/dev/null | awk '/^# Description$/ { f = 1; next } /^# Acceptance$/ { f = 0 } f')"
assert_eq $'Seen on the Mac.\n\n## Problem\nLine one.\nLine two.\n\n## Repro\n```\n## not a heading\n<!-- a comment in the log -->\n```' "$(printf '%s' "$desc" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

# Public repo: refused without --public (ticket unchanged), sent with it.
id2="$("$TKT" create "Public one" -t bug -p 2)"
export STUB_VIS=PUBLIC; : > "$STUB_LOG"; before="$(cksum < ".tickets/$id2/ticket.md")"
rc=0; pub="$("$TKT" send-issue "$id2" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a public repo should be refused, got $rc"
assert_contains "$pub" "acme/app is PUBLIC"
[[ "$(writes)" == 0 && "$(cksum < ".tickets/$id2/ticket.md")" == "$before" ]] || fail "a refused public send called gh or changed the ticket"
[[ ! -e ".tickets/$id2/github.md" ]] || fail "a refused send wrote the GitHub trail (t-1dec)"
# A dry run previews it without --public (nothing is created; the board asks from the PUBLIC in its repo: line).
dry="$("$TKT" send-issue "$id2" --dry-run)"; assert_contains "$dry" "repo: acme/app (PUBLIC)"
[[ "$(writes)" == 0 && "$(cksum < ".tickets/$id2/ticket.md")" == "$before" ]] || fail "a public dry run called gh or changed the ticket"
"$TKT" send-issue "$id2" --public >/dev/null
assert_grep '^## .* — sent$' ".tickets/$id2/github.md"   # t-1dec: only a real send starts the trail
assert_grep "^github: acme/app#57$" ".tickets/$id2/ticket.md"
unset STUB_VIS

# Missing acceptance, plan and research: "(none yet)", and a warning.
id3="$("$TKT" create "Bare" -t task -p 3)"
"$TKT" send-issue "$id3" --dry-run > "$stub/bare" 2> "$stub/bare.err"
# t-093a: the template body is all comment-only sections, so the Description reads (none yet) too; both warnings say the
# session drafts and waits (the issue's step 2).
[[ "$(grep -c '^(none yet)$' "$stub/bare")" == 4 ]] || fail "expected Description, Acceptance, Plan and Research to read (none yet): $(cat "$stub/bare")"
assert_grep "has no acceptance criteria: the session will draft them and wait for your approval" "$stub/bare.err"
assert_grep "has no plan .plan.md ## Approach is empty.: the session will draft it and wait for your approval" "$stub/bare.err"
# Numbered criteria count; an Approach with text silences the plan warning.
printf '# Acceptance\n\n## Criteria\n1. The board idles under 5%%\n' > ".tickets/$id3/acceptance.md"
printf '# Plan\n\n## Approach\nProfile, then fix.\n' > ".tickets/$id3/plan.md"
"$TKT" send-issue "$id3" --dry-run >/dev/null 2> "$stub/num.err"
[[ ! -s "$stub/num.err" ]] || fail "numbered criteria or a written approach still warned: $(cat "$stub/num.err")"
rm ".tickets/$id3/acceptance.md" ".tickets/$id3/plan.md"

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

# t-0da2: --launch starts the cloud session. A stub claude logs its cwd and arguments, plays STUB_CLAUDE=ok|fail, and refuses
# without a terminal on stdin and stdout exactly as the real `claude --cloud` does (a piped run failed for a maintainer).
cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then echo "Options:"; [[ -n "${STUB_NOCLOUD:-}" ]] || echo "  --cloud [description|session_id|url]  Create a cloud session"; exit 0; fi
[[ -t 0 && -t 1 ]] || { echo "claude --cloud needs an interactive terminal" >&2; exit 1; }
{ printf 'cwd=%s\n' "$(pwd -P)"; printf 'arg=%s\n' "$@"; } >> "$STUB_CLAUDE_LOG"
case "${STUB_CLAUDE:-ok}" in
  fail) echo "Error: not signed in" >&2; exit 1 ;;
  *)    echo "Created cloud session: Work on Issue"; echo "View: https://claude.ai/code/session_abc?from=cli&m=0" ;;
esac
EOF
chmod +x "$stub/claude"
export STUB_CLAUDE_LOG="$stub/claude.log"
git remote set-url origin https://github.com/acme/app.git   # the cases above end on a GitLab origin
fresh() { "$TKT" create "Launch case $1" -t task -p 2 -d "x"; }
project_real="$(pwd -P)"

# Without --launch the output gains one line, the same prompt as a single-quoted command a terminal can run.
idf="$(fresh plain)"; : > "$STUB_LOG"; : > "$STUB_CLAUDE_LOG"
out="$("$TKT" send-issue "$idf")"
cmdline="$(printf '%s\n' "$out" | grep '^From a terminal: claude --cloud ' || true)"
[[ -n "$cmdline" ]] || fail "no 'From a terminal:' line: $out"
want="Work on Issue#57 for ticket $idf. Read its section \"Working on this\" thoroughly before starting and follow it step by step. Work on a new branch, never main."
got="$(eval "set -- ${cmdline#From a terminal: claude --cloud }"; printf '%s' "$1")"
assert_eq "$want" "$got"
[[ ! -s "$STUB_CLAUDE_LOG" ]] || fail "claude ran without --launch"

# No claude on PATH at all (the same PATH-without-one-command trick as the gh case below), the usage line, and the help text.
noclaude="$stub/noclaude"; mkdir "$noclaude"; path_nocl=""
IFS=: read -ra cdirs <<<"$PATH"
for dir in "${cdirs[@]}"; do
  [[ "$dir" == "$stub" ]] && continue
  if [[ -x "$dir/claude" ]]; then
    for f in "$dir"/*; do [[ "${f##*/}" == claude || -e "$noclaude/${f##*/}" ]] || ln -s "$f" "$noclaude/${f##*/}"; done
  else path_nocl="$path_nocl:$dir"; fi
done
idc="$(fresh noclaude)"
rc=0; r="$(PATH="$noclaude$path_nocl" "$TKT" send-issue "$idc" --launch --yes 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "no claude should exit 1, got $rc: $r"; assert_contains "$r" "needs the Claude CLI with --cloud"
rc=0; r="$("$TKT" send-issue 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "send-issue without an id should exit 1, got $rc"; assert_contains "$r" "Usage: tkt send-issue <id> [--dry-run] [--public] [--allow-unpushed] [--launch [--yes]]"
h="$("$TKT" --help 2>&1)"
assert_contains "$h" "send-issue <id> [--dry-run] [--public] [--allow-unpushed] [--launch [--yes]]"; assert_contains "$h" "in a real terminal only"

# Refusals come before anything is created: a claude without --cloud, no terminal (with or without --yes), --yes alone, --launch with --dry-run.
idl="$(fresh refuse)"; : > "$STUB_LOG"; before="$(cksum < ".tickets/$idl/ticket.md")"
rc=0; r="$(STUB_NOCLOUD=1 "$TKT" send-issue "$idl" --launch --yes 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "claude without --cloud should exit 1, got $rc"; assert_contains "$r" "needs the Claude CLI with --cloud"
for extra in "" "--yes"; do
  rc=0; r="$("$TKT" send-issue "$idl" --launch $extra </dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "--launch $extra without a terminal should exit 1, got $rc"; assert_contains "$r" "needs an interactive terminal"
done
rc=0; r="$("$TKT" send-issue "$idl" --yes 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "--yes alone should exit 1, got $rc"; assert_contains "$r" "--yes only goes with --launch"
rc=0; r="$("$TKT" send-issue "$idl" --launch --dry-run 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "--launch --dry-run should exit 1, got $rc"
assert_contains "$r" "cannot go together"
[[ "$(writes)" == 0 ]] || fail "a refused --launch made a writing gh call: $(cat "$STUB_LOG")"
[[ "$(cksum < ".tickets/$idl/ticket.md")" == "$before" ]] || fail "a refused --launch changed the ticket"
[[ ! -s "$STUB_CLAUDE_LOG" ]] || fail "a refused --launch ran claude"

# The terminal cases need a pty: python3 runs tkt on one, answers the [y/N] question if there is one, and prints what it saw.
if ! command -v python3 >/dev/null 2>&1; then
  echo "tkt-send-issue: skipped the --launch cases that need a terminal: no python3"
else
  # pty.py runs tkt send-issue --launch on a pty. mode: flag (adds --yes) or the answer typed at [y/N]: n, y, yes, eof (Ctrl-D).
  # PTY_HALF=stdin gives a terminal on stdin only, stdout a pipe; PTY_HALF=stdout the reverse; PTY_CWD sets the directory.
  cat > "$stub/pty.py" <<'PYEOF'
import os, pty, subprocess, sys
tkt, tid, mode = sys.argv[1:4]
half, cwd = os.environ.get("PTY_HALF", ""), os.environ.get("PTY_CWD") or None
args = [tkt, "send-issue", tid, "--launch"] + (["--yes"] if mode == "flag" else [])
if half:
    m, s = pty.openpty()
    if half == "stdin":
        p = subprocess.Popen(args, stdin=s, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=cwd)
        out = p.communicate()[0]
    else:
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=s, stderr=s, cwd=cwd)
        os.close(s)
        out = b""
        while True:
            try: d = os.read(m, 4096)
            except OSError: break
            if not d: break
            out += d
        p.wait()
    sys.stdout.write(out.decode(errors="replace")); sys.exit(p.returncode)
pid, fd = pty.fork()
if pid == 0:
    if cwd: os.chdir(cwd)
    os.execv(tkt, args)
reply = {"n": b"n\n", "y": b"y\n", "yes": b"yes\n", "eof": b"\x04"}.get(mode)
buf, sent = b"", False
while True:
    try: d = os.read(fd, 4096)
    except OSError: break
    if not d: break
    buf += d
    if reply and not sent and b"[y/N]" in buf:
        os.write(fd, reply); sent = True
_, st = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(st))
PYEOF
  ptyrun() { python3 -I "$stub/pty.py" "$TKT" "$1" "${2:-flag}"; }

  # --yes: the issue as today, then claude --cloud <start line> from the project root on the terminal, and the launch in the trail.
  idy="$(fresh yes)"; : > "$STUB_LOG"; : > "$STUB_CLAUDE_LOG"
  out="$(ptyrun "$idy" flag)" || fail "--launch --yes on a terminal failed: $out"
  assert_contains "$out" "Sent $idy as https://github.com/acme/app/issues/57"
  assert_contains "$out" "View: https://claude.ai/code/session_abc"        # claude's own output reaches the terminal
  assert_grep "^cwd=$project_real$" "$STUB_CLAUDE_LOG"
  assert_grep "^arg=--cloud$" "$STUB_CLAUDE_LOG"
  assert_grep "^arg=Work on Issue#57 for ticket $idy\. Read its section \"Working on this\" thoroughly" "$STUB_CLAUDE_LOG"
  [[ "$(grep -c '^arg=' "$STUB_CLAUDE_LOG")" == 2 ]] || fail "the prompt was not one argument: $(cat "$STUB_CLAUDE_LOG")"
  assert_grep "— launched$" ".tickets/$idy/github.md"
  assert_grep "^command: claude --cloud '" ".tickets/$idy/github.md"
  assert_grep "^github: acme/app#57$" ".tickets/$idy/ticket.md"

  # t-0aa7: --launch on a ticket that was already sent starts a session on its existing issue and creates nothing (the Sent panel's
  # To Claude Cloud types exactly this line); without --launch the ticket is still refused as already sent.
  : > "$STUB_LOG"; : > "$STUB_CLAUDE_LOG"; before="$(cksum < ".tickets/$idy/ticket.md")"
  out="$(ptyrun "$idy" flag)" || fail "--launch --yes on an already-sent ticket failed: $out"
  [[ "$(writes)" == 0 ]] || fail "launching an already-sent ticket made a writing gh call: $(cat "$STUB_LOG")"
  [[ "$(cksum < ".tickets/$idy/ticket.md")" == "$before" ]] || fail "launching an already-sent ticket changed the ticket"
  assert_grep "^arg=Work on Issue#57 for ticket $idy\. Read its section" "$STUB_CLAUDE_LOG"
  [[ "$(grep -c '— launched$' ".tickets/$idy/github.md")" == 2 ]] || fail "the second launch was not noted in the trail"
  r="$("$TKT" send-issue "$idy" 2>&1)" && fail "a plain send-issue of a sent ticket should still be refused"
  assert_contains "$r" "was already sent"
  out="$(ptyrun "$idy" n)" || fail "declining the question exited nonzero: $out"
  assert_contains "$out" "no session started"

  # claude fails after the issue exists: the issue stays recorded, the manual command is printed, exit 1, no launched entry.
  idm="$(fresh fail)"; : > "$STUB_LOG"
  rc=0; r="$(STUB_CLAUDE=fail ptyrun "$idm" flag)" || rc=$?
  [[ "$rc" == 1 ]] || fail "a failing claude should exit 1, got $rc: $r"
  assert_contains "$r" "was sent, but claude --cloud did not start a session"
  assert_contains "$r" "Start it yourself: claude --cloud '"
  assert_grep "^github: acme/app#57$" ".tickets/$idm/ticket.md"
  ! grep -q "launched" ".tickets/$idm/github.md" || fail "a failed launch wrote a launched entry"

  # A branch without an upstream, or ahead of it, warns and pushes nothing.
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base; git -c user.name=t -c user.email=t@t commit -q --allow-empty -m next
  br="$(git rev-parse --abbrev-ref HEAD)"
  r="$(ptyrun "$(fresh noup)" flag)"
  assert_contains "$r" "branch $br has no upstream"
  git config "branch.$br.remote" origin; git config "branch.$br.merge" "refs/heads/$br"; git update-ref "refs/remotes/origin/$br" HEAD~1
  # t-ced8: a commit on no branch of origin is invisible to the cloud session, so the send is REFUSED (it only warned before), the ticket and
  # GitHub are untouched, and --allow-unpushed sends it anyway with a warning.
  ida="$(fresh ahead)"; : > "$STUB_LOG"
  rc=0; r="$(ptyrun "$ida" flag)" || rc=$?
  [[ "$rc" == 1 ]] || fail "unpushed commits must refuse the send, got $rc: $r"
  assert_contains "$r" "1 commit(s) in "; assert_contains "$r" "are on no branch of origin"; assert_contains "$r" "tkt send-issue $ida --allow-unpushed"
  [[ "$(writes)" == 0 ]] || fail "a refused send made a writing gh call: $(cat "$STUB_LOG")"
  assert_grep "^status: open$" ".tickets/$ida/ticket.md"; ! grep -q "^github:" ".tickets/$ida/ticket.md" || fail "a refused send linked the ticket"
  r="$("$TKT" send-issue "$ida" --dry-run 2>&1)" && fail "--dry-run must refuse unpushed commits too (the board's preview runs it)"
  assert_contains "$r" "are on no branch of origin"
  [[ -z "$(event_line github.sent "$ida")" ]] || fail "a refused send wrote github.sent"   # t-4c09
  r="$("$TKT" send-issue "$ida" --allow-unpushed 2>&1)" || fail "--allow-unpushed did not send: $r"
  assert_contains "$r" "warning: 1 commit(s) are on no branch of origin"; assert_contains "$r" "Sent $ida as"
  gs="$(event_line github.sent "$ida")"; assert_contains "$gs" '"source":"tkt"'; assert_contains "$gs" '"issue":"57"'; [[ "$gs" != *'"actor"'* ]] || fail "a CLI send claimed an actor: $gs"
  [[ "$(git rev-parse "refs/remotes/origin/$br")" == "$(git rev-parse HEAD~1)" ]] || fail "--launch moved the upstream ref"
  git update-ref "refs/remotes/origin/$br" HEAD   # level with the upstream, the usual case: no warning, and under set -e no stop
  rc=0; r="$(ptyrun "$(fresh level)" flag)" || rc=$?
  [[ "$rc" == 0 ]] || fail "--launch on a branch level with its upstream failed ($rc): $r"
  [[ "$r" != *"warning: branch"* ]] || fail "a branch level with its upstream warned: $r"

  # t-ced8: a ticket planned here is in_progress. It can be sent when no session works on it, and it joins the sent state (open +
  # runs: github, ACTIVE cleared); a live session, a closed ticket and a failed post each leave it exactly as it was.
  cat > "$stub/canon" <<'CEOF'
#!/usr/bin/env bash
[[ "${STUB_CANON:-}" == fail ]] && exit 1
[[ "$1 $2" == "sessions --json" ]] && echo "${STUB_SESSIONS:-[]}"
CEOF
  chmod +x "$stub/canon"
  idp="$(fresh planned)"; "$TKT" start "$idp" >/dev/null; : > "$STUB_LOG"
  assert_grep "^status: in_progress$" ".tickets/$idp/ticket.md"; [[ "$(cat .tickets/ACTIVE)" == "$idp" ]] || fail "start did not mark ACTIVE"
  rc=0; r="$(STUB_SESSIONS="[{\"session\":\"s1\",\"ticket\":\"$idp\"}]" "$TKT" send-issue "$idp" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "a ticket with a live session must be refused, got $rc: $r"; assert_contains "$r" "has a live agent session"
  [[ "$(writes)" == 0 ]] || fail "a refused send made a writing gh call"
  assert_grep "^status: in_progress$" ".tickets/$idp/ticket.md"; [[ "$(cat .tickets/ACTIVE)" == "$idp" ]] || fail "a refused send cleared ACTIVE"
  rc=0; r="$(STUB_FAIL=create "$TKT" send-issue "$idp" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "a failed post should exit 1, got $rc"
  assert_grep "^status: in_progress$" ".tickets/$idp/ticket.md"; ! grep -q "^github:" ".tickets/$idp/ticket.md" || fail "a failed post linked the ticket"
  [[ "$(cat .tickets/ACTIVE)" == "$idp" ]] || fail "a failed post cleared ACTIVE"
  r="$("$TKT" send-issue "$idp" 2>&1)" || fail "an in-progress ticket with no live session was not sent: $r"
  assert_contains "$r" "Sent $idp as"
  assert_grep "^status: open$" ".tickets/$idp/ticket.md"; assert_grep "^runs: github$" ".tickets/$idp/ticket.md"; assert_grep "^github: acme/app#57$" ".tickets/$idp/ticket.md"
  [[ ! -s .tickets/ACTIVE ]] || fail "ACTIVE still names a ticket that went to the cloud: $(cat .tickets/ACTIVE)"
  # no answer from canon (not installed, daemon down: it exits 1) is "not live"; an OPEN ticket is never held back by a session row
  idq="$(fresh quiet)"; "$TKT" start "$idq" >/dev/null
  r="$(STUB_CANON=fail "$TKT" send-issue "$idq" 2>&1)" || fail "canon failing must read as no live session, not refuse: $r"
  assert_contains "$r" "Sent $idq as"
  # a ticket bound to a linked worktree: ITS unpushed commits count, not the main checkout's (the main checkout is level with origin here)
  idl="$(fresh wtbound)"; "$TKT" start "$idl" >/dev/null
  git worktree add -q -b wtbranch "$stub/wt" >/dev/null 2>&1; git -C "$stub/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m wtwork
  printf '%s\n' "$stub/wt" > ".tickets/$idl/.cockpit-cwd"; : > "$STUB_LOG"
  rc=0; r="$("$TKT" send-issue "$idl" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "unpushed commits in the ticket's worktree must refuse, got $rc: $r"; assert_contains "$r" "are on no branch of origin"
  [[ "$(writes)" == 0 ]] || fail "a refused worktree send made a writing gh call"; assert_grep "^status: in_progress$" ".tickets/$idl/ticket.md"
  git update-ref refs/remotes/origin/wtbranch "$(git -C "$stub/wt" rev-parse HEAD)"
  r="$("$TKT" send-issue "$idl" 2>&1)" || fail "the worktree's commits are pushed: the send must go: $r"; assert_contains "$r" "Sent $idl as"
  git worktree remove --force "$stub/wt" >/dev/null 2>&1 || true
  # t-4c09 observer-only: with the events folder unwritable the send behaves exactly the same and logs nothing
  if [[ "$(id -u)" != 0 ]]; then   # root writes into a read-only folder anyway
  # t-d0a5: scripts/test.sh shares one CANON_HOME across parallel suites, so another suite's event could land between the two counts:
  # this block counts a private copy of the events folder.
  shared_home="$CANON_HOME"; CANON_HOME="$stub/canon-home-ro"; mkdir -p "$CANON_HOME"; cp -R "$shared_home/events" "$CANON_HOME/"; export CANON_HOME
  ido2="$(fresh readonly)"; before_n="$(cat "$CANON_HOME"/events/*.jsonl | grep -c . || true)"
  chmod 400 "$CANON_HOME"/events/*.jsonl; chmod 500 "$CANON_HOME/events"   # an existing day file takes an append even in a read-only folder
  r="$("$TKT" send-issue "$ido2" 2>&1)" || { chmod 700 "$CANON_HOME/events"; chmod 600 "$CANON_HOME"/events/*.jsonl; fail "an unwritable events folder broke the send: $r"; }
  chmod 700 "$CANON_HOME/events"; chmod 600 "$CANON_HOME"/events/*.jsonl; assert_contains "$r" "Sent $ido2 as"; [[ -z "$(event_line github.sent "$ido2")" ]] || fail "an event was written into a read-only folder"
  assert_eq "$before_n" "$(cat "$CANON_HOME"/events/*.jsonl | grep -c . || true)"
  CANON_HOME="$shared_home"; export CANON_HOME
  fi
  # no canon on the PATH at all (a cloud session, a minimal install): not live either
  idz="$(fresh nocanon)"; "$TKT" start "$idz" >/dev/null; mv "$stub/canon" "$stub/canon.off"
  r="$(PATH="$stub:/usr/bin:/bin" "$TKT" send-issue "$idz" 2>&1)" || { mv "$stub/canon.off" "$stub/canon"; fail "no canon on the PATH must read as no live session, not refuse: $r"; }
  mv "$stub/canon.off" "$stub/canon"; assert_contains "$r" "Sent $idz as"
  ido="$(fresh openlive)"
  r="$(STUB_SESSIONS="[{\"session\":\"s9\",\"ticket\":\"$ido\"}]" "$TKT" send-issue "$ido" 2>&1)" || fail "an open ticket with a session row must still send: $r"
  assert_contains "$r" "Sent $ido as"
  idc="$(fresh closed)"; "$TKT" close "$idc" --no-sprint >/dev/null
  rc=0; r="$("$TKT" send-issue "$idc" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "a closed ticket must be refused, got $rc"; assert_contains "$r" "is closed; only an open or in-progress ticket"
  # uncommitted code warns (and sends); a tracked, uncommitted ticket file warns only when .tickets/ is tracked
  echo base > tracked.txt; git add tracked.txt; git -c user.name=t -c user.email=t@t commit -q -m tracked; git update-ref "refs/remotes/origin/$br" HEAD
  echo changed >> tracked.txt
  idw="$(fresh warn)"; r="$("$TKT" send-issue "$idw" 2>&1)" || fail "an uncommitted change must warn, not refuse: $r"
  assert_contains "$r" "1 file(s) in "; assert_contains "$r" "have uncommitted or untracked changes"; [[ "$r" != *"under .tickets/ are tracked"* ]] || fail "warned about tracked ticket files in a project that ignores them"
  git checkout -q -- tracked.txt
  r="$("$TKT" send-issue "$(fresh clean)" --dry-run 2>&1)" || fail "a clean tree failed a dry run: $r"
  [[ "$r" != *"uncommitted or untracked changes"* ]] || fail "a clean tree warned about uncommitted changes: $r"
  idt="$(fresh tracked)"; git add -f ".tickets/$idt"; git -c user.name=t -c user.email=t@t commit -q -m "track $idt"; git update-ref "refs/remotes/origin/$br" HEAD
  echo "more" >> ".tickets/$idt/ticket.md"
  r="$("$TKT" send-issue "$idt" --dry-run 2>&1)" || fail "dry run of a tracked ticket with an uncommitted file failed: $r"
  assert_contains "$r" "$idt's files under .tickets/ are tracked and have uncommitted changes"
  git add -f ".tickets/$idt"; git -c user.name=t -c user.email=t@t commit -q -m "commit $idt edits"; git update-ref "refs/remotes/origin/$br" HEAD
  r="$("$TKT" send-issue "$idt" --dry-run 2>&1)" || fail "dry run of a tracked, clean ticket failed: $r"
  [[ "$r" != *"are tracked and have uncommitted changes"* ]] || fail "a tracked ticket with nothing uncommitted warned: $r"
  # no remote branches known at all: it cannot tell, so it says so and still sends
  git for-each-ref --format='%(refname)' refs/remotes/origin | while read -r ref; do git update-ref -d "$ref"; done
  r="$("$TKT" send-issue "$(fresh norefs)" --dry-run 2>&1)" || fail "no origin refs must warn, not refuse: $r"
  assert_contains "$r" "warning: no origin branches are known here"
  git update-ref "refs/remotes/origin/$br" HEAD

  # Asking: n creates nothing and runs no claude; y sends and launches.
  idn="$(fresh no)"; : > "$STUB_LOG"; : > "$STUB_CLAUDE_LOG"; before="$(cksum < ".tickets/$idn/ticket.md")"
  r="$(ptyrun "$idn" n)" || fail "answering n should exit 0: $r"
  assert_contains "$r" "--- body ---"; assert_contains "$r" "not sent; nothing was created"
  assert_contains "$r" "repo: acme/app (PRIVATE)"; assert_contains "$r" "title: $idn: Launch case no"; assert_contains "$r" "# Description"
  [[ "$(writes)" == 0 && ! -s "$STUB_CLAUDE_LOG" ]] || fail "answer n still sent or launched"
  [[ "$(cksum < ".tickets/$idn/ticket.md")" == "$before" ]] || fail "answer n changed the ticket"
  : > "$STUB_CLAUDE_LOG"
  r="$(ptyrun "$(fresh yes2)" y)" || fail "answering y should exit 0: $r"
  assert_contains "$r" "View: https://claude.ai/code/session_abc"
  assert_grep "^arg=--cloud$" "$STUB_CLAUDE_LOG"

  # claude --cloud refuses unless stdin AND stdout are terminals: either one alone is refused, before anything is created.
  for half in stdin stdout; do
    idh="$(fresh "half-$half")"; : > "$STUB_LOG"; : > "$STUB_CLAUDE_LOG"
    rc=0; r="$(PTY_HALF=$half ptyrun "$idh" flag)" || rc=$?
    [[ "$rc" == 1 ]] || fail "a terminal on $half only should exit 1, got $rc: $r"
    assert_contains "$r" "needs an interactive terminal"
    [[ "$(writes)" == 0 && ! -s "$STUB_CLAUDE_LOG" ]] || fail "a terminal on $half only still sent or launched"
  done

  # The answer is read as typed: "yes" sends and launches, and Ctrl-D (end of input) is a no, not a crash.
  : > "$STUB_CLAUDE_LOG"
  r="$(ptyrun "$(fresh word)" yes)" || fail "answering yes should exit 0: $r"
  assert_contains "$r" "View: https://claude.ai/code/session_abc"
  assert_grep "^arg=--cloud$" "$STUB_CLAUDE_LOG"
  : > "$STUB_LOG"; : > "$STUB_CLAUDE_LOG"
  r="$(ptyrun "$(fresh eof)" eof)" || fail "Ctrl-D at the question should exit 0: $r"
  assert_contains "$r" "not sent; nothing was created"
  [[ "$(writes)" == 0 && ! -s "$STUB_CLAUDE_LOG" ]] || fail "Ctrl-D still sent or launched"

  # claude starts in the project root even when tkt runs from a subdirectory.
  mkdir -p sub; : > "$STUB_CLAUDE_LOG"
  r="$(PTY_CWD="$project_real/sub" ptyrun "$(fresh subdir)" flag)" || fail "--launch from a subdirectory failed: $r"
  assert_grep "^cwd=$project_real$" "$STUB_CLAUDE_LOG"
fi

echo "tkt-send-issue: ok"
