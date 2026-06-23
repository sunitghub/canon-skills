#!/usr/bin/env bash
# Workshop installer — copies canon from the extracted zip to ~/.canon
# Usage: bash install.sh [target-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HOME/.canon}"

echo "Installing canon to $TARGET..."

mkdir -p "$TARGET"
cp -r "$SCRIPT_DIR/." "$TARGET/"
chmod +x "$TARGET/tools/tkt" "$TARGET/tools/sprint" \
         "$TARGET/tools/sprint-check" "$TARGET/tools/skills.sh" \
         "$TARGET/scripts/copy-todo-walkthrough.sh" 2>/dev/null || true

echo ""
echo "Done. Add canon tools to your PATH:"
echo "  export PATH=\"\$PATH:$TARGET/tools\""
echo ""
echo "Then start a sprint board from any project:"
echo "  sprint-check"
