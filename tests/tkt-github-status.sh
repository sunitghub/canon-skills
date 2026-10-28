#!/usr/bin/env bash
# t-d271: tkt github-status reports where a ticket sent to GitHub stands (sent → pr-open → results-ready → results-in →
# merged) from one gh read and one ls-remote, read-only; a gh or origin failure exits 1 with the reason.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main
git init -q --bare "$W/origin.git"; P="$W/p"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
printf '.tickets/\n' > .gitignore; git add .gitignore; git commit -qm init; git push -q origin HEAD:main
id="$("$TKT" create "Out on GitHub")"; f=".tickets/$id/ticket.md"
awk '/^---$/ && ++n == 2 { print "github: acme/app#23" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"
HEAD7="$(git rev-parse HEAD)"   # a real local commit: github-status reads the commits after a graded head (t-c8d4)
mkdir "$W/bin"; cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[[ -n "${STUB_FAIL:-}" ]] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
# t-24b1: the session-branch search. graphql prints what --jq would (default branch, then candidates); compare prints
# true/false from cmp; a pr list --head prints the PR count from headprs.
[[ "$1 $2" == "api graphql" && -n "${STUB_GQLFAIL:-}" ]] && { echo "HTTP 502: graphql" >&2; exit 1; }
[[ "$1 $2" == "api graphql" ]] && { cat "$STUB_W/graphql" 2>/dev/null || echo main; exit 0; }
[[ "$1 $2" == "api repos/acme/app/compare/"* && -n "${STUB_CMPFAIL:-}" ]] && { echo "HTTP 502: compare" >&2; exit 1; }
[[ "$1 $2" == "pr list" && " $* " == *" --head "* && -n "${STUB_HEADFAIL:-}" ]] && { echo "HTTP 502: head prs" >&2; exit 1; }
[[ "$1 $2" == "api repos/acme/app/compare/"* ]] && { cat "$STUB_W/cmp" 2>/dev/null || echo false; exit 0; }
[[ "$1 $2" == "pr list" && " $* " == *" --head "* ]] && { cat "$STUB_W/headprs" 2>/dev/null || echo 0; exit 0; }
[[ "$1 $2" == "pr list" ]] && { cat "$STUB_W/prs"; exit 0; }
echo "unexpected gh call: $*" >&2; exit 9
SH
chmod +x "$W/bin/gh"; export PATH="$W/bin:$PATH" STUB_LOG="$W/log" STUB_W="$W"
st() { "$TKT" github-status "$id" --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write([j.stage,j.pr,j.pr_state,j.results_branch,j.verdict,j.graded_matches_pr].join("|"))'; }

: > "$W/prs";                                   assert_eq "sent|||false||false" "$(st)"
printf '24\tOPEN\t%s\n' "$HEAD7" > "$W/prs";    assert_eq "pr-open|24|OPEN|false||false" "$(st)"
git push -q origin "HEAD:refs/heads/canon-results/$id"
                                                assert_eq "results-ready|24|OPEN|true||false" "$(st)"
# Imported: the evaluator passed on the PR's head and the ticket closed; the results branch is gone.
git push -q origin --delete "canon-results/$id"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\npass: all met\n' "$HEAD7" > ".tickets/$id/eval-report.md"
sed -i.bak 's/^status: open$/status: closed/' "$f" && rm -f "$f.bak"
                                                assert_eq "results-in|24|OPEN|false|pass|true" "$(st)"
# A verdict on another head is not results-in.
printf 'evaluator-run-id: 1-1\ngraded-head: ffffffffffffffffffffffffffffffffffffffff\npass: all met\n' > ".tickets/$id/eval-report.md"
                                                assert_eq "pr-open|24|OPEN|false|pass|false" "$(st)"
# t-c259: imported (eval-report.md here), still open, PR open: land is offered; closed, or no report, it is not.
land() { "$TKT" github-status "$id" --json | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).land))'; }
assert_eq false "$(land)"
sed -i.bak 's/^status: closed$/status: open/' "$f" && rm -f "$f.bak";  assert_eq true "$(land)"
mv ".tickets/$id/eval-report.md" "$W/er";                              assert_eq false "$(land)"
printf '24\tMERGED\t%s\n' "$HEAD7" > "$W/prs"; mv "$W/er" ".tickets/$id/eval-report.md"; assert_eq false "$(land)"
printf '24\tOPEN\t%s\n' "$HEAD7" > "$W/prs"
sed -i.bak 's/^status: open$/status: closed/' "$f" && rm -f "$f.bak"
# t-6623: landed is the land worktree's path once tkt land made it (.land-head and the directory), else null.
landed() { "$TKT" github-status "$id" --json | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).landed))'; }
LWT="$(cd "$(git rev-parse --show-toplevel)/.." && pwd -P)/$(basename "$(git rev-parse --show-toplevel)")-worktrees/land-$id"
assert_eq null "$(landed)"
echo "$HEAD7" > ".tickets/$id/.land-head"; assert_eq null "$(landed)"
mkdir -p "$LWT"; assert_eq "$LWT" "$(landed)"
rm ".tickets/$id/.land-head"; assert_eq null "$(landed)"   # a directory alone is not a land worktree
rm -rf "$LWT"; assert_eq null "$(landed)"
# t-c8d4: graded-head plus late docs only (the cloud's learnings sweep) is results-in, as merge-pr accepts it; a code change
# after the graded head is not. The commits are made in another clone, so github-status has to fetch the PR head.
git clone -q "$W/origin.git" "$W/c" 2>/dev/null
echo a > "$W/c/src.txt"; git -C "$W/c" add src.txt; git -C "$W/c" commit -qm graded; G="$(git -C "$W/c" rev-parse HEAD)"
echo row > "$W/c/LEARNINGS.md"; git -C "$W/c" add LEARNINGS.md; git -C "$W/c" commit -qm sweep; L="$(git -C "$W/c" rev-parse HEAD)"
git -C "$W/c" push -q origin "$L:refs/pull/24/head"
printf 'evaluator-run-id: 1-1\ngraded-head: %s\npass: all met\n' "$G" > ".tickets/$id/eval-report.md"
printf '24\tOPEN\t%s\n' "$L" > "$W/prs";       assert_eq "results-in|24|OPEN|false|pass|false" "$(st)"
assert_contains "$("$TKT" github-status "$id")" "(the PR head plus late docs)"
echo b > "$W/c/src.txt"; git -C "$W/c" commit -qam code; X="$(git -C "$W/c" rev-parse HEAD)"
git -C "$W/c" push -q origin "+$X:refs/pull/24/head"
printf '24\tOPEN\t%s\n' "$X" > "$W/prs";       assert_eq "pr-open|24|OPEN|false|pass|false" "$(st)"
# A head that is not local and cannot be fetched exits 1, never a guessed stage.
git -C "$W/c" push -q origin --delete refs/pull/24/head
printf '24\tOPEN\t%s\n' 0123456789abcdef0123456789abcdef01234567 > "$W/prs"; rc=0; out="$("$TKT" github-status "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unfetchable PR head should exit 1"; assert_contains "$out" "could not fetch PR #24's head"
printf 'evaluator-run-id: 1-1\ngraded-head: ffffffffffffffffffffffffffffffffffffffff\npass: all met\n' > ".tickets/$id/eval-report.md"
# Merged: by GitHub's PR state, or by the ticket's merged: line.
printf '24\tMERGED\t%s\n' "$HEAD7" > "$W/prs";  assert_eq "merged|24|MERGED|false|pass|false" "$(st)"
printf '24\tCLOSED\t%s\n25\tOPEN\t%s\n' "$HEAD7" "$HEAD7" > "$W/prs"; assert_eq "25" "$(st | cut -d'|' -f2)"   # the open one wins
# Read-only: only a pr list call, and the ticket is unchanged.
: > "$W/log"; before="$(cksum < "$f")"; st >/dev/null
assert_eq "1" "$(grep -c . "$W/log")"; grep -q '^pr list --repo acme/app --state all --search Fixes #23 in:body' "$W/log" || fail "wrong gh call: $(cat "$W/log")"
[[ "$(cksum < "$f")" == "$before" ]] || fail "github-status changed the ticket"
# Failures: gh, origin, not sent.
rc=0; out="$(STUB_FAIL=1 "$TKT" github-status "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a gh failure should exit 1"; assert_contains "$out" "Bad credentials"
git remote set-url origin "$W/nope.git"; rc=0; out="$("$TKT" github-status "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unreadable origin should exit 1, not guess a stage"; assert_contains "$out" "could not read origin"
git remote set-url origin "$W/origin.git"
id2="$("$TKT" create "Local only")"; rc=0; out="$("$TKT" github-status "$id2" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unsent ticket should exit 1"; assert_contains "$out" "was not sent to GitHub"
assert_contains "$("$TKT" github-status "$id")" "$id · acme/app#23 ·"
# t-07b5: a tracked .tickets/ has no results branch: the closed ticket rides in the PR's head, so that head is where to look.
# Protects: the Factory card's poll (Import results for a project that commits .tickets/).
sed -i.bak 's/^status: closed$/status: open/' "$f" && rm -f "$f.bak" ".tickets/$id/eval-report.md"
mkdir -p "$W/c/.tickets/$id"; sed 's/^status: .*$/status: closed/' "$f" > "$W/c/.tickets/$id/ticket.md"
git -C "$W/c" add -f ".tickets/$id/ticket.md"; git -C "$W/c" commit -qm "cloud close"; TR="$(git -C "$W/c" rev-parse HEAD)"
git -C "$W/c" push -q origin "+$TR:refs/pull/24/head"
printf '24\tOPEN\t%s\n' "$TR" > "$W/prs";       assert_eq "results-ready|24|OPEN|false||false" "$(st)"
assert_contains "$("$TKT" github-status "$id")" "tkt import-results $id --pr 24"
printf '24\tCLOSED\t%s\n' "$TR" > "$W/prs";     assert_eq "pr-open|24|CLOSED|false||false" "$(st)"   # only an open PR offers it
sed -i.bak 's/^status: closed$/status: open/' "$W/c/.tickets/$id/ticket.md" && rm -f "$W/c/.tickets/$id/ticket.md.bak"
git -C "$W/c" commit -qam "still open"; TO="$(git -C "$W/c" rev-parse HEAD)"; git -C "$W/c" push -q origin "+$TO:refs/pull/24/head"
printf '24\tOPEN\t%s\n' "$TO" > "$W/prs";       assert_eq "pr-open|24|OPEN|false||false" "$(st)"   # an unclosed ticket in the head is not a result
git -C "$W/c" rm -q -r --cached ".tickets"; git -C "$W/c" commit -qm "no ticket"; TN="$(git -C "$W/c" rev-parse HEAD)"; git -C "$W/c" push -q origin "+$TN:refs/pull/24/head"
printf '24\tOPEN\t%s\n' "$TN" > "$W/prs";       assert_eq "pr-open|24|OPEN|false||false" "$(st)"   # no ticket in the head at all
git -C "$W/c" push -q origin --delete refs/pull/24/head; printf '' > "$W/prs"
# t-24b1: a branch the session pushed without a PR (#41). Only while the stage would be "sent".
printf '' > "$W/prs"; sed -i.bak 's/^status: closed$/status: open/' "$f" && rm -f "$f.bak" ".tickets/$id/eval-report.md"
bs() { "$TKT" github-status "$id" --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write([j.stage,j.branch,JSON.stringify(j.mirrors)].join("|"))'; }
printf 'main\n--repo=evil/x\nclaude/brave-x1\n' > "$W/graphql"; echo true > "$W/cmp"; echo 0 > "$W/headprs"   # a name that reads as an option is skipped
: > "$W/log";                                   assert_eq "branch|claude/brave-x1|[]" "$(bs)"
grep -q '^api repos/acme/app/compare/main...claude/brave-x1 ' "$W/log" || fail "the candidate was not compared with the default branch: $(cat "$W/log")"
! grep -q -- '--repo=evil' "$W/log" || fail "a branch name that reads as an option reached gh: $(cat "$W/log")"
grep -q '^pr list --repo acme/app --head claude/brave-x1 --state all' "$W/log" || fail "the candidate's PRs were not checked: $(cat "$W/log")"
# The search asks about this repo and this ticket (the stub cannot run --jq, so the arguments are checked instead).
gq="$(grep '^api graphql ' "$W/log")"; assert_contains "$gq" "-f o=acme -f n=app --jq"; assert_contains "$gq" "test(\"\\\\b$id\\\\b\")"
assert_contains "$(grep '^api repos/acme/app/compare/' "$W/log")" "test(\"\\\\b$id\\\\b\")"
assert_contains "$("$TKT" github-status "$id")" "claude/brave-x1 is on origin with no PR: tkt open-pr $id"
echo false > "$W/cmp";                          assert_eq "sent||[]" "$(bs)"     # its commit naming the id is on main
[[ "$("$TKT" github-status "$id")" != *"with no PR"* ]] || fail "the plain form named a branch for a sent ticket"
echo true > "$W/cmp"; echo 1 > "$W/headprs";    assert_eq "sent||[]" "$(bs)"     # it already has a PR (any state)
echo 0 > "$W/headprs"; printf '24\tOPEN\t%s\n' "$HEAD7" > "$W/prs"
: > "$W/log";                                   assert_eq "pr-open||[]" "$(bs)"   # a Fixes PR exists: no branch search
! grep -q '^api graphql' "$W/log" || fail "searched for a session branch with a PR open"
printf '' > "$W/prs"; rc=0; out="$(STUB_GQLFAIL=1 "$TKT" github-status "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a gh failure in the branch search should exit 1, not read as no branch"; assert_contains "$out" "HTTP 502: graphql"
for v in STUB_CMPFAIL STUB_HEADFAIL; do
  rc=0; out="$(env "$v=1" "$TKT" github-status "$id" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "$v: a gh failure while checking the candidate should exit 1, not read as no branch"; assert_contains "$out" "HTTP 502"
done
# Mirrors come from git config canon.mirror, in order.
git config --add canon.mirror public; git config --add canon.mirror backup
assert_eq "branch|claude/brave-x1|[\"public\",\"backup\"]" "$(bs)"
echo "tkt-github-status: ok"
