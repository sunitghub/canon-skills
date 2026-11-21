#!/usr/bin/env bash
# sandbox-tmpdir — t-7ab9: canon's sprint commands run inside Claude Code's sandbox on macOS. The sandbox lets a session write TMPDIR but
# not the per-user temp folder (getconf DARWIN_USER_TEMP_DIR), where macOS's bare `mktemp` / `mktemp -d` write whatever TMPDIR says; the
# platform-lib.sh wrapper moves them into TMPDIR. Protects sprint start, sprint approve, sprint gate-snapshot pre/post and
# tools/skill-eval-scope.sh (the close's skill-eval scope) under that sandbox. macOS only: GNU mktemp already honours TMPDIR.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

[[ "$(uname -s)" == Darwin ]] || { echo "sandbox-tmpdir: skipped (macOS only; GNU mktemp already honours TMPDIR)"; exit 0; }
command -v sandbox-exec >/dev/null 2>&1 || { echo "sandbox-tmpdir: skipped (no sandbox-exec)"; exit 0; }
sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null \
  || { echo "sandbox-tmpdir: skipped (sandbox-exec cannot apply here, e.g. inside another sandbox such as Claude Code's)"; exit 0; }

UT="$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)"   # Seatbelt matches resolved paths: /private/var/folders/...
base="$(cd "${TMPDIR:-/tmp}" && pwd -P)"; [[ "$base/" == "$UT/"* ]] && base=/private/tmp   # the scratch must sit outside the denied folder
W="$(command mktemp -d "$base/sandbox-tmpdir.XXXXXX")"; W="$(cd "$W" && pwd -P)"
mkdir -p "$W/tmp" "$W/home" "$W/canon-home" "$W/registry"
export CANON_GATE_SCOPE_DIR="$W/registry"   # t-c206: gate-snapshot pre's scope registry stays in this test's scratch
cleanup() {
  local f d
  for f in "$CANON_GATE_SCOPE_DIR"/*; do [[ -f "$f" ]] || continue; d="$(sed -n 's/^dir=//p' "$f")"; [[ "$d" == /*/* ]] && rm -rf "$d"; done
  rm -rf "$W"
}
trap cleanup EXIT

PROFILE="(version 1)(allow default)(deny file-write* (subpath \"$UT\"))"
sb() { sandbox-exec -p "$PROFILE" env HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/canon-home" TMPDIR="$W/tmp" "$@"; }

# The profile must reproduce the bug, or every run below proves nothing: the real mktemp ignores TMPDIR and is refused.
if sb /usr/bin/mktemp >/dev/null 2>&1; then fail "the profile did not refuse the real mktemp: it no longer reproduces Claude Code's sandbox"; fi
if sb /usr/bin/mktemp -d >/dev/null 2>&1; then fail "the profile did not refuse the real mktemp -d"; fi

project="$W/project"; mkdir -p "$project"; cd "$project" || exit 1
git init -q; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

out="$(sb "$SPRINT" start "Sandboxed sprint" 2>&1)" || fail "sprint start failed in the sandbox: $out"
id="$(awk '/Sprint started:/ { print $3 }' <<< "$out")"; [[ -n "$id" ]] || fail "sprint start printed no ticket id: $out"
cat > ".tickets/$id/plan.md" <<'PLAN'
# Plan

## Sign-off
Tier: normal | Risk: low

- [ ] Plan approved — proceed to implementation

## Approach
Do the thing.

## Files
- todo.js
PLAN
out="$(sb "$SPRINT" approve "$id" 2>&1)" || fail "sprint approve failed in the sandbox: $out"
assert_contains "$out" "pinned ## Approach"

snap=".tickets/$id/gate-snapshot.txt"
out="$(sb "$SPRINT" gate-snapshot pre "$snap" --role reviewer 2>&1)" || fail "sprint gate-snapshot pre failed in the sandbox: $out"
out="$(sb "$SPRINT" gate-snapshot post "$snap" 2>&1)" || fail "sprint gate-snapshot post failed in the sandbox: $out"
assert_contains "$out" "post ok"

out="$(sb "$ROOT/tools/skill-eval-scope.sh" HEAD 2>&1)" || fail "skill-eval-scope.sh failed in the sandbox: $out"

echo "sandbox-tmpdir: ok"
