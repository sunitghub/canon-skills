#!/usr/bin/env bash
# worktree-suites — suites that broke when canon is checked out as a linked worktree (.git is a file) or under a symlinked
# path (macOS /var -> /private/var) must keep passing there (t-1cfc, t-80fc). Builds a copy of canon, a linked worktree of it
# and a symlinked alias of it, and runs the suites that failed in each. A suite that writes under its root must also leave
# the checkout it was started in untouched: skills-uninstall once overwrote .claude/settings.json and deleted the real
# .git/hooks/pre-commit there.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/tmp"

copy_canon_tree "$W/canon"
git -C "$W/canon" init -q
git -C "$W/canon" add -A
git -C "$W/canon" -c user.email=t@t.com -c user.name=t commit -q -m seed
git -C "$W/canon" worktree add -q -b wt "$W/wt"
ln -s "$W/canon" "$W/alias"
[[ -f "$W/wt/.git" ]] || fail "expected the linked worktree to have a .git FILE"

# run_in <dir> <suite>: the suite from <dir> under a pinned environment, GIT_* unset.
run_in() {
  local dir="$1" suite="$2"
  (cd "$dir" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_PREFIX \
    HOME="$W/home" TMPDIR="$W/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    SKILLS_SH_NO_TTY=1 bash "tests/$suite.sh" 2>&1)
}
expect_ok() {
  local dir="$1" suite="$2" out rc=0
  out="$(run_in "$dir" "$suite")" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$suite failed in ${dir#"$W"/}: $(printf '%s' "$out" | tail -3)"
}

# A checkout reached through a symlink: node resolves the physical path, the shell's $PWD is the alias.
expect_ok "$W/alias" install-target

# The headless evaluator finds its repository above a spec file when .git is a file.
expect_ok "$W/wt" sprint-headless-eval-tools

# skills-uninstall from the worktree and from the main copy, with a real-looking hook planted: it must survive, and
# the checkout's settings.json and status must be byte-identical afterwards.
hook="$W/canon/.git/hooks/pre-commit"
mkdir -p "$W/canon/.git/hooks"
printf '#!/usr/bin/env bash\n# canon-managed-pre-commit-hook\necho canary\n' > "$hook"
chmod +x "$hook"
for dir in "$W/wt" "$W/canon"; do
  before_hook="$(cksum < "$hook")"
  before_settings="$(cksum < "$dir/.claude/settings.json")"
  before_status="$(git -C "$dir" status --porcelain)"
  expect_ok "$dir" skills-uninstall
  [[ -f "$hook" ]] || fail "skills-uninstall run from ${dir#"$W"/} deleted the checkout's pre-commit hook"
  assert_eq "$before_hook" "$(cksum < "$hook")"
  assert_eq "$before_settings" "$(cksum < "$dir/.claude/settings.json")"
  assert_eq "$before_status" "$(git -C "$dir" status --porcelain)"
done

printf 'worktree-suites: ok\n'
