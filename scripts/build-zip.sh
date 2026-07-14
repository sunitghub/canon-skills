#!/usr/bin/env bash
# build-zip.sh — packages generated dist artifacts
# Run directly or called by .git/hooks/post-commit via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
FIXTURE_ZIP="$DIST_DIR/context-check-fixture.zip"
FIXTURE_DIR="$REPO_ROOT/examples/context-check-fixture"
FIXTURE_STAGE="$(mktemp -d)"

cleanup() { rm -rf "$FIXTURE_STAGE"; }
trap cleanup EXIT

mkdir -p "$DIST_DIR"

# ── Zip: context-check fixture ───────────────────────────────────────────────
if [[ -d "$FIXTURE_DIR" ]]; then
  rm -f "$FIXTURE_ZIP"
  mkdir -p "$FIXTURE_STAGE"
  cp -r "$FIXTURE_DIR" "$FIXTURE_STAGE/context-check-fixture"
  find "$FIXTURE_STAGE" \( -name ".DS_Store" -o -name "*.pyc" \) -delete 2>/dev/null || true
  # zip embeds file mtimes, so identical content produces different bytes
  # every rebuild (staging always re-copies with a fresh mtime) — normalize
  # to a fixed timestamp so unchanged source content yields a byte-identical
  # zip, and the post-commit hook stops committing a spurious "changed" zip.
  find "$FIXTURE_STAGE" -exec touch -t 202001010000 {} +
  (cd "$FIXTURE_STAGE" && zip -rX "$FIXTURE_ZIP" "context-check-fixture" --quiet)
  echo "dist: context-check-fixture.zip updated ($(du -sh "$FIXTURE_ZIP" | cut -f1))"
else
  echo "Error: fixture dir not found: $FIXTURE_DIR" >&2
  exit 1
fi

# ── Binary: sprint-check-win.exe (Windows board server) ─────────────────────
if command -v go >/dev/null 2>&1; then
  GOOS=windows GOARCH=amd64 go build \
    -o "$REPO_ROOT/tools/sprint-check-win.exe" \
    "$REPO_ROOT/tools/sprint-check-go/main.go"
  echo "dist: sprint-check-win.exe rebuilt ($(du -sh "$REPO_ROOT/tools/sprint-check-win.exe" | cut -f1))"
else
  echo "dist: sprint-check-win.exe skipped (go absent)"
fi

# ── Binary: sprint-headless-json-win.exe (Windows JSON-parse helper) ────────
if command -v go >/dev/null 2>&1; then
  GOOS=windows GOARCH=amd64 go build \
    -o "$REPO_ROOT/tools/sprint-headless-json-win.exe" \
    "$REPO_ROOT/tools/sprint-headless-json-go/main.go"
  echo "dist: sprint-headless-json-win.exe rebuilt ($(du -sh "$REPO_ROOT/tools/sprint-headless-json-win.exe" | cut -f1))"
else
  echo "dist: sprint-headless-json-win.exe skipped (go absent)"
fi
