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

# ── pre-push: regenerate workshop zip and commit if changed ──────────────────
PRE_PUSH="$HOOKS_DIR/pre-push"
cat > "$PRE_PUSH" << 'HOOK'
#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "$REPO_ROOT/scripts/build-zip.sh"
if ! git -C "$REPO_ROOT" diff --quiet -- dist/canon-workshop.zip 2>/dev/null; then
  git -C "$REPO_ROOT" add dist/canon-workshop.zip
  git -C "$REPO_ROOT" commit -m "chore: update workshop zip"
  echo "[pre-push] workshop zip updated and committed"
fi
HOOK
chmod +x "$PRE_PUSH"
echo "  [ok]    pre-push hook installed → $PRE_PUSH"
