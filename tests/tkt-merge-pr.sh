#!/usr/bin/env bash
# t-4718: tkt merge-pr checks a cloud ticket's PR (evaluator passed on its head; open, own repo, mergeable, clean; the test
# command green on base + PR in a scratch clone), asks, then merges with --match-head-commit from outside any checkout.
# Every refusal makes no merge call and leaves ticket.md byte-identical.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-merge-pr.XXXXXX")"
use_fresh_board "$W/board"   # t-4c09: the audit event goes through the board binary (built before HOME moves)
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com
# origin is https://github.com/acme/app.git as far as tkt can tell; pushes land in a bare repo, which also holds the PR ref
# GitHub would. A git shim (on PATH below) sends a fetch or ls-remote of that URL, or of the remote origin, to the bare repo, so
# `remote get-url` stays real and nothing reaches the network.
git init -q --bare "$W/origin.git"
git config --global url."$W/origin.git".pushInsteadOf https://github.com/acme/app.git

P="$W/project"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
git remote set-url origin https://github.com/acme/app.git
# The suite leaves $STUB_W/ran behind, so a test can tell whether the PR's code ran at all.
mkdir -p scripts; printf '#!/usr/bin/env bash\ntouch "$STUB_W/ran"\n[ -e FAIL ] && { echo "suite: 1 failed"; echo "FAILED: stub-suite (exit 1)"; echo "slowest: table"; exit 1; }\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
printf '.tickets/\n' > .gitignore; git add -A; git commit -qm base; git push -q origin HEAD:main
# The PR: one commit on a branch, published as refs/pull/7/head.
git checkout -q -b claude/pr7; echo change > change.txt; git add change.txt; git commit -qm "the PR"; PRHEAD="$(git rev-parse HEAD)"
git push -q origin "HEAD:refs/pull/7/head"; git checkout -q main

id="$("$TKT" create "Cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"
awk '/^---$/ && ++n == 2 { print "github: acme/app#21" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"
eval_ok() { printf 'evaluator-run-id: 1-1\ngraded-head: %s\n## Verdict\npass: all met\n' "${1:-$PRHEAD}" > ".tickets/$id/eval-report.md"; }
eval_ok

# The stub gh: pr list prints $W/prlist (what --jq would leave: PR numbers); pr view prints the TSV for STUB_* fields, or
# the merge commit; pr merge logs its arguments and the directory it ran in.
mkdir "$W/bin"; cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "pr list")  cat "$STUB_W/prlist" ;;
  "pr view")  [[ -n "${STUB_VIEW_FAIL:-}" && "$*" != *mergeCommit* ]] && { echo "HTTP 502" >&2; exit 1; }
              if [[ "$*" == *mergeCommit* ]]; then   # STUB_NO_SHA: GitHub has no merge commit; gh's --jq then prints "null" unless "// empty"
                if [[ -z "${STUB_NO_SHA:-}" ]]; then echo "mergesha0000000000000000000000000000000000"; elif [[ "$*" != *"// empty"* ]]; then echo null; fi
                exit 0; fi
              if [[ "$*" == *"--json state --jq"* ]]; then echo "${STUB_AFTER:-OPEN}"; exit 0; fi
              # STUB_SCRIPT: a file of "MG MS" lines, one per read (the last repeats); STUB_READS counts the reads.
              if [[ -n "${STUB_SCRIPT:-}" ]]; then n=$(( $(cat "$STUB_W/reads" 2>/dev/null || echo 0) + 1 )); echo $n > "$STUB_W/reads"
                read -r STUB_MG STUB_MS < <(sed -n "${n}p" "$STUB_SCRIPT" | grep . || tail -1 "$STUB_SCRIPT"); fi
              if [[ "$*" == *"--json isDraft,mergeStateStatus,mergeable"* ]]; then printf '%s\t%s\t%s\n' "${STUB_REREAD_DRAFT:-${STUB_DRAFT:-false}}" "${STUB_REREAD_MS:-${STUB_MS:-CLEAN}}" "${STUB_MG:-MERGEABLE}"; exit 0; fi   # t-a463: the re-read after a refused merge
              if [[ "$*" == *"--json state,isCrossRepository,isDraft"* ]]; then printf '%s\t%s\t%s\n' "${STUB_STATE:-OPEN}" "${STUB_CROSS:-false}" "${STUB_DRAFT:-false}"; exit 0; fi   # t-a463: pr-ready's read
              printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${STUB_STATE:-OPEN}" "${STUB_MG:-MERGEABLE}" "${STUB_MS:-CLEAN}" \
                "${STUB_HEAD:?}" main "${STUB_CROSS:-false}" "${STUB_DRAFT:-false}" ;;
  "pr ready") exit "${STUB_READY_RC:-0}" ;;
  "pr merge") printf 'cwd %s\n' "$PWD" >> "$STUB_LOG"; [[ -n "${STUB_MERGE_FAIL:-}" ]] && { echo "could not delete branch" >&2; exit 1; }
              # STUB_MERGE_PUSH: GitHub's merge moves main on origin (here: to the PR head, a fast-forward of the base).
              [[ -n "${STUB_MERGE_PUSH:-}" ]] && git --git-dir="$STUB_W/origin.git" update-ref refs/heads/main "$STUB_HEAD"; exit 0 ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$W/bin/gh"
REAL_GIT="$(command -v git)"
cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
[[ -n "\${STUB_FF_FETCH_FAIL:-}" && " \$* " == *" fetch -q origin refs/heads/main "* ]] && { echo "fatal: unable to access origin" >&2; exit 128; }
[[ -n "\${STUB_UPDATE_REF_FAIL:-}" && " \$* " == *" update-ref refs/heads/main "* ]] && { echo "fatal: forced update-ref failure" >&2; exit 128; }
if [[ " \$* " == *" merge -q --ff-only "* ]]; then
  [[ -z "\${STUB_FF_SPY:-}" ]] || grep -c '^merged:' "\$STUB_FF_SPY" > "$W/ff-spy" || true
  [[ -z "\${STUB_FF_MERGE_FAIL:-}" ]] || { echo "error: forced ff failure" >&2; exit 1; }
