#!/usr/bin/env bash
# copy-todo-walkthrough — copy the Todo walkthrough to a disposable project dir

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/examples/canon-todo-walkthrough"
DEFAULT_TARGET="$HOME/Developer/canon-todo-walkthrough"
FORCE=0
TARGET=""

usage() {
  cat <<'EOF'
copy-todo-walkthrough — copy canon's Todo walkthrough to a disposable project

Usage:
  scripts/copy-todo-walkthrough.sh [--force] [target-dir]

Default target:
  ~/Developer/canon-todo-walkthrough

Options:
  --force   Remove target-dir first if it already exists
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "Only one target directory may be provided." >&2
        usage >&2
        exit 1
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

TARGET="${TARGET:-$DEFAULT_TARGET}"
TARGET="${TARGET/#\~/$HOME}"
target_parent="$(dirname "$TARGET")"
target_name="$(basename "$TARGET")"
mkdir -p "$target_parent"
target_parent="$(cd "$target_parent" && pwd)"
TARGET="$target_parent/$target_name"

# Safety check on the raw resolved target (before copy-into-dir logic)
BLOCKED_DIRS=("$HOME" "/" "/tmp" "/var" "/usr" "/etc" "/bin" "/sbin")
for blocked in "${BLOCKED_DIRS[@]}"; do
  if [[ "$TARGET" == "$blocked" ]]; then
    echo "Refusing unsafe target: $TARGET" >&2
    exit 1
  fi
done
if [[ "$TARGET" == "$ROOT" || "$TARGET" == "$SOURCE" ]]; then
  echo "Refusing unsafe target: $TARGET" >&2
  exit 1
fi

# If the target is an existing directory, copy INTO it (cp -R semantics)
if [[ -d "$TARGET" ]]; then
  TARGET="$TARGET/$(basename "$SOURCE")"
fi

if [[ -e "$TARGET" ]]; then
  if [[ "$FORCE" -ne 1 ]]; then
    echo "Target already exists: $TARGET" >&2
    echo "Use --force to replace it." >&2
    exit 1
  fi
  rm -rf "$TARGET"
fi

cp -R "$SOURCE" "$TARGET"

rm -rf \
  "$TARGET/.git" \
  "$TARGET/.tickets" \
  "$TARGET/CLAUDE.md" \
  "$TARGET/AGENTS.md" \
  "$TARGET/HANDOFF.md" \
  "$TARGET/DECISIONS.md"

cat <<EOF
Copied Todo walkthrough to:
  $TARGET

Next steps:
  cd "$TARGET"
  skills.sh add sprint
  sprint-check
EOF
