#!/usr/bin/env bash
# worktree-suites — suites that broke when canon is checked out as a linked worktree (.git is a file) or under a symlinked
# path (macOS /var -> /private/var) must keep passing there (t-1cfc, t-80fc). Builds a copy of canon, a linked worktree of it
# and a symlinked alias of it, and runs the suites that failed in each. A suite that writes under its root must also leave
# the checkout it was started in untouched: skills-uninstall once overwrote .claude/settings.json and deleted the real
# .git/hooks/pre-commit there.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
W="$(cd "$W" && pwd -P)"
mkdir -p "$W/home" "$W/tmp" "$W/xdg"
# The setup below runs git (init, commit, worktree add): pin the environment so it cannot reach the caller's repository or config
# (GIT_* is already unset by helpers.sh; a global commit.gpgsign or core.hooksPath would otherwise run here).
export HOME="$W/home" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/xdg" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# helpers.sh drops git's hook environment: a suite run from an old pre-commit hook (t-ce0b) must not aim `git init` / `commit` at the real repo.
poison="$(GIT_DIR=/nonexistent GIT_INDEX_FILE=/nonexistent GIT_WORK_TREE=/nonexistent GIT_PREFIX=x \
  bash -c 'source "$1/tests/helpers.sh"; env | grep -c "^GIT_\(DIR\|INDEX_FILE\|WORK_TREE\|PREFIX\)=" || true' _ "$ROOT")"
assert_eq "0" "$poison"

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
  (cd "$dir" && SKILLS_SH_NO_TTY=1 bash "tests/$suite.sh" 2>&1)
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
  # a non-trivial settings.json: the old test overwrote it with its fixture, which a tracked `{}` could not show
  printf '{"canary":"keep"}\n' > "$dir/.claude/settings.json"
  before_hook="$(cksum < "$hook")"
  before_settings="$(cksum < "$dir/.claude/settings.json")"
  before_status="$(git -C "$dir" status --porcelain)"
  expect_ok "$dir" skills-uninstall
  [[ -f "$hook" ]] || fail "skills-uninstall run from ${dir#"$W"/} deleted the checkout's pre-commit hook"
  # its project registry writes belong under the temp HOME it makes; the pinned HOME of this run must stay empty
  [[ ! -e "$W/home/.config/canon/projects" ]] || fail "skills-uninstall run from ${dir#"$W"/} wrote the caller's project registry"
  assert_eq "$before_hook" "$(cksum < "$hook")"
  assert_eq "$before_settings" "$(cksum < "$dir/.claude/settings.json")"
  assert_eq "$before_status" "$(git -C "$dir" status --porcelain)"
done

# The shipped hook installers, run from the worktree, reach the common hooks dir instead of skipping "not a git repo" (t-80fc).
common_hooks="$(git_common_dir "$W/wt")/hooks"
assert_eq "$W/canon/.git/hooks" "$common_hooks"
rm -f "$common_hooks/pre-commit" "$common_hooks/pre-push" "$common_hooks/post-commit"
out="$(cd "$W/wt" && bash scripts/install-hooks.sh 2>&1)"
if [[ "$out" == *"not found"* ]]; then fail "install-hooks.sh skipped in a linked worktree: $out"; fi
[[ -x "$common_hooks/pre-push" ]] || fail "install-hooks.sh from the worktree did not install pre-push into $common_hooks"
out="$(cd "$W/wt" && bash tools/skills.sh add sprint "$W/wt" 2>&1)" || fail "skills.sh add sprint failed in the worktree: $(printf '%s' "$out" | tail -3)"
if [[ "$out" == *"not a git repo"* ]]; then fail "skills.sh add skipped the pre-commit hook in a linked worktree"; fi
assert_grep "canon-managed-pre-commit-hook" "$common_hooks/pre-commit"
(cd "$W/wt" && bash tools/skills.sh remove sprint "$W/wt" >/dev/null 2>&1) || fail "skills.sh remove sprint failed in the worktree"
[[ ! -e "$common_hooks/pre-commit" ]] || fail "skills.sh remove from the worktree left the common pre-commit hook"

printf 'worktree-suites: ok\n'
