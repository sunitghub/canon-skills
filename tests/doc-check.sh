#!/usr/bin/env bash
# t-0a7c: tools/doc-check is doc-audit's mechanical half, run with no model at every close that changes a user-facing doc.
# Prod path: wrapup's doc-audit step runs it before the model pass. Fixture root holds copies of the real sprint and tkt
# dispatchers, so a renamed subcommand in the real tools is what makes a doc stale here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"; mkdir -p "$W/tools" "$W/docs"
cp "$ROOT/tools/sprint" "$ROOT/tools/tkt" "$W/tools/"; : > "$W/docs/real.md"

# Clean doc: a resolving link, a fragment link, an external link, real subcommands and an existing file.
cat > "$W/docs/clean.md" <<'MD'
# Clean
See [real](real.md), [part](real.md#top), [web](https://example.com) and [anchor](#clean).
Run `sprint complete` and `tkt ls`, then read `docs/real.md`.
```
$ sprint start "x"
tkt show t-1234
```
Prose may say sprint foo or tkt bar outside code without a finding.
MD
out="$("$ROOT/tools/doc-check" --root "$W" "$W/docs/clean.md")" || fail "doc-check: a clean doc exited nonzero: $out"

# One broken link and one unknown command: nonzero, each named with file:line.
cat > "$W/docs/bad.md" <<'MD'
# Bad
See [gone](missing.md) for details.
Run `sprint frobnicate` now.
MD
rc=0; out="$("$ROOT/tools/doc-check" --root "$W" "$W/docs/bad.md" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "doc-check: broken doc exited $rc, want 1: $out"
assert_contains "$out" "docs/bad.md:2: broken link: missing.md"
assert_contains "$out" "docs/bad.md:3: broken cmd: sprint frobnicate"

# A missing code-span file is named; a missing input file is a usage error.
printf 'Edit `tools/nope.sh` first.\n' > "$W/docs/file.md"
rc=0; out="$("$ROOT/tools/doc-check" --root "$W" "$W/docs/file.md" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "doc-check: missing file exited $rc, want 1"
assert_contains "$out" "broken file: tools/nope.sh"
rc=0; "$ROOT/tools/doc-check" --root "$W" "$W/docs/none.md" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "doc-check: a missing input file exited $rc, want 2"

# canon's own user-facing docs stay clean (the default file set).
"$ROOT/tools/doc-check" --root "$ROOT" || fail "doc-check: canon's own docs have findings"
echo "doc-check: ok"
