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
HEAD7=0123456789abcdef0123456789abcdef01234567
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
# t-24b1: a branch the session pushed without a PR (#41). Only while the stage would be "sent".
printf '' > "$W/prs"; sed -i.bak 's/^status: closed$/status: open/' "$f" && rm -f "$f.bak" ".tickets/$id/eval-report.md"
bs() { "$TKT" github-status "$id" --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write([j.stage,j.branch,JSON.stringify(j.mirrors)].join("|"))'; }
printf 'main\nclaude/brave-x1\n' > "$W/graphql"; echo true > "$W/cmp"; echo 0 > "$W/headprs"
: > "$W/log";                                   assert_eq "branch|claude/brave-x1|[]" "$(bs)"
grep -q '^api repos/acme/app/compare/main...claude/brave-x1 ' "$W/log" || fail "the candidate was not compared with the default branch: $(cat "$W/log")"
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
