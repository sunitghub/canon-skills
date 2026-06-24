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

# Skip rebuild if no source files changed (e.g. dist-only or unrelated commits)
if ! git -C "$REPO_ROOT" diff --name-only HEAD~1 HEAD 2>/dev/null | grep -qv "^dist/"; then
  exit 0
fi

bash "$REPO_ROOT/scripts/build-zip.sh"

CHANGED=()
for ZIP in dist/canon-workshop.zip dist/context-check.zip dist/skill-export.zip; do
  if ! git -C "$REPO_ROOT" diff --quiet -- "$ZIP" 2>/dev/null; then
    CHANGED+=("$ZIP")
  fi
done

if [ ${#CHANGED[@]} -gt 0 ]; then
  git -C "$REPO_ROOT" add "${CHANGED[@]}"
  git -C "$REPO_ROOT" commit -m "chore: update dist zips"
  echo "[post-commit] dist zips updated and committed: ${CHANGED[*]}"
fi
HOOK
chmod +x "$POST_COMMIT"
echo "  [ok]    post-commit hook installed → $POST_COMMIT"
