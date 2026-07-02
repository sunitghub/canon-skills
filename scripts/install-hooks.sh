#!/usr/bin/env bash
# install-hooks.sh — installs git hooks for canon repo (called by skills.sh init)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "  [skip]  .git/hooks not found (not a git repo?)"
  exit 0
fi

# ── post-commit: regenerate dist zips and commit if changed ──────────────────
POST_COMMIT="$HOOKS_DIR/post-commit"
cat > "$POST_COMMIT" << 'HOOK'
#!/usr/bin/env bash
# Prevent recursive execution when the zip-update commit itself triggers this hook
LAST_MSG=$(git log -1 --pretty=%s)
if [ "$LAST_MSG" = "chore: update dist zips" ]; then
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Build artifacts build-zip.sh may touch. Watched generically below (git status,
# not a hardcoded per-file list) so a new artifact never needs a second edit here.
ARTIFACT_PATHS=(dist/ tools/sprint-check-win.exe)

# Skip rebuild if the prior commit only touched build artifacts (e.g. this hook's
# own commit, or an artifact-only commit) -- nothing upstream could have changed.
if ! git -C "$REPO_ROOT" diff --name-only HEAD~1 HEAD 2>/dev/null \
     | grep -qvE "^(dist/|tools/sprint-check-win\.exe$)"; then
  exit 0
fi

bash "$REPO_ROOT/scripts/build-zip.sh"

CHANGED=()
while IFS= read -r f; do
  [ -n "$f" ] && CHANGED+=("$f")
done < <(
  { git -C "$REPO_ROOT" diff --name-only -- "${ARTIFACT_PATHS[@]}"
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "${ARTIFACT_PATHS[@]}"
  } | sort -u
)

if [ ${#CHANGED[@]} -gt 0 ]; then
  git -C "$REPO_ROOT" add "${CHANGED[@]}"
  git -C "$REPO_ROOT" commit -m "chore: update dist zips"
  echo "[post-commit] dist zips updated and committed: ${CHANGED[*]}"
fi
HOOK
chmod +x "$POST_COMMIT"
echo "  [ok]    post-commit hook installed → $POST_COMMIT"
