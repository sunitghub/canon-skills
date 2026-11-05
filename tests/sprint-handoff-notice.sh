#!/usr/bin/env bash
# sprint-handoff-notice (t-eecb) — `sprint complete` prints one non-blocking line when HANDOFF.md's Current Focus is empty, and nothing
# when it has text, is missing, or HANDOFF.md does not exist. Protects the close (_notice_handoff_focus): it never refuses a close.
# The function is run from the real script, with its own project_root; a close that reaches the notice needs every earlier gate to pass,
# so the notice is exercised through a tiny harness that sources only the function's text.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Lift the function out of tools/sprint (between its comment header and the next top-level comment) and run it against a folder.
fn="$(awk '/^_notice_handoff_focus\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$SPRINT")"
[[ -n "$fn" ]] || fail "could not find _notice_handoff_focus in tools/sprint"
run_notice() {   # <folder>: the notice text, and its exit status
  ( cd "$1" && project_root() { pwd; } && eval "$fn" && _notice_handoff_focus; echo "rc=$?" )
}
NOTE='HANDOFF.md: Current Focus is empty; the wrapup step "refresh HANDOFF.md" fills it (this never blocks the close)'
mk() { local d="$work/$1"; mkdir -p "$d"; printf '%s' "$2" > "$d/HANDOFF.md"; echo "$d"; }

out="$(run_notice "$(mk empty $'# Handoff\n<!-- canon:handoff:BEGIN -->\n## Current Focus\n\n## In Progress\n\n## Discoveries\n\n## Next Steps\n\n<!-- canon:handoff:END -->\n')")"
assert_contains "$out" "$NOTE"; assert_contains "$out" "rc=0"
out="$(run_notice "$(mk comment $'## Current Focus\n<!-- fill me -->\n\n## In Progress\nx\n')")"
assert_contains "$out" "$NOTE"
out="$(run_notice "$(mk filled $'## Current Focus\nBuilding t-c662.\n\n## In Progress\n\n')")"
assert_eq "rc=0" "$out"                                    # text in the section: nothing printed
out="$(run_notice "$(mk nosection $'## In Progress\nx\n')")"
assert_eq "rc=0" "$out"                                    # no Current Focus section at all: nothing
mkdir -p "$work/nofile"; out="$(run_notice "$work/nofile")"
assert_eq "rc=0" "$out"                                    # no HANDOFF.md: nothing
out="$(run_notice "$(mk crlf $'## Current Focus\r\n\r\n## In Progress\r\nx\r\n')")"
assert_contains "$out" "$NOTE"                             # a Windows file with CRLF line ends reads as empty too
grep -q '^  _notice_handoff_focus$' "$SPRINT" || fail "sprint complete no longer calls _notice_handoff_focus"
echo "sprint-handoff-notice: ok (empty, comment-only and CRLF notice; filled, missing section and missing file silent; never blocks; called from complete)"