fi
if [[ " \$* " == *" fetch "* || " \$* " == *" ls-remote "* ]]; then a=(); for x in "\$@"; do [[ "\$x" == https://github.com/acme/app.git || "\$x" == origin ]] && x="$W/origin.git"; a+=("\$x"); done; set -- "\${a[@]}"; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/bin/git"
export PATH="$W/bin:$PATH" STUB_LOG="$W/gh.log" STUB_W="$W" STUB_HEAD="$PRHEAD"
echo 7 > "$W/prlist"
sig() { cksum < "$f"; }
merged() { grep -q '^pr merge' "$STUB_LOG"; }

# refuses <label> <expected message> [env assignments...] -- [merge-pr args...]: exit 1, message, no merge, ticket unchanged.
refuses() {
  local label="$1" part="$2"; shift 2; local envs=(); out=""; while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  : > "$STUB_LOG"; local before; before="$(sig)"; local rc=0
  out="$(env ${envs[@]+"${envs[@]}"} "$TKT" merge-pr "$id" "$@" < /dev/null 2>&1)" || rc=$?
  : "${out}"   # left for the caller to read
  [[ "$rc" == 1 ]] || fail "merge-pr should refuse $label (rc $rc): $out"
  assert_contains "$out" "$part"
  merged && fail "merge-pr called gh pr merge although it refused $label"
  [[ "$(sig)" == "$before" ]] || fail "ticket.md changed although merge-pr refused $label"
  echo "merge-pr: refused $label"
}

# Refusals, one check each.
printf 'graded-head: %s\nfail: one criterion\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
refuses "a failing verdict" "no passing evaluator verdict" -- --yes
[[ ! -e ".tickets/$id/github.md" ]] || fail "a refusal before the PR was read wrote the GitHub trail (t-1dec)"
rm ".tickets/$id/eval-report.md"
refuses "no eval-report.md" "no passing evaluator verdict" -- --yes
eval_ok 0123456789abcdef0123456789abcdef01234567
refuses "a head the evaluator did not grade" "is not the commit the evaluator graded" -- --yes
# t-1dec: that refusal came after the PR was read, so it is the trail's first block (the refusals above came before).
gt=".tickets/$id/github.md"; assert_eq "# GitHub" "$(head -1 "$gt")"; assert_eq 1 "$(grep -c '^## ' "$gt")"
assert_grep '^## .* — refused$' "$gt"; assert_grep '^reason: PR head .* is not the graded-head ' "$gt"
printf 'graded-head: %s\n## Verdict\npass: all met\nfail: one criterion\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
refuses "two verdict lines" "2 verdict lines and 1 graded-heads" -- --yes
printf 'graded-head: %s\ngraded-head: %s\npass: all met\n' "$PRHEAD" 0123456789abcdef0123456789abcdef01234567 > ".tickets/$id/eval-report.md"
refuses "two graded-heads" "1 verdict lines and 2 graded-heads" -- --yes
eval_ok
refuses "a closed PR" "is CLOSED, not open" STUB_STATE=CLOSED -- --yes
# t-1dec: a refusal after the PR was read is one `refused` block on the ticket's GitHub trail.
assert_eq 2 "$(grep -c '^## ' "$gt")"; assert_contains "$(tail -n 3 "$gt")" "reason: PR is CLOSED, not open"
refuses "a fork's PR" "comes from a fork" STUB_CROSS=true -- --yes
assert_eq 3 "$(grep -c '^## ' "$gt")"; assert_contains "$(tail -n 3 "$gt")" "PR: #7"
cp "$gt" "$W/trail.before"
refuses "a PR that cannot merge" "cannot merge cleanly" STUB_MG=CONFLICTING STUB_MS=DIRTY -- --yes
refuses "a blocked PR" "blocked by a branch rule" STUB_MS=BLOCKED -- --yes
: > "$W/prlist"; refuses "no PR saying Fixes #21" "no open PR says Fixes #21" -- --yes
printf '7\n8\n' > "$W/prlist"; refuses "two PRs saying Fixes #21" "several open PRs say Fixes #21" -- --yes
echo 7 > "$W/prlist"
# The head moves on GitHub between the check and the fetch: refused.
git checkout -q claude/pr7; echo more >> change.txt; git commit -qam more; git push -q -f origin "HEAD:refs/pull/7/head"
refuses "a PR that moved after the check" "moved while checking it" -- --yes
git reset -q --hard "$PRHEAD"; git push -q -f origin "HEAD:refs/pull/7/head"; git checkout -q main
# A red suite on base + PR: refused, with its output. This PR also changes scripts/test.sh, which the summary flags.
git checkout -q claude/pr7; touch FAIL; echo '# changed' >> scripts/test.sh; git add FAIL scripts/test.sh; git commit -qm red; RED="$(git rev-parse HEAD)"
git push -q -f origin "HEAD:refs/pull/7/head"
eval_ok "$RED"; refuses "a red suite" "suite: 1 failed" STUB_HEAD="$RED" -- --yes
assert_contains "$out" "this PR changes scripts/test.sh itself"
# t-6b90: the failing suite is named before the tail, and the full log is kept.
assert_contains "$out" "Failing:"; assert_contains "$out" "FAILED: stub-suite (exit 1)"
[[ "${out%%FAILED: stub-suite*}" != *"Last lines:"* ]] || fail "FAILED line came after the tail: $out"
klog="$(printf '%s\n' "$out" | sed -n 's/^Full log kept at: //p')"; [[ "$klog" == "$TMPDIR/tkt-merge-$id-pr7."* ]] || fail "no kept-log path in: $out"
grep -q 'slowest: table' "$klog" || fail "kept log is missing the full output"; rm -f "$klog"
git reset -q --hard "$PRHEAD"; git push -q -f origin "HEAD:refs/pull/7/head"; git checkout -q main; eval_ok
# --test overrides the default: a failing command refuses.
refuses "a failing --test command" "false failed" -- --test false --yes
[[ "$out" != *"Failing:"* ]] || fail "a failure with no FAILED lines printed a Failing: header: $out"
assert_contains "$out" "Full log kept at:"; rm -f "$TMPDIR"/tkt-merge-*
# No terminal and no --yes: refused before any of the PR's code runs.
rm -f "$W/ran"; refuses "no terminal without --yes" "no terminal to ask on" --
[[ ! -e "$W/ran" ]] || fail "the PR's tests ran before anyone said yes"
assert_contains "$(tail -n 3 "$gt")" "reason: no terminal to ask on"   # t-1dec: this refusal came after the PR was read, so it is on the trail
[[ -z "$(ls "$TMPDIR" | grep '^tkt-merge\.' || true)" ]] || fail "a scratch clone was left behind"
# A PR that deletes scripts/test.sh cannot switch the gate off: the default comes from the base branch, so it runs, fails.
git checkout -q claude/pr7; git rm -q scripts/test.sh; git commit -qm "drop the suite"; NOSUITE="$(git rev-parse HEAD)"
git push -q -f origin "HEAD:refs/pull/7/head"
eval_ok "$NOSUITE"; refuses "a PR that deletes scripts/test.sh" "scripts/test.sh failed" STUB_HEAD="$NOSUITE" -- --yes
git reset -q --hard "$PRHEAD"; git push -q -f origin "HEAD:refs/pull/7/head"; git checkout -q main; eval_ok
# gh merge fails and GitHub says the PR is still open: a real failure, nothing recorded.
before="$(sig)"; rc=0; out="$(STUB_MERGE_FAIL=1 "$TKT" merge-pr "$id" --yes 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a merge GitHub did not make should exit 1, got $rc"
assert_contains "$out" "gh could not merge PR #7: could not delete branch"
[[ "$(sig)" == "$before" ]] || fail "a failed merge recorded something in ticket.md"

# t-a463: a draft PR (a cloud PR always is one) is refused in seconds, before the clone and the test run, for --check and a real run alike.
rm -f "$W/ran"; gt=".tickets/$id/github.md"; blocks_before="$(grep -c '^## ' "$gt")"
refuses "a draft PR" "PR #7 is a draft; GitHub will not merge it. Run: gh pr ready 7" STUB_DRAFT=true -- --yes
[[ ! -e "$W/ran" ]] || fail "the suite ran on a draft PR (t-a463)"
assert_eq "$((blocks_before + 1))" "$(grep -c '^## ' "$gt")"; assert_grep '^reason: PR is a draft$' "$gt"
blocks_before="$(grep -c '^## ' "$gt")"
refuses "a draft PR on --check" "is a draft; GitHub will not merge it" STUB_DRAFT=true -- --check
assert_eq "$blocks_before" "$(grep -c '^## ' "$gt")"   # --check is read-only: no trail entry
# gh could not say whether it is a draft (the field arrives as "-" after jq): not "not a draft"; nothing runs (fails closed)
rm -f "$W/ran"
refuses "a PR whose draft state gh did not say" "did not say whether PR #7 is a draft" STUB_DRAFT=- -- --yes
[[ ! -e "$W/ran" ]] || fail "the suite ran although gh did not say whether the PR is a draft (t-a463)"
# the same PR, not a draft, still checks as ready (positive control)
out="$("$TKT" merge-pr "$id" --check 2>&1)" || fail "a non-draft PR no longer checks: $out"
assert_contains "$out" "merge-pr: ready"
# after a passing suite GitHub refuses anyway: say the suite passed, what GitHub said, and what the PR reads like now (the draft, named)
before="$(sig)"; rc=0; out="$(STUB_MERGE_FAIL=1 STUB_REREAD_DRAFT=true "$TKT" merge-pr "$id" --yes 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a refused merge should exit 1, got $rc"
assert_contains "$out" "the suite passed on main + PR #7; GitHub refused the merge."
assert_contains "$out" "gh could not merge PR #7: could not delete branch"
assert_contains "$out" "PR #7 now reads: draft=true, mergeStateStatus=CLEAN, mergeable=MERGEABLE; PR #7 is a draft: run gh pr ready 7"
[[ "$(sig)" == "$before" ]] || fail "a refused merge recorded something in ticket.md"
out="$(STUB_MERGE_FAIL=1 STUB_REREAD_MS=BEHIND "$TKT" merge-pr "$id" --yes 2>&1)" || true
assert_contains "$out" "the PR branch is behind main: update it, then merge"
echo "merge-pr: names a draft first, and what GitHub refused after a passing suite (t-a463)"

# tkt pr-ready: marks the ticket's own open, same-repo DRAFT PR ready, with one gh call; anything else changes nothing.
readyc() { grep -c '^pr ready' "$STUB_LOG" || true; }
: > "$STUB_LOG"; before="$(sig)"
out="$(STUB_DRAFT=true "$TKT" pr-ready "$id" 2>&1)" || fail "pr-ready on a draft failed: $out"
assert_contains "$out" "Marked PR #7 ready for review"; assert_eq 1 "$(readyc)"; assert_grep '^pr ready 7 --repo acme/app$' "$STUB_LOG"
assert_grep '— ready$' "$gt"
for c in "a PR that is not a draft|false|OPEN|false|not a draft" "a closed PR|true|CLOSED|false|is CLOSED, not open" "a PR from a fork|true|OPEN|true|comes from a fork"; do
  IFS='|' read -r label d st cr msg <<< "$c"
  : > "$STUB_LOG"; rc=0; out="$(STUB_DRAFT=$d STUB_STATE=$st STUB_CROSS=$cr "$TKT" pr-ready "$id" 2>&1)" || rc=$?
  assert_contains "$out" "$msg"; assert_eq 0 "$(readyc)"
  [[ "$label" == "a PR that is not a draft" ]] || [[ "$rc" == 1 ]] || fail "pr-ready should refuse $label (rc $rc): $out"
done
# only THIS ticket's own PR: another open draft's number (the board or a typo) is refused, with no gh pr ready call; the ticket's own number passes
: > "$STUB_LOG"; rc=0; out="$(STUB_DRAFT=true "$TKT" pr-ready "$id" --pr 99 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "pr-ready marked a PR that is not the ticket's ready (rc $rc): $out"
assert_contains "$out" "PR #99 is not this ticket's PR"; assert_eq 0 "$(readyc)"
: > "$STUB_LOG"; out="$(STUB_DRAFT=true "$TKT" pr-ready "$id" --pr 7 2>&1)" || fail "pr-ready refused the ticket's own PR when named: $out"
assert_eq 1 "$(readyc)"
: > "$STUB_LOG"; rc=0; out="$(STUB_DRAFT=- "$TKT" pr-ready "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "pr-ready acted when gh did not say whether the PR is a draft (rc $rc): $out"; assert_eq 0 "$(readyc)"
: > "$STUB_LOG"; rc=0; out="$(STUB_DRAFT=true "$TKT" pr-ready "$id" --pr '7;x' 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "pr-ready took a PR argument that is not a number: $out"; assert_eq 0 "$(readyc)"
[[ "$(sig)" == "$before" ]] || fail "pr-ready changed ticket.md"
echo "pr-ready: marks only the ticket's own open same-repo draft ready (t-a463)"

# The prompt needs a pseudo-terminal from script(1); Git Bash on Windows has none, so those cases skip there, loudly.
if command -v script >/dev/null 2>&1; then
# The prompt: "n" runs nothing and merges nothing; "y" runs the tests and merges. A pseudo-terminal answers it (script(1):
# BSD and util-linux spellings).
tty_run() { local a="$1"; shift
  # The pipe stays open a while: BSD script sends EOF to the terminal as soon as its input closes, before the prompt reads.
  if script --version >/dev/null 2>&1 < /dev/null; then { printf '%s\n' "$a"; sleep 3; } | script -qec "$(printf '%q ' "$@")" /dev/null
  else { printf '%s\n' "$a"; sleep 3; } | script -q /dev/null "$@"; fi; }
: > "$STUB_LOG"; before="$(sig)"; rm -f "$W/ran"
out="$(tty_run n "$TKT" merge-pr "$id" 2>&1)" || true
assert_contains "$out" "PR #7 (acme/app): 1 file changed"
assert_contains "$out" "Run PR #7's code here (scripts/test.sh on main + PR) and merge into main if it passes? This also closes #21. [y/N]"
assert_contains "$out" "merge-pr: nothing run, not merged"
[[ ! -e "$W/ran" ]] || fail "an n at the prompt still ran the PR's tests"
merged && fail "an n at the prompt merged"; [[ "$(sig)" == "$before" ]] || fail "an n at the prompt changed ticket.md"

: > "$STUB_LOG"
rm -f "$TMPDIR"/tkt-merge-*
[[ -z "$(event_line github.merged "$id")" ]] || fail "a refused or declined merge wrote github.merged"   # t-4c09
out="$(tty_run y "$TKT" merge-pr "$id" 2>&1)" || fail "merge-pr with y failed: $out"
[[ -z "$(ls "$TMPDIR" | grep '^tkt-merge-.*-pr[0-9]*\.' || true)" ]] || fail "a passing run kept a log"
gm="$(event_line github.merged "$id")"; assert_contains "$gm" '"pr":"7"'; assert_contains "$gm" '"source":"tkt"'; [[ "$gm" != *'"actor"'* ]] || fail "a CLI merge claimed an actor: $gm"
assert_contains "$out" "running scripts/test.sh on main + PR #7"
assert_contains "$out" "Merged PR #7 into main"
grep -qx "pr merge 7 --repo acme/app --merge --delete-branch --match-head-commit $PRHEAD" "$STUB_LOG" || fail "wrong merge call: $(cat "$STUB_LOG")"
assert_eq "/" "$(sed -n 's/^cwd //p' "$STUB_LOG")"   # never inside a checkout, so --delete-branch cannot touch local branches
assert_grep '^merged: mergesha0000000000000000000000000000000000$' "$f"
grep -q '^pr list' "$STUB_LOG" || fail "the PR was not found by its Fixes line"
# On a terminal the progress line is rewritten in place (carriage return), every 2 s.
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
out="$(tty_run y "$TKT" merge-pr "$id" --pr 7 --test 'echo tty step; sleep 5' 2>&1)" || fail "tty progress run failed: $out"
[[ "$out" == *$'\r'"merge-pr: running echo tty step; sleep 5 on main + PR #7… 0m0"*"(tty step)"* ]] || fail "no in-place progress on a terminal: $(printf '%q' "$out")"
else
  echo "tkt-merge-pr: SKIPPED the prompt cases: no script(1) here for a pseudo-terminal" >&2
  sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; "$TKT" merge-pr "$id" --yes > /dev/null 2>&1 || fail "merge-pr --yes failed"
fi

# t-b2e5: after a merge, a canon-results/<id> branch left by a close on this machine is deleted; a refused delete only
# warns. The bare origin's pre-receive hook refuses deletes while $W/no-delete exists.
printf '#!/usr/bin/env bash\n[ -e "%s/no-delete" ] && grep -q "^[0-9a-f]* 0\\{40\\} refs/heads/canon-results/" && { echo "delete refused" >&2; exit 1; }\nexit 0\n' "$W" > "$W/origin.git/hooks/pre-receive"
chmod +x "$W/origin.git/hooks/pre-receive"
results_branch() { git push -q origin "main:refs/heads/canon-results/$id" 2>/dev/null; }
has_results() { git ls-remote --heads origin "canon-results/$id" | grep . >/dev/null; }
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; results_branch; has_results || fail "the test could not create canon-results/$id"
out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "merge-pr failed: $out"
has_results && fail "merge-pr left canon-results/$id on origin"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "merge-pr failed without a results branch: $out"   # none: fine
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; results_branch; touch "$W/no-delete"
out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "a refused branch delete failed the merge: $out"
assert_contains "$out" "could not delete canon-results/$id on origin"; has_results || fail "the refused delete still deleted"
rm -f "$W/no-delete"; git push -q origin --delete "canon-results/$id"

# --yes, --pr and no test command: merges on the gates alone and says so.
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; git rm -q scripts/test.sh; git commit -qm "no suite"; git push -q origin HEAD:main
: > "$STUB_LOG"; out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "merge-pr --yes failed: $out"
assert_contains "$out" "No test command (pass --test). Merge PR #7 into main on the gates alone? yes (--yes)"
grep -q '^pr list' "$STUB_LOG" && fail "--pr still searched for the PR"
grep -q '^pr merge 7 ' "$STUB_LOG" || fail "--yes did not merge"

# t-bad4: --check runs only the checks that execute nothing, reports, and stops: exit 0 ready, 1 with the reason.
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; : > "$STUB_LOG"; rm -f "$W/ran"; before="$(sig)"
out="$("$TKT" merge-pr "$id" --pr 7 --check --test 'touch "$STUB_W/ran"' 2>&1)" || fail "--check on a ready PR failed: $out"
assert_contains "$out" "PR #7 (acme/app):"
assert_contains "$out" "merge-pr: ready: would run touch \"\$STUB_W/ran\" on main + PR #7, then merge (closes #21)"
[[ ! -e "$W/ran" ]] || fail "--check ran the test command"
merged && fail "--check merged"; [[ "$(sig)" == "$before" ]] || fail "--check changed ticket.md"
n_before="$(grep -c '^## ' "$gt")"; "$TKT" merge-pr "$id" --pr 7 --check >/dev/null 2>&1
assert_eq "$n_before" "$(grep -c '^## ' "$gt")"   # t-1dec: --check appends nothing
n_before="$(grep -c '^## ' "$gt")"
refuses "--check on a blocked PR" "blocked by a branch rule" STUB_MS=BLOCKED -- --pr 7 --check
assert_eq "$n_before" "$(grep -c '^## ' "$gt")"   # t-1dec: a --check refusal appends nothing either
refuses "--yes with --check" "do not go together" -- --pr 7 --yes --check

# Progress while the tests run: without a terminal a plain line every CANON_PROGRESS_SECONDS, naming the newest log line.
: > "$STUB_LOG"
out="$(CANON_PROGRESS_SECONDS=1 "$TKT" merge-pr "$id" --pr 7 --yes --test 'echo step one; sleep 3; printf "old\rstep \033[1mtwo\033[0m\n"; sleep 2' 2>&1)" || fail "a slow suite run failed: $out"
assert_contains "$out" "(step one)"; assert_contains "$out" "(step two)"   # after the last \r, escape sequences removed
assert_contains "$out" "passed in 0m0"
[[ "$out" != *$'\r'* ]] || fail "progress used carriage returns without a terminal"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
# t-a36b: merge-pr's own pacing variable never reaches the code under test (the board sets it; a suite's stub may log it).
: > "$STUB_LOG"; rm -f "$W/progress-env"
CANON_PROGRESS_SECONDS=1 "$TKT" merge-pr "$id" --pr 7 --yes --test 'echo "${CANON_PROGRESS_SECONDS-unset}" > "$STUB_W/progress-env"' >/dev/null 2>&1 \
  || fail "a run with CANON_PROGRESS_SECONDS set failed"
assert_eq "unset" "$(cat "$W/progress-env" 2>/dev/null)"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
# t-e523: before the test log has a line, the progress line ends at the time, with no empty "()".
: > "$STUB_LOG"
out="$(CANON_PROGRESS_SECONDS=1 "$TKT" merge-pr "$id" --pr 7 --yes --test 'sleep 2' 2>&1)" || fail "a silent suite run failed: $out"
assert_contains "$out" "merge-pr: running sleep 2 on main + PR #7… 0m0"
[[ "$out" != *"()"* ]] || fail "an empty test log printed (): $out"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
# An interrupt (TERM, or HUP: a closed terminal) stops the whole test run, its children included, says so, merges nothing.
for sig_name in TERM HUP; do
  : > "$STUB_LOG"; rm -f "$W/child.pid"; before="$(sig)"
  "$TKT" merge-pr "$id" --pr 7 --yes --test 'sleep 60 & echo $! > "$STUB_W/child.pid"; wait' > "$W/int.out" 2>&1 & mpid=$!
  for _ in $(seq 100); do [[ -s "$W/child.pid" ]] && break; sleep 0.1; done
  [[ -s "$W/child.pid" ]] || fail "the slow test command never started ($sig_name)"
  kill -"$sig_name" "$mpid"; rc=0; wait "$mpid" || rc=$?
  [[ "$rc" != 0 ]] || fail "merge-pr exited 0 after $sig_name"
  for _ in $(seq 20); do pid_alive "$(cat "$W/child.pid")" || break; sleep 0.2; done
  ! pid_alive "$(cat "$W/child.pid")" || { kill "$(cat "$W/child.pid")" 2>/dev/null; fail "the test command's child outlived $sig_name"; }
  assert_contains "$(cat "$W/int.out")" "merge-pr: stopped; the tests were ended and nothing was merged"
  merged && fail "merge-pr merged after $sig_name"; [[ "$(sig)" == "$before" ]] || fail "merge-pr changed ticket.md after $sig_name"
done

# gh fails after GitHub merged (the branch delete, say): recorded as merged, with gh's message; no sha → no "null".
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
out="$(STUB_MERGE_FAIL=1 STUB_AFTER=MERGED STUB_NO_SHA=1 "$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "a merge GitHub made was reported as a failure: $out"
assert_contains "$out" "Merged PR #7 into main (gh reported: could not delete branch)"
assert_grep '^merged: PR #7$' "$f"
# t-1dec: a merge is a `merged` block (PR, merge commit, base), appended after the earlier ones, which stay byte-identical.
assert_contains "$(awk '/^## .* — merged$/ { b = "" } { b = b $0 "\n" } END { printf "%s", b }' "$gt")" "PR: #7"
assert_contains "$(tail -n 5 "$gt")" "base: main"
assert_eq "$(cat "$W/trail.before")" "$(head -n "$(wc -l < "$W/trail.before")" "$gt")"
# A github.md that is a symlink is never written through.
mv "$gt" "$W/trail.real"; ln -s "$W/trail.real" "$gt"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
cp "$W/trail.real" "$W/trail.sym.before"
out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "a symlinked github.md failed the merge: $out"
assert_contains "$out" "warning: could not write the GitHub trail"; cmp -s "$W/trail.real" "$W/trail.sym.before" || fail "the trail was written through a symlink"
rm -f "$gt"; mv "$W/trail.real" "$gt"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
# A trail that cannot be written (a directory in its place; root ignores permissions) warns once; the merge still succeeds.
rm -f "$gt"; mkdir "$gt"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "an unwritable github.md failed the merge: $out"
assert_contains "$out" "Merged PR #7 into main"; assert_eq 1 "$(printf '%s\n' "$out" | grep -c '^warning: could not write the GitHub trail')"
rmdir "$gt"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"

# t-fdb1: a head past graded-head merges only when what came after is merge-safe late docs (the cloud's learnings sweep).
past() {   # past <file>...: one commit on top of the graded PR head touching those files, published as PR #7's head; prints its sha
  git checkout -q -B past "$PRHEAD"; local x; for x in "$@"; do mkdir -p "$(dirname "$x")"; echo "$x" > "$x"; git add -f "$x"; done
  git commit -qm "after grading"; git push -qf origin "HEAD:refs/pull/7/head"; git rev-parse HEAD; git checkout -q main
}
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; eval_ok "$PRHEAD"
LATE="$(past LEARNINGS.md LEARNINGS-archive.md ".tickets/$id/summary.md")"; : > "$STUB_LOG"
out="$(STUB_HEAD="$LATE" "$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "a late-docs-only head was refused: $out"
assert_contains "$out" "merge-pr: PR #7 head is graded-head plus late docs only: .tickets/$id/summary.md, LEARNINGS-archive.md, LEARNINGS.md"
grep -qx "pr merge 7 --repo acme/app --merge --delete-branch --match-head-commit $LATE" "$STUB_LOG" || fail "late-docs merge not pinned to its head: $(cat "$STUB_LOG")"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
CODE="$(past LEARNINGS.md tools/x.sh)"
refuses "a code file after grading" "since then it changes tools/x.sh: re-run the gates on it" STUB_HEAD="$CODE" -- --pr 7 --yes
AGENTREAD="$(past CLAUDE.md)"
refuses "an agent-read late doc after grading" "since then it changes CLAUDE.md" STUB_HEAD="$AGENTREAD" -- --pr 7 --yes
OTHER="$(past .tickets/t-0th3/plan.md)"
refuses "another ticket's folder after grading" "since then it changes .tickets/t-0th3/plan.md" STUB_HEAD="$OTHER" -- --pr 7 --yes
DOT="$(past ".tickets/$id/.cockpit-cwd")"
refuses "a dotfile in the ticket's folder after grading" "since then it changes .tickets/$id/.cockpit-cwd" STUB_HEAD="$DOT" -- --pr 7 --yes
git checkout -q -B past "$PRHEAD"; ln -s AGENTS.md LEARNINGS.md; git add LEARNINGS.md; git commit -qm "symlink after grading"
git push -qf origin "HEAD:refs/pull/7/head"; LINK="$(git rev-parse HEAD)"; git checkout -q main
refuses "a symlink under an allowed name after grading" "LEARNINGS.md (symlink or submodule)" STUB_HEAD="$LINK" -- --pr 7 --yes
git push -qf origin "$PRHEAD:refs/pull/7/head"

# t-75f5: the cloud's audit log (.claude/subagent-runs.jsonl) is the one file under .claude/ that may follow the grade, and only appended to.
# The graded head here already holds a two-line log; each head below is one commit on it published as PR #7's head.
LOGBASE="$(git checkout -q -B past "$PRHEAD"; mkdir -p .claude; printf 'a\nb\n' > .claude/subagent-runs.jsonl; git add -f .claude/subagent-runs.jsonl
  git commit -qm "graded with a log"; git rev-parse HEAD; git checkout -q main)"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; eval_ok "$LOGBASE"
pastlog() {   # pastlog <log content> [file...]: a commit on LOGBASE that sets the log to that text and touches the files
  git checkout -q -B past "$LOGBASE"; printf '%s' "$1" > .claude/subagent-runs.jsonl; shift; local x
  for x in "$@"; do mkdir -p "$(dirname "$x")"; echo "$x" > "$x"; git add -f "$x"; done
  git add -f .claude/subagent-runs.jsonl; git commit -qm "after grading"; git push -qf origin "HEAD:refs/pull/7/head"; git rev-parse HEAD; git checkout -q main
}
GREW="$(pastlog $'a\nb\nc\n' ".tickets/$id/summary.md" LEARNINGS.md)"; : > "$STUB_LOG"
out="$(STUB_HEAD="$GREW" "$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "a head that only appended to the audit log was refused: $out"
assert_contains "$out" "merge-pr: PR #7 head is graded-head plus late docs only: .claude/subagent-runs.jsonl, .tickets/$id/summary.md, LEARNINGS.md"
grep -qx "pr merge 7 --repo acme/app --merge --delete-branch --match-head-commit $GREW" "$STUB_LOG" || fail "the audit-log merge was not pinned to its head: $(cat "$STUB_LOG")"
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
refuses "a rewritten audit log" "since then it changes .claude/subagent-runs.jsonl (rewritten; not appended)" STUB_HEAD="$(pastlog $'a\nX\nc\n')" -- --pr 7 --yes
refuses "a truncated audit log" "since then it changes .claude/subagent-runs.jsonl (rewritten; not appended)" STUB_HEAD="$(pastlog $'a\n')" -- --pr 7 --yes
refuses "an emptied audit log" "since then it changes .claude/subagent-runs.jsonl (rewritten; not appended)" STUB_HEAD="$(pastlog '')" -- --pr 7 --yes
refuses "an appended log beside a code file" "since then it changes tools/x.sh" STUB_HEAD="$(pastlog $'a\nb\nc\n' tools/x.sh)" -- --pr 7 --yes
refuses "an appended log beside two code files" "since then it changes tools/x.sh, tools/y.sh" STUB_HEAD="$(pastlog $'a\nb\nc\n' tools/x.sh tools/y.sh)" -- --pr 7 --yes
refuses "a rewritten log beside a code file" "since then it changes .claude/subagent-runs.jsonl (rewritten; not appended), tools/x.sh" STUB_HEAD="$(pastlog $'a\nX\n' tools/x.sh)" -- --pr 7 --yes
refuses "another file under .claude/" "since then it changes .claude/settings.json" STUB_HEAD="$(pastlog $'a\nb\nc\n' .claude/settings.json)" -- --pr 7 --yes
refuses "an agent definition under .claude/" "since then it changes .claude/agents/x.md" STUB_HEAD="$(pastlog $'a\nb\nc\n' .claude/agents/x.md)" -- --pr 7 --yes
refuses "a look-alike log name" "since then it changes .claude/subagent-runs.jsonl.bak" STUB_HEAD="$(pastlog $'a\nb\nc\n' .claude/subagent-runs.jsonl.bak)" -- --pr 7 --yes
refuses "the log's name in another folder" "since then it changes x/.claude/subagent-runs.jsonl" STUB_HEAD="$(pastlog $'a\nb\nc\n' x/.claude/subagent-runs.jsonl)" -- --pr 7 --yes
git checkout -q -B past "$LOGBASE"; chmod +x .claude/subagent-runs.jsonl; git add -f .claude/subagent-runs.jsonl; git commit -qm "log mode only"
git push -qf origin "HEAD:refs/pull/7/head"; MODE="$(git rev-parse HEAD)"; git checkout -q main
refuses "a mode-only change to the audit log" "since then it changes .claude/subagent-runs.jsonl (rewritten; not appended)" STUB_HEAD="$MODE" -- --pr 7 --yes
git checkout -q -B past "$LOGBASE"; printf 'a\nb\n\000c\n' > .claude/subagent-runs.jsonl; git add -f .claude/subagent-runs.jsonl; git commit -qm "binary log"
git push -qf origin "HEAD:refs/pull/7/head"; BIN="$(git rev-parse HEAD)"; git checkout -q main
refuses "a binary audit log" "since then it changes .claude/subagent-runs.jsonl (rewritten; not appended)" STUB_HEAD="$BIN" -- --pr 7 --yes
git checkout -q -B past "$LOGBASE"; rm .claude/subagent-runs.jsonl; ln -s AGENTS.md .claude/subagent-runs.jsonl; git add -f .claude/subagent-runs.jsonl; git commit -qm "log as a link"
git push -qf origin "HEAD:refs/pull/7/head"; LOGLINK="$(git rev-parse HEAD)"; git checkout -q main
refuses "the audit log turned into a symlink" ".claude/subagent-runs.jsonl (symlink or submodule)" STUB_HEAD="$LOGLINK" -- --pr 7 --yes
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; eval_ok "$PRHEAD"; git push -qf origin "$PRHEAD:refs/pull/7/head"

# t-24b1: after the merge, local main catches up with origin's, fast-forward only, or is left alone with the reason.
BASE="$(git rev-parse "$PRHEAD^")"
ff_merge() {   # origin main back at the base, the ticket unmerged; one merge-pr --yes whose merge moves origin main
  git --git-dir="$W/origin.git" update-ref refs/heads/main "$BASE"
  sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
  STUB_MERGE_PUSH=1 "$TKT" merge-pr "$id" --pr 7 --yes --test true 2>&1
}
git checkout -q main; git reset -q --hard "$BASE"
out="$(STUB_FF_SPY="$PWD/$f" ff_merge)"; assert_contains "$out" "Local main: ${BASE:0:8} -> ${PRHEAD:0:8} (fast-forward)"
assert_eq 0 "$(cat "$W/ff-spy")"; assert_grep '^merged: mergesha' "$f"   # t-41ff: merged: is written after main moved, not before
assert_eq "$PRHEAD" "$(git rev-parse main)"; [[ "$(git status --porcelain --untracked-files=no)" == "" ]] || fail "the fast-forward left changes"
git reset -q --hard "$BASE"; echo dirty >> .gitignore                      # t-41ff: an edit the merge does not touch survives it
out="$(ff_merge)"; assert_contains "$out" "Local main: ${BASE:0:8} -> ${PRHEAD:0:8} (fast-forward)"
assert_eq "$PRHEAD" "$(git rev-parse main)"; assert_grep '^dirty$' .gitignore; git checkout -q .gitignore; git reset -q --hard "$BASE"
git reset -q --hard "$BASE"; echo mine > change.txt                        # a file the merge changes, edited here: left alone
out="$(ff_merge)"; assert_contains "$out" "Local main: 1 file(s) here differ from the merged copy; left at ${BASE:0:8}:"
assert_contains "$out" $'\n  change.txt\n  Commit or move them, then run: git pull  (in the Cockpit Terminal, type su first)'
assert_eq "$BASE" "$(git rev-parse main)"; assert_eq mine "$(cat change.txt)"; rm change.txt
git checkout -q -b side                                                    # main checked out nowhere: the ref moves
out="$(ff_merge)"; assert_contains "$out" "Local main: ${BASE:0:8} -> ${PRHEAD:0:8} (fast-forward)"
assert_eq "$PRHEAD" "$(git rev-parse main)"; assert_eq side "$(git branch --show-current)"
git branch -qf main "$BASE"   # t-41ff: a git failure in the local update (set -e) still lets merge-pr record merged: and exit 0
out="$(STUB_UPDATE_REF_FAIL=1 ff_merge)"; assert_contains "$out" "Local main: git refused to move it; left at ${BASE:0:8}. Update it by hand: git pull"
assert_eq "$BASE" "$(git rev-parse main)"; assert_grep '^merged: mergesha' "$f"; git branch -qf main "$PRHEAD"
git branch -qf main "$BASE"; git worktree add -q "$W/wt" main              # main checked out in another worktree: left alone
out="$(ff_merge)"; assert_contains "$out" "Local main: checked out in $(cd "$W/wt" && pwd -P); left at ${BASE:0:8}. Update it there: git pull"
assert_eq "$BASE" "$(git rev-parse main)"; git worktree remove -f "$W/wt"
git checkout -q main; echo local > local.txt; git add local.txt; git commit -qm "local only"; LOCAL="$(git rev-parse HEAD)"
out="$(ff_merge)"; assert_contains "$out" "Local main: has commits origin/main lacks, not a fast-forward; left at ${LOCAL:0:8}"
assert_eq "$LOCAL" "$(git rev-parse main)"; git reset -q --hard "$BASE"
# The merge happened, so merge-pr exits 0 whatever the local branch could do (ff_merge runs under set -e).
git reset -q --hard "$PRHEAD"; out="$(ff_merge)"; assert_contains "$out" "Local main: already at ${PRHEAD:0:8}"
git reset -q --hard "$BASE"; out="$(STUB_FF_FETCH_FAIL=1 ff_merge)"; assert_contains "$out" "Local main: could not fetch origin/main; update it by hand: git pull"
assert_eq "$BASE" "$(git rev-parse main)"
git checkout -q -B side; git branch -qD main; out="$(ff_merge)"; assert_contains "$out" "Local main: none here; nothing to update"
git checkout -q -B main "$BASE"

# t-41ff: the PR carries files canon already wrote here (import-results): identical ones, this ticket's ticket.md (local
# fields aside) and the audit log are set aside, main fast-forwards, and the local fields and log lines come back. Any
# other difference leaves every file and main as they were. Protects `tkt merge-pr` and the board's Check & merge.
B="$W/build"; git clone -q "$W/origin.git" "$B" 2>/dev/null; git -C "$B" checkout -q "$BASE"
echo change > "$B/change.txt"; echo same > "$B/new.txt"; mkdir -p "$B/.claude"; printf 'a\nb\n' > "$B/.claude/subagent-runs.jsonl"
# also: a file in a folder that is not here (no blocker), a tracked file it changes, and a near miss of the log's name
mkdir -p "$B/newdir"; echo n > "$B/newdir/x.txt"; printf '#!/usr/bin/env bash\necho merged\n' > "$B/scripts/test.sh"; echo theirs > "$B/.claude/subagent-runs.jsonl.bak"
git -C "$B" add -f change.txt new.txt newdir/x.txt scripts/test.sh .claude/subagent-runs.jsonl .claude/subagent-runs.jsonl.bak; git -C "$B" commit -qm graded; G="$(git -C "$B" rev-parse HEAD)"
eval_ok "$G"; mkdir -p "$B/.tickets/$id"; cp ".tickets/$id/eval-report.md" "$B/.tickets/$id/"
sed '/^github: /d; /^merged: /d' "$f" > "$B/.tickets/$id/ticket.md"; printf 'c' >> "$B/.claude/subagent-runs.jsonl"   # no final newline
git -C "$B" add -f .tickets .claude/subagent-runs.jsonl; git -C "$B" commit -qm "late docs"; H="$(git -C "$B" rev-parse HEAD)"
git -C "$B" checkout -q "$G"; git -C "$B" checkout -q "$H" -- .tickets .claude/subagent-runs.jsonl; printf '\n' >> "$B/.claude/subagent-runs.jsonl"; git -C "$B" add -f .tickets .claude/subagent-runs.jsonl
git -C "$B" commit -qm "late docs, log with a final newline"; H3="$(git -C "$B" rev-parse HEAD)"; git -C "$B" checkout -q "$H"
git -C "$B" push -qf origin "HEAD:refs/pull/7/head"
recon_setup() {   # main at the base (mixed reset: --hard would delete the ticket files H tracks); canon's copies as import-results leaves them, plus an unrelated edit
  git checkout -q main; git reset -q "$BASE"; git checkout -q -- .gitignore scripts/test.sh; rm -rf change.txt newdir .claude/subagent-runs.jsonl.bak; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
  echo same > new.txt; mkdir -p .claude; printf 'a\nlocal1\nb\n' > .claude/subagent-runs.jsonl; echo dirty >> .gitignore
}
tree_sig() { cksum new.txt .claude/subagent-runs.jsonl .gitignore ".tickets/$id/eval-report.md" "$f"; }
recon_setup; cp "$f" "$W/ticket.before"
out="$(STUB_HEAD="$H" ff_merge)"
assert_contains "$out" "Local main: ${BASE:0:8} -> ${H:0:8} (fast-forward)"; assert_eq "$H" "$(git rev-parse main)"
assert_eq "$(cat "$W/ticket.before")" "$(sed '/^merged: mergesha0\{34\}$/d' "$f")"; assert_grep '^merged: mergesha' "$f"   # the local fields kept, plus merged:
printf 'a\nb\nc\nlocal1\n' | cmp -s - .claude/subagent-runs.jsonl || fail "audit log: $(od -c .claude/subagent-runs.jsonl)"   # merged copy had no final newline
assert_eq same "$(cat new.txt)"; assert_eq n "$(cat newdir/x.txt)"; assert_contains "$(cat scripts/test.sh)" "echo merged"
assert_grep '^dirty$' .gitignore; assert_grep '— merged$' ".tickets/$id/github.md"; assert_grep '^merge commit: mergesha' ".tickets/$id/github.md"
assert_eq 0 "$(find "$TMPDIR" -maxdepth 1 -name 'tkt-ff.*' | grep -c . || true)"   # the set-aside copies are removed
git checkout -q .gitignore
# The merged log ends with a newline: no blank line before the local ones.
recon_setup; git -C "$B" push -qf origin "$H3:refs/pull/7/head"; out="$(STUB_HEAD="$H3" ff_merge)"; assert_contains "$out" "(fast-forward)"
printf 'a\nb\nc\nlocal1\n' | cmp -s - .claude/subagent-runs.jsonl || fail "audit log after a newline-ended copy: $(od -c .claude/subagent-runs.jsonl)"
git -C "$B" push -qf origin "$H:refs/pull/7/head"
# A tracked file edited here to exactly the merged copy is set aside too.
recon_setup; git show "$H:scripts/test.sh" > scripts/test.sh; out="$(STUB_HEAD="$H" ff_merge)"; assert_contains "$out" "Local main: ${BASE:0:8} -> ${H:0:8} (fast-forward)"
assert_eq "" "$(git status --porcelain --untracked-files=no -- scripts/test.sh)"
# Not identical: an untracked file, or ticket.md's title (the near miss of the field rule). Nothing changes; each is named.
recon_setup; echo other > new.txt; before="$(tree_sig)"
out="$(STUB_HEAD="$H" ff_merge)"; assert_contains "$out" "Local main: 1 file(s) here differ from the merged copy; left at ${BASE:0:8}:"
assert_contains "$out" $'\n  new.txt\n  Commit or move them, then run: git pull  (in the Cockpit Terminal, type su first)'; [[ "$out" != *"(fast-forward)"* ]] || fail "a refused update still printed a fast-forward: $out"
assert_eq "$BASE" "$(git rev-parse main)"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; assert_eq "$before" "$(tree_sig)"
recon_setup; sed -i.bak 's/^# Cloud ticket$/# Cloud ticket, renamed here/' "$f" && rm -f "$f.bak"; assert_grep '^# Cloud ticket, renamed here$' "$f"; before="$(tree_sig)"
out="$(STUB_HEAD="$H" ff_merge)"; assert_contains "$out" $'\n  .tickets/'"$id"$'/ticket.md\n  Commit or move them'
assert_eq "$BASE" "$(git rev-parse main)"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; assert_eq "$before" "$(tree_sig)"
sed -i.bak 's/^# Cloud ticket, renamed here$/# Cloud ticket/' "$f" && rm -f "$f.bak"
# Staged, a symlink here (even to identical text), or a near miss of the log's name: each differs.
recon_setup; git add -f new.txt; out="$(STUB_HEAD="$H" ff_merge)"; assert_contains "$out" $'\n  new.txt (staged)\n'; [[ "$out" != *"(fast-forward)"* ]] || fail "a refused update still printed a fast-forward: $out"
assert_eq "$BASE" "$(git rev-parse main)"; git reset -q -- new.txt
recon_setup; rm new.txt; echo same > "$W/same.txt"; ln -s "$W/same.txt" new.txt; out="$(STUB_HEAD="$H" ff_merge)"
assert_contains "$out" $'\n  new.txt\n'; [[ -L new.txt ]] || fail "the local symlink was replaced"; assert_eq "$BASE" "$(git rev-parse main)"; rm new.txt
recon_setup; echo mine > .claude/subagent-runs.jsonl.bak; out="$(STUB_HEAD="$H" ff_merge)"
assert_contains "$out" $'\n  .claude/subagent-runs.jsonl.bak\n'; assert_eq mine "$(cat .claude/subagent-runs.jsonl.bak)"; assert_eq "$BASE" "$(git rev-parse main)"
# A PR path under a folder that is a symlink here is never followed: the file outside the repo stays (t-07b5: PR paths are untrusted).
git -C "$B" checkout -q "$BASE"; mkdir -p "$B/lnk"; echo same2 > "$B/lnk/new2.txt"; git -C "$B" add lnk/new2.txt; git -C "$B" commit -qm "under a link"
H2="$(git -C "$B" rev-parse HEAD)"; git -C "$B" push -qf origin "HEAD:refs/pull/7/head"; eval_ok "$H2"
recon_setup; mkdir -p "$W/outside"; echo same2 > "$W/outside/new2.txt"; ln -s "$W/outside" lnk
out="$(STUB_HEAD="$H2" ff_merge)"; assert_contains "$out" $'\n  lnk/new2.txt (inside a symlinked folder)\n  Commit or move them'
assert_eq "$BASE" "$(git rev-parse main)"; assert_eq same2 "$(cat "$W/outside/new2.txt")"
rm lnk; git -C "$B" push -qf origin "$H:refs/pull/7/head"; eval_ok "$G"
# git refuses after the files were set aside: each comes back byte for byte, main stays.
recon_setup; before="$(tree_sig)"
out="$(STUB_HEAD="$H" STUB_FF_MERGE_FAIL=1 ff_merge)"
assert_contains "$out" "Local main: git refused the fast-forward; left at ${BASE:0:8}, every file set aside put back. Update it by hand: git pull"
assert_eq 0 "$(find "$TMPDIR" -maxdepth 1 -name 'tkt-ff.*' | grep -c . || true)"   # the set-aside copies are removed here too
assert_contains "$out" "  git: error: forced ff failure"; [[ "$out" != *"(fast-forward)"* ]] || fail "a refused update still printed a fast-forward: $out"
assert_eq "$BASE" "$(git rev-parse main)"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; assert_eq "$before" "$(tree_sig)"
# A log with no local-only lines comes out byte-identical to the merged copy (no newline added to one that lacks it).
recon_setup; printf 'a\nb\n' > .claude/subagent-runs.jsonl; out="$(STUB_HEAD="$H" ff_merge)"; assert_contains "$out" "(fast-forward)"
printf 'a\nb\nc' | cmp -s - .claude/subagent-runs.jsonl || fail "a log with nothing local changed: $(od -c .claude/subagent-runs.jsonl)"
git checkout -q .gitignore scripts/test.sh; rm -rf new.txt newdir .claude; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
# A PR path is matched literally (t-07b5: untrusted): a tracked file named '*' never stands for every file, so the
# unrelated edit to .gitignore survives the set-aside of '*'.
git -C "$B" checkout -q "$BASE"; echo x > "$B/*"; git -C "$B" add -- ':(literal)*'; git -C "$B" commit -qm "star"; BASE2="$(git -C "$B" rev-parse HEAD)"
echo y > "$B/*"; git -C "$B" add -- ':(literal)*'; git -C "$B" commit -qm "star changed"; H4="$(git -C "$B" rev-parse HEAD)"
git -C "$B" push -qf origin "$BASE2:refs/heads/star-base" "$H4:refs/pull/7/head"; git fetch -q origin refs/heads/star-base; eval_ok "$H4"
git checkout -q main; git reset -q "$BASE2"; git checkout -q -- .; echo y > '*'; echo dirty >> .gitignore   # mixed: main is at H, which tracks the ticket files
out="$(BASE="$BASE2" STUB_HEAD="$H4" ff_merge)"; assert_contains "$out" "Local main: ${BASE2:0:8} -> ${H4:0:8} (fast-forward)"
assert_grep '^dirty$' .gitignore; assert_eq y "$(cat '*')"
git checkout -q .gitignore; git reset -q --hard "$BASE"; sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; eval_ok "$PRHEAD"
git push -qf origin "$PRHEAD:refs/pull/7/head"; git --git-dir="$W/origin.git" update-ref refs/heads/main "$BASE"

# t-4718 also fixed import-results: a ticket that comes back without eval-report.md is reported, not a silent exit.
other="t-0e0e"; X="$W/cloud"; git clone -q "$W/origin.git" "$X" 2>/dev/null
mkdir -p "$X/.tickets/$other"; printf -- '---\nid: %s\nstatus: closed\ntype: task\npriority: 2\n---\n# Back\n' "$other" > "$X/.tickets/$other/ticket.md"
git -C "$X" add -f ".tickets/$other/ticket.md" && git -C "$X" commit -qm results && git -C "$X" push -q origin "HEAD:refs/heads/canon-results/$other"
out="$("$TKT" import-results "$other" 2>&1)" || true
assert_contains "$out" "evaluator: no eval-report.md  graded-head: none"

echo "tkt-merge-pr: ok"

# t-fefb: GitHub's mergeable UNKNOWN (right after another PR merged) is waited out; every other refusal stays immediate.
mkdir "$W/sbin"; printf '#!/usr/bin/env bash\necho "$*" >> "$STUB_W/sleeps"\n' > "$W/sbin/sleep"; chmod +x "$W/sbin/sleep"
PATH="$W/sbin:$PATH"   # from here on; earlier tests need the real sleep
reads() { cat "$W/reads" 2>/dev/null || echo 0; }
nsleeps() { grep -c '^5$' "$W/sleeps" 2>/dev/null || true; }
printf 'UNKNOWN UNKNOWN\nUNKNOWN UNKNOWN\nMERGEABLE CLEAN\n' > "$W/script"; rm -f "$W/reads" "$W/sleeps"; : > "$STUB_LOG"
rc=0; out="$(STUB_SCRIPT="$W/script" "$TKT" merge-pr "$id" --pr 7 --check 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "UNKNOWN twice then MERGEABLE should pass --check (rc $rc): $out"
[[ "$(reads)" == 3 && "$(nsleeps)" == 2 ]] || fail "expected 3 reads and 2 sleeps, got $(reads) and $(nsleeps)"
assert_contains "$out" "merge-pr: PR #7 mergeable state is UNKNOWN; reading it again (2/6)…"
assert_contains "$out" "(3/6)…"
printf 'UNKNOWN UNKNOWN\n' > "$W/script"; rm -f "$W/reads" "$W/sleeps"
refuses "a PR that stays UNKNOWN" "merge-pr: PR #7 cannot merge cleanly (mergeable: UNKNOWN, state: UNKNOWN)" STUB_SCRIPT="$W/script" -- --yes
[[ "$(reads)" == 6 && "$(nsleeps)" == 5 ]] || fail "expected 6 reads and 5 sleeps, got $(reads) and $(nsleeps)"
for pair in "CONFLICTING DIRTY" "MERGEABLE BLOCKED"; do
  printf '%s\nMERGEABLE CLEAN\n' "$pair" > "$W/script"; rm -f "$W/reads" "$W/sleeps"
  refuses "a $pair PR without waiting" "merge-pr: PR #7" STUB_SCRIPT="$W/script" -- --yes
  [[ "$(reads)" == 1 && ! -e "$W/sleeps" ]] || fail "$pair should read once and not sleep"
done
# A gh failure on the read is still a refusal, not a wait.
rm -f "$W/reads" "$W/sleeps"
refuses "a PR gh cannot read" "gh could not read PR #7 on acme/app: HTTP 502" STUB_VIEW_FAIL=1 -- --yes
