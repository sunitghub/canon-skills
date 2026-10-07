#!/usr/bin/env bash
# t-c184, t-9383: the post-commit hook runs the build script of the checkout being committed in (not the main checkout that
# owns the shared .git/hooks directory), and it never commits anything: the Windows exes are release assets now. An OLD
# installed hook (tests/fixtures/old-post-commit-hook.sh, the pre-t-9383 text) must degrade to a no-op, not an error, because
# every other worktree keeps its old hook until `skills.sh init` is run there.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A real hook run exports GIT_DIR/GIT_INDEX_FILE; never let the caller's leak into the temp repos.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
main="$tmp/main"
wt="$tmp/wt"

git init -q "$main"
git -C "$main" config user.email t@example.com
git -C "$main" config user.name t
mkdir -p "$main/scripts" "$main/tools"
cp "$ROOT/scripts/install-hooks.sh" "$main/scripts/install-hooks.sh"
# Stub build: records which checkout it ran from and what source it saw, as the real build-zip.sh does via its own path.
cat > "$main/scripts/build-zip.sh" <<'STUB'
#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "src=$(cat "$REPO_ROOT/src.txt")" > "$REPO_ROOT/built.txt"
STUB
echo main-src > "$main/src.txt"
printf '/built.txt\n/tools/*-win.exe\n' > "$main/.gitignore"
git -C "$main" add -A
git -C "$main" commit -qm init
bash "$main/scripts/install-hooks.sh" >/dev/null
hook="$main/.git/hooks/post-commit"
grep -q 'ARTIFACT_PATHS' "$hook" && fail "the installed hook still has ARTIFACT_PATHS (it must not commit artifacts any more)"
grep -q 'git commit' "$hook" && fail "the installed hook must never commit"

git -C "$main" worktree add -q "$wt" -b wtb

# ── Commit in the worktree: the build runs from the worktree's source, and nothing extra is committed ──
echo wt-src > "$wt/src.txt"
git -C "$wt" add src.txt
git -C "$wt" commit -qm "wt change" >/dev/null
assert_eq "wt change" "$(git -C "$wt" log -1 --format=%s)"
assert_eq "src=wt-src" "$(cat "$wt/built.txt")"
assert_eq "" "$(git -C "$main" status --short)"
[[ ! -e "$main/built.txt" ]] || fail "the worktree commit built in the main checkout"

# ── Commit in the main checkout: still builds from main ─────────────────────
echo main-src2 > "$main/src.txt"
git -C "$main" add src.txt
git -C "$main" commit -qm "main change" >/dev/null
assert_eq "main change" "$(git -C "$main" log -1 --format=%s)"
assert_eq "src=main-src2" "$(cat "$main/built.txt")"
assert_eq 2 "$(git -C "$main" rev-list --count HEAD)"   # init and the main change; the worktree's commit is on wtb, and no hook commit exists

# ── An exe that exists but is untracked and ignored never produces a commit, with the NEW hook ──
echo fetched > "$main/tools/sprint-check-win.exe"
echo main-src3 > "$main/src.txt"; git -C "$main" add src.txt; git -C "$main" commit -qm "main change 3" >/dev/null
assert_eq "main change 3" "$(git -C "$main" log -1 --format=%s)"; assert_eq "" "$(git -C "$main" status --short)"

# ── An OLD installed hook (still listing the exes) must be a harmless no-op in a repo that no longer tracks them ──
cp "$ROOT/tests/fixtures/old-post-commit-hook.sh" "$hook"; chmod +x "$hook"
grep -q '^ARTIFACT_PATHS=(' "$hook" || fail "the fixture is not the old hook"
echo main-src4 > "$main/src.txt"; git -C "$main" add src.txt
before="$(git -C "$main" rev-list --count HEAD)"
git -C "$main" commit -qm "main change with an old hook" >/dev/null
assert_eq "main change with an old hook" "$(git -C "$main" log -1 --format=%s)"
assert_eq "$((before + 1))" "$(git -C "$main" rev-list --count HEAD)"   # exactly the one commit we made
assert_eq "" "$(git -C "$main" status --short)"
assert_eq "src=main-src4" "$(cat "$main/built.txt")"

echo "post-commit-worktree: ok"
