#!/usr/bin/env bash
# tests/canon-version.sh — `canon --version` prints the repo's VERSION file (the single owner of the number),
# and reports "unknown" rather than failing when an install has no VERSION file.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

want="canon $(tr -d '[:space:]' < "$ROOT/VERSION")"
for flag in --version -V version; do
  assert_eq "$want" "$("$ROOT/tools/canon" "$flag")"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools"
cp "$ROOT/tools/canon" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$tmp/tools/"
assert_eq "canon unknown" "$("$tmp/tools/canon" --version)"

printf 'canon-version: ok\n'
