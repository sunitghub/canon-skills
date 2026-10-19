#!/usr/bin/env bash
# tkt open-pr (t-24b1): the card's Open PR for a branch a cloud session pushed without a PR (#41). It opens the PR from
# the branch a commit naming the ticket is on, with "Fixes #N" so import-results and merge-pr find it, and creates
# nothing when there is no such branch or gh fails.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main
P="$W/p"; git init -q "$P"; cd "$P"
printf '.tickets/\n' > .gitignore; git add .gitignore; git commit -qm init
id="$("$TKT" create "Export tasks as CSV")"; f=".tickets/$id/ticket.md"
awk '/^---$/ && ++n == 2 { print "github: acme/app#23" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"

# The stub plays the search (graphql, compare, pr list --head, as tkt-github-status.sh's) and logs pr create's argv,
# one argument per line, so the body's newlines stay visible.
mkdir "$W/bin"; cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_W/log"
case "$1 $2" in
  "api graphql") cat "$STUB_W/graphql" ;;
  "api repos/"*) echo true ;;
  "pr list")     echo 0 ;;
  "pr create")   [[ -e "$STUB_W/fail" ]] && { echo "HTTP 422: no commits between" >&2; exit 1; }
                 printf '%s\n' "$@" > "$STUB_W/create"; echo "https://github.com/acme/app/pull/31" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$W/bin/gh"; export PATH="$W/bin:$PATH" STUB_W="$W"

# Found: one pr create, base = the default branch, head = the branch, title and Fixes line.
printf 'trunk\nclaude/brave-x1\n' > "$W/graphql"
out="$("$TKT" open-pr "$id")"
assert_eq "Opened a PR from claude/brave-x1 into trunk: https://github.com/acme/app/pull/31" "$out"
create="$(cat "$W/create")"
assert_contains "$create" $'--base\ntrunk\n--head\nclaude/brave-x1\n--title\n'"$id: Export tasks as CSV"
assert_contains "$create" $'--body\nFixes #23\n\nOpened by canon (tkt open-pr): the cloud session pushed claude/brave-x1 without a PR.'
assert_eq 1 "$(grep -c '^pr create' "$W/log")"

# No such branch: exit 1, nothing created.
printf 'trunk\n' > "$W/graphql"; rm -f "$W/create"; rc=0; out="$("$TKT" open-pr "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "no branch on acme/app has a commit naming $id"; [[ ! -e "$W/create" ]] || fail "opened a PR with no branch"
# gh refuses the PR: exit 1 with gh's words.
printf 'trunk\nclaude/brave-x1\n' > "$W/graphql"; touch "$W/fail"; rc=0; out="$("$TKT" open-pr "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "HTTP 422: no commits between"; rm -f "$W/fail"
# Not sent to GitHub: refused before any gh call.
id2="$("$TKT" create "Local")"; : > "$W/log"; rc=0; out="$("$TKT" open-pr "$id2" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "was not sent to GitHub"; [[ ! -s "$W/log" ]] || fail "called gh for an unsent ticket"
echo "tkt-open-pr: ok"
