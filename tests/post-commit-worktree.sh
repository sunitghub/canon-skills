#!/usr/bin/env bash
# t-c184: the post-commit hook must build and commit artifacts from the checkout being committed in,
# not from the main checkout that owns the shared .git/hooks directory.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A real hook run exports GIT_DIR/GIT_INDEX_FILE; never let the caller's leak into the temp repos.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
main="$tmp/main"
wt="$tmp/wt"
ART=tools/sprint-check-win.exe

git init -q "$main"
git -C "$main" config user.email t@example.com
git -C "$main" config user.name t
mkdir -p "$main/scripts" "$main/tools"
cp "$ROOT/scripts/install-hooks.sh" "$main/scripts/install-hooks.sh"
# Stub build: records the tree it was built from, as the real build-zip.sh does via its own path.
cat > "$main/scripts/build-zip.sh" <<'STUB'
#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "src=$(cat "$REPO_ROOT/src.txt")" > "$REPO_ROOT/tools/sprint-check-win.exe"
STUB
echo main-src > "$main/src.txt"
echo old > "$main/$ART"
git -C "$main" add -A
git -C "$main" commit -qm init
bash "$main/scripts/install-hooks.sh" >/dev/null

git -C "$main" worktree add -q "$wt" -b wtb

# ── Commit in the worktree: artifact comes from the worktree's source ───────
echo wt-src > "$wt/src.txt"
git -C "$wt" add src.txt
git -C "$wt" commit -qm "wt change" >/dev/null
assert_eq "chore: update dist zips" "$(git -C "$wt" log -1 --format=%s)"
assert_eq "src=wt-src" "$(git -C "$wt" show HEAD:$ART)"
assert_eq "" "$(git -C "$main" status --short)"
assert_eq "old" "$(cat "$main/$ART")"

# ── Artifact-only commit in the worktree: no rebuild commit follows ─────────
echo touched > "$wt/$ART"
git -C "$wt" add "$ART"
git -C "$wt" commit -qm "touch artifact" >/dev/null
assert_eq "touch artifact" "$(git -C "$wt" log -1 --format=%s)"

# ── Commit in the main checkout: still builds from main ─────────────────────
echo main-src2 > "$main/src.txt"
git -C "$main" add src.txt
git -C "$main" commit -qm "main change" >/dev/null
assert_eq "chore: update dist zips" "$(git -C "$main" log -1 --format=%s)"
assert_eq "src=main-src2" "$(git -C "$main" show HEAD:$ART)"

echo "post-commit-worktree: ok"
