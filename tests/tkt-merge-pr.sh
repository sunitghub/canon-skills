#!/usr/bin/env bash
# t-4718: tkt merge-pr checks a cloud ticket's PR (evaluator passed on its head; open, own repo, mergeable, clean; the test
# command green on base + PR in a scratch clone), asks, then merges with --match-head-commit from outside any checkout.
# Every refusal makes no merge call and leaves ticket.md byte-identical.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-merge-pr.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com
# origin is https://github.com/acme/app.git as far as tkt can tell; pushes land in a bare repo, which also holds the PR ref
# GitHub would. A git shim (on PATH below) sends a fetch of that URL, or of the remote origin, to the bare repo, so
# `remote get-url` stays real and nothing reaches the network.
git init -q --bare "$W/origin.git"
git config --global url."$W/origin.git".pushInsteadOf https://github.com/acme/app.git

P="$W/project"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
git remote set-url origin https://github.com/acme/app.git
# The suite leaves $STUB_W/ran behind, so a test can tell whether the PR's code ran at all.
mkdir -p scripts; printf '#!/usr/bin/env bash\ntouch "$STUB_W/ran"\n[ -e FAIL ] && { echo "suite: 1 failed"; exit 1; }\necho "suite: ok"\n' > scripts/test.sh; chmod +x scripts/test.sh
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
  "pr view")  if [[ "$*" == *mergeCommit* ]]; then   # STUB_NO_SHA: GitHub has no merge commit; gh's --jq then prints "null" unless "// empty"
                if [[ -z "${STUB_NO_SHA:-}" ]]; then echo "mergesha0000000000000000000000000000000000"; elif [[ "$*" != *"// empty"* ]]; then echo null; fi
                exit 0; fi
              if [[ "$*" == *"--json state --jq"* ]]; then echo "${STUB_AFTER:-OPEN}"; exit 0; fi
              printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${STUB_STATE:-OPEN}" "${STUB_MG:-MERGEABLE}" "${STUB_MS:-CLEAN}" \
                "${STUB_HEAD:?}" main "${STUB_CROSS:-false}" ;;
  "pr merge") printf 'cwd %s\n' "$PWD" >> "$STUB_LOG"; [[ -n "${STUB_MERGE_FAIL:-}" ]] && { echo "could not delete branch" >&2; exit 1; }; exit 0 ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$W/bin/gh"
REAL_GIT="$(command -v git)"
cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" fetch "* ]]; then a=(); for x in "\$@"; do [[ "\$x" == https://github.com/acme/app.git || "\$x" == origin ]] && x="$W/origin.git"; a+=("\$x"); done; set -- "\${a[@]}"; fi
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
rm ".tickets/$id/eval-report.md"
refuses "no eval-report.md" "no passing evaluator verdict" -- --yes
eval_ok 0123456789abcdef0123456789abcdef01234567
refuses "a head the evaluator did not grade" "is not the commit the evaluator graded" -- --yes
eval_ok
refuses "a closed PR" "is CLOSED, not open" STUB_STATE=CLOSED -- --yes
refuses "a fork's PR" "comes from a fork" STUB_CROSS=true -- --yes
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
git reset -q --hard "$PRHEAD"; git push -q -f origin "HEAD:refs/pull/7/head"; git checkout -q main; eval_ok
# --test overrides the default: a failing command refuses.
refuses "a failing --test command" "false failed" -- --test false --yes
# No terminal and no --yes: refused before any of the PR's code runs.
rm -f "$W/ran"; refuses "no terminal without --yes" "no terminal to ask on" --
[[ ! -e "$W/ran" ]] || fail "the PR's tests ran before anyone said yes"
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
out="$(tty_run y "$TKT" merge-pr "$id" 2>&1)" || fail "merge-pr with y failed: $out"
assert_contains "$out" "running scripts/test.sh on main + PR #7"
assert_contains "$out" "Merged PR #7 into main"
grep -qx "pr merge 7 --repo acme/app --merge --delete-branch --match-head-commit $PRHEAD" "$STUB_LOG" || fail "wrong merge call: $(cat "$STUB_LOG")"
assert_eq "/" "$(sed -n 's/^cwd //p' "$STUB_LOG")"   # never inside a checkout, so --delete-branch cannot touch local branches
assert_grep '^merged: mergesha0000000000000000000000000000000000$' "$f"
grep -q '^pr list' "$STUB_LOG" || fail "the PR was not found by its Fixes line"

# --yes, --pr and no test command: merges on the gates alone and says so.
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"; git rm -q scripts/test.sh; git commit -qm "no suite"; git push -q origin HEAD:main
: > "$STUB_LOG"; out="$("$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "merge-pr --yes failed: $out"
assert_contains "$out" "No test command (pass --test). Merge PR #7 into main on the gates alone? yes (--yes)"
grep -q '^pr list' "$STUB_LOG" && fail "--pr still searched for the PR"
grep -q '^pr merge 7 ' "$STUB_LOG" || fail "--yes did not merge"

# gh fails after GitHub merged (the branch delete, say): recorded as merged, with gh's message; no sha → no "null".
sed -i.bak '/^merged: /d' "$f" && rm -f "$f.bak"
out="$(STUB_MERGE_FAIL=1 STUB_AFTER=MERGED STUB_NO_SHA=1 "$TKT" merge-pr "$id" --pr 7 --yes 2>&1)" || fail "a merge GitHub made was reported as a failure: $out"
assert_contains "$out" "Merged PR #7 into main (gh reported: could not delete branch)"
assert_grep '^merged: PR #7$' "$f"

# t-4718 also fixed import-results: a ticket that comes back without eval-report.md is reported, not a silent exit.
other="t-0e0e"; X="$W/cloud"; git clone -q "$W/origin.git" "$X" 2>/dev/null
mkdir -p "$X/.tickets/$other"; printf -- '---\nid: %s\nstatus: closed\ntype: task\npriority: 2\n---\n# Back\n' "$other" > "$X/.tickets/$other/ticket.md"
git -C "$X" add -f ".tickets/$other/ticket.md" && git -C "$X" commit -qm results && git -C "$X" push -q origin "HEAD:refs/heads/canon-results/$other"
out="$("$TKT" import-results "$other" 2>&1)" || true
assert_contains "$out" "evaluator: no eval-report.md  graded-head: none"

echo "tkt-merge-pr: ok"
