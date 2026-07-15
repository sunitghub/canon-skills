#!/usr/bin/env bash
# validate-visuals.sh — check that every image-extension filename mentioned in
# a markdown file is properly embedded via ![alt](path) and exists on disk.
#
# Usage: validate-visuals.sh <ticket-id> <file1> [file2]
# Exit 0 = all OK, Exit 1 = broken reference found.
#
# Extracted from tools/sprint's _gate_visual_embed for independent use
# (pre-commit, CI, or the sprint close-gate chain).

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: validate-visuals.sh <ticket-id> <file1> [file2]" >&2
  exit 1
fi

id="$1"
shift

for file in "$@"; do
  [[ -f "$file" ]] || continue

  # Basename of every real image embed's target path in this file — regardless of
  # whether the mention driving it used a visuals/ prefix, so a bare filename
  # mention and a visuals/-prefixed one resolve to the same identity.
  embedded="$(grep -oE '!\[[^]]*\]\([^)]+\)' "$file" \
    | sed -E 's/.*\(([^)]+)\)/\1/' \
    | grep -oE '[A-Za-z0-9_.-]+\.(png|jpg|jpeg|gif|webp)$' \
    | sort -u)" || true

  # Every image-extension filename mentioned anywhere in the file — bare,
  # backticked, visuals/-prefixed, or inside a real embed's own path.
  mentions="$(grep -oE '[A-Za-z0-9_.-]+\.(png|jpg|jpeg|gif|webp)' "$file" | sort -u)" || true
  [[ -z "$mentions" ]] && continue

  visuals_dir="$(dirname "$file")/visuals"
  bad_refs=()
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    if ! grep -qxF "$ref" <<< "$embedded"; then
      bad_refs+=("$ref — never embedded as a real image")
    elif [[ ! -f "$visuals_dir/$ref" ]]; then
      bad_refs+=("$ref — embedded, but $visuals_dir/$ref doesn't exist on disk")
    fi
  done <<< "$mentions"

  if [[ "${#bad_refs[@]}" -gt 0 ]]; then
    echo "Sprint $id cannot close: $file has a broken visual reference."
    printf '  %s\n' "${bad_refs[@]}"
    echo "Use a real markdown image embed — ![alt](visuals/<name>.<ext>) — and make sure the file is actually copied to $visuals_dir/."
    exit 1
  fi
done
