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

# Default file set: README.md, docs/*.md and tools/*.md are all read when no file is named.
D="$(mktemp -d)"; mkdir -p "$D/docs" "$D/tools"; cp "$ROOT/tools/sprint" "$ROOT/tools/tkt" "$D/tools/"
printf 'See [a](gone-a.md).\n' > "$D/README.md"; printf 'See [b](gone-b.md).\n' > "$D/docs/g.md"; printf 'See [c](gone-c.md).\n' > "$D/tools/t.md"
rc=0; out="$("$ROOT/tools/doc-check" --root "$D" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "doc-check: default set exited $rc, want 1: $out"
for f in README.md docs/g.md tools/t.md; do assert_contains "$out" "$f:1: broken link"; done

# Link forms: absolute-from-root resolves, a missing one does not; a tkt alias and an unknown tkt subcommand; code is not prose.
cat > "$W/docs/forms.md" <<'MD'
[ok](/docs/real.md) [no](/nope.md) [mail](mailto:a@b.c) [ph](<x>) [empty]()
`tkt list` and `tkt bogus` and `[fake](nowhere.md)`
```
[fake](nowhere.md)
```
MD
rc=0; out="$("$ROOT/tools/doc-check" --root "$W" "$W/docs/forms.md" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "doc-check: forms doc exited $rc, want 1: $out"
assert_contains "$out" "broken link: /nope.md"
assert_contains "$out" "broken cmd: tkt bogus"
[[ "$out" != *"tkt list"* && "$out" != *nowhere* && "$out" != *"real.md"* ]] || fail "doc-check: flagged something valid or inside code: $out"
[[ "$(grep -c . <<<"$out")" == 2 ]] || fail "doc-check: expected exactly 2 findings: $out"

# Without the tools in the root there is no subcommand list to compare against, so commands are not judged.
E="$(mktemp -d)"; printf 'Run `sprint frobnicate`.\n' > "$E/a.md"
"$ROOT/tools/doc-check" --root "$E" "$E/a.md" || fail "doc-check: judged a command with no dispatcher to compare against"

# Options.
"$ROOT/tools/doc-check" --help | grep -q usage || fail "doc-check: --help printed no usage"
rc=0; "$ROOT/tools/doc-check" --bogus >/dev/null 2>&1 || rc=$?; [[ "$rc" == 2 ]] || fail "doc-check: unknown option exited $rc, want 2"
rc=0; (cd "$E" && "$ROOT/tools/doc-check" >/dev/null 2>&1) || rc=$?; [[ "$rc" == 2 ]] || fail "doc-check: outside a repo with no --root exited $rc, want 2"
rc=0; "$ROOT/tools/doc-check" --root >/dev/null 2>&1 || rc=$?; [[ "$rc" == 2 ]] || fail "doc-check: --root with no value exited $rc, want 2"

# canon's own user-facing docs stay clean (the default file set).
"$ROOT/tools/doc-check" --root "$ROOT" || fail "doc-check: canon's own docs have findings"
echo "doc-check: ok"
