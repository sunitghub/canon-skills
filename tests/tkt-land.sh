#!/usr/bin/env bash
# t-c259: tkt land closes an imported cloud ticket here (the `tkt land` command, and the board's Close here button that runs it).
# Prepare: a linked worktree on land/<id> at the PR head, the ticket started and bound to it. --finish: only after a closed
# ticket with a passing verdict graded on that worktree's head; it unbinds and removes worktree and branch. Every refusal changes nothing.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tkt-land.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main
git config --global user.name test; git config --global user.email test@example.com
git init -q --bare "$W/origin.git"
git config --global url."$W/origin.git".pushInsteadOf https://github.com/acme/app.git

P="$W/project"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
git remote set-url origin https://github.com/acme/app.git
printf '.tickets/\n' > .gitignore; echo base > f.txt; git add -A; git commit -qm base; git push -q origin HEAD:main
git checkout -q -b claude/pr7; echo change > f.txt; git add f.txt; git commit -qm "the PR"; PRHEAD="$(git rev-parse HEAD)"
git push -q origin "HEAD:refs/pull/7/head"; git checkout -q main

id="$("$TKT" create "Cloud ticket" -t bug)"; f=".tickets/$id/ticket.md"
awk '/^---$/ && ++n == 2 { print "github: acme/app#21" } { print }' "$f" > "$W/t" && mv "$W/t" "$f"
WT="$W/project-worktrees/land-$id"

mkdir "$W/bin"; cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "pr list") cat "$STUB_W/prlist" ;;
  "pr view") printf '%s\t%s\t%s\n' "${STUB_STATE:-OPEN}" "${STUB_HEAD:?}" "${STUB_CROSS:-false}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$W/bin/gh"
REAL_GIT="$(command -v git)"
cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" fetch "* ]]; then a=(); for x in "\$@"; do [[ "\$x" == origin ]] && x="$W/origin.git"; a+=("\$x"); done; set -- "\${a[@]}"; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/bin/git"
export PATH="$W/bin:$PATH" STUB_LOG="$W/gh.log" STUB_W="$W" STUB_HEAD="$PRHEAD"
echo 7 > "$W/prlist"
sig() { { cksum < "$f"; ls "$W/project-worktrees" 2>&1; git branch --list 'land/*'; } | cksum; }

# refuses <label> <message> [env...] -- <args...>: exit 1, the message, and ticket, worktrees and branches unchanged.
refuses() {
  local label="$1" part="$2"; shift 2; local envs=(); while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  local before rc=0; before="$(sig)"
  out="$(env ${envs[@]+"${envs[@]}"} "$TKT" land "$id" "$@" < /dev/null 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "land should refuse $label (rc $rc): $out"
  assert_contains "$out" "$part"
  [[ "$(sig)" == "$before" ]] || fail "land changed state although it refused $label"
  echo "land: refused $label"
}

refuses "a PR from a fork" "comes from a fork" STUB_CROSS=true --
refuses "a closed PR" "is CLOSED, not open" STUB_STATE=CLOSED --
: > "$W/prlist"; refuses "no open PR" "no open PR says" --; echo 7 > "$W/prlist"
refuses "finish before prepare" "is not bound" -- --finish
printf 'graded-head: %s\npass: all met\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
refuses "a PR head that already has a verdict" "nothing to close here" --
rm ".tickets/$id/eval-report.md"
"$TKT" start "$id" >/dev/null
refuses "a ticket that is not open" "not open" --
"$TKT" reopen "$id" >/dev/null 2>&1 || sed -i.bak 's/^status: .*/status: open/' "$f"
grep -q '^status: open' "$f" || fail "test setup: ticket not reopened"

# Prepare.
out="$("$TKT" land "$id" < /dev/null 2>&1)"; assert_contains "$out" "worktree: $WT"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$PRHEAD" ]] || fail "worktree is not at the PR head"
[[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" == "land/$id" ]] || fail "worktree is not on land/$id"
grep -q '^status: in_progress' "$f" || fail "ticket not in_progress"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$WT" ]] || fail ".cockpit-cwd is not the worktree"
refuses "a second land (ticket already started)" "not open" --

# Finish refusals: ticket not closed; closed with a verdict graded elsewhere; both leave the worktree.
refuses "finish of an unclosed ticket" "is not closed yet" -- --finish
sed -i.bak 's/^status: .*/status: closed/' "$f"
printf 'graded-head: 0123456789abcdef0123456789abcdef01234567\npass: all met\n' > ".tickets/$id/eval-report.md"
refuses "finish with a verdict on another head" "no passing evaluator verdict graded on the worktree head" -- --finish
[[ -d "$WT" ]] || fail "worktree removed although finish refused"
printf 'graded-head: %s\npass: all met\n' "$PRHEAD" > ".tickets/$id/eval-report.md"
echo dirty > "$WT/f.txt"
refuses "finish with uncommitted work in the worktree" "worktree kept" -- --finish
git -C "$WT" checkout -q -- f.txt

# Finish.
out="$("$TKT" land "$id" --finish < /dev/null 2>&1)"; assert_contains "$out" "tkt merge-pr $id"
[[ ! -e "$WT" ]] || fail "worktree still there"
git show-ref --verify --quiet "refs/heads/land/$id" && fail "branch land/$id still there"
[[ "$(tr -d '[:space:]' < ".tickets/$id/.cockpit-cwd")" == "$P" ]] || fail ".cockpit-cwd not restored to the earlier binding"
[[ ! -e ".tickets/$id/.cockpit-cwd.before-land" ]] || fail "saved binding left behind"
[[ "$(git ls-remote origin 2>/dev/null)" != *"land/"* ]] || fail "land pushed a branch"
echo "tkt land: ok"
