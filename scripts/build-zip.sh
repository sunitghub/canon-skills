#!/usr/bin/env bash
# build-zip.sh — packages canon into dist/canon-workshop.zip for offline/workshop distribution
# Run directly or called by .git/hooks/pre-push via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
ZIP_OUT="$DIST_DIR/canon-workshop.zip"
STAGE="$(mktemp -d)"
CANON_DIR="$STAGE/canon"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$CANON_DIR"

# ── Copy include list into staging dir ──────────────────────────────────────
mkdir -p "$CANON_DIR/tools" "$CANON_DIR/standards"
cp -r "$REPO_ROOT/skills"                       "$CANON_DIR/"
cp -r "$REPO_ROOT/tools/sprint-check-app"      "$CANON_DIR/tools/sprint-check-app"
cp    "$REPO_ROOT/tools/tkt"                    "$CANON_DIR/tools/tkt"
cp    "$REPO_ROOT/tools/sprint"                 "$CANON_DIR/tools/sprint"
cp    "$REPO_ROOT/tools/sprint-check"           "$CANON_DIR/tools/sprint-check"
cp    "$REPO_ROOT/standards/efficiency.md"      "$CANON_DIR/standards/efficiency.md"
cp    "$REPO_ROOT/standards/agent-design.md"    "$CANON_DIR/standards/agent-design.md"
cp    "$REPO_ROOT/AGENTS.md"                    "$CANON_DIR/AGENTS.md"

# Workshop-specific installers (not the public GitHub install.sh)
cp    "$REPO_ROOT/scripts/workshop-install.sh"  "$CANON_DIR/install.sh"
cp    "$REPO_ROOT/install.ps1"                  "$CANON_DIR/install.ps1"

# Workshop README becomes the zip root README
cp    "$REPO_ROOT/dist/README.md"               "$CANON_DIR/README.md"

# ── Strip unwanted files from staging ───────────────────────────────────────
rm -rf "$CANON_DIR/tools/sprint-check-app/__pycache__"
find "$STAGE" \( -name "*.pyc" -o -name ".DS_Store" \) -delete 2>/dev/null || true

# ── Zip ─────────────────────────────────────────────────────────────────────
rm -f "$ZIP_OUT"
(cd "$STAGE" && zip -r "$ZIP_OUT" "canon" --quiet)

echo "dist: canon-workshop.zip updated ($(du -sh "$ZIP_OUT" | cut -f1))"
