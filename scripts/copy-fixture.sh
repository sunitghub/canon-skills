#!/usr/bin/env bash
# copy-fixture — copy dist/context-check-fixture.zip to a dest folder

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ZIP="$ROOT/dist/context-check-fixture.zip"
CANON_REPO="$(cd "$ROOT" && pwd)"
FORCE=0
TARGET=""
STAGE=""
cleanup() { [[ -n "$STAGE" ]] && rm -rf "$STAGE"; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
copy-fixture — copy canon's context-check fixture to a disposable project dir

Usage:
  scripts/copy-fixture.sh [--force] <target-dir>

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

if [[ -z "$TARGET" ]]; then
  echo "Error: target-dir is required." >&2
  usage >&2
  exit 1
fi

TARGET="${TARGET/#\~/$HOME}"

# If target is an existing directory, nest inside it
if [[ -d "$TARGET" ]]; then
  TARGET="$TARGET/context-check-fixture"
fi

target_parent="$(dirname "$TARGET")"
target_name="$(basename "$TARGET")"
mkdir -p "$target_parent"
target_parent="$(cd "$target_parent" && pwd)"
TARGET="$target_parent/$target_name"

if [[ "$TARGET" == "/" || "$TARGET" == "$ROOT" || "$TARGET" == "$SOURCE_ZIP" || "$TARGET" == "$CANON_REPO" ]]; then
  echo "Refusing unsafe target: $TARGET" >&2
  exit 1
fi

# Prevent writing inside the canon repo
if [[ "$TARGET" == "$CANON_REPO/"* ]]; then
  echo "Refusing to copy into the canon repo: $TARGET" >&2
  exit 1
fi

if [[ -e "$TARGET" ]]; then
  if [[ "$FORCE" -ne 1 ]]; then
    echo "Target already exists: $TARGET" >&2
    echo "Use --force to replace it." >&2
    exit 1
  fi
  rm -rf "$TARGET"
fi

if [[ ! -f "$SOURCE_ZIP" ]]; then
  echo "Error: fixture zip not found: $SOURCE_ZIP" >&2
  echo "Run scripts/build-zip.sh first." >&2
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "Error: unzip is required to extract $SOURCE_ZIP" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
unzip -q "$SOURCE_ZIP" -d "$STAGE"
cp -R "$STAGE/context-check-fixture" "$TARGET"

rm -rf \
  "$TARGET/.git" \
  "$TARGET/.tickets" \
  "$TARGET/HANDOFF.md" \
  "$TARGET/DECISIONS.md"

cat <<EOF
Copied context-check fixture to:
  $TARGET

Next steps:
  cd "$TARGET"
  skills.sh add context-check
EOF
