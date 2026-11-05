#!/usr/bin/env bash
# sprint-handoff-notice (t-eecb) — `sprint complete` prints one non-blocking line when HANDOFF.md's Current Focus is empty, and nothing
# when it has text, is missing, or HANDOFF.md does not exist. Protects the close (_notice_handoff_focus): it never refuses a close.
# The function is run from the real script, with its own project_root; a close that reaches the notice needs every earlier gate to pass,
# so the notice is exercised through a tiny harness that sources only the function's text.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Lift the functions out of tools/sprint by name (a one-line function ends on its own line) and run them against a folder.
lift() { awk -v n="$1" 'index($0, n "() {") == 1 { p = 1 } p { print } p && (/^}/ || /^[^#]*\(\) \{.*\}[[:space:]]*$/) { exit }' "$SPRINT"; }
fn=""; for f in _handoff_file _handoff_focus_empty _handoff_sum _handoff_mark _notice_handoff_focus _notice_handoff_stale; do
  part="$(lift "$f")"; [[ -n "$part" ]] || fail "could not find $f in tools/sprint"; fn+="$part"$'\n'
done
run_notice() {   # <folder> [main checkout] [mark|stale <ticket dir>]: the notice text, and its exit status
  # project_root is the main checkout, worktree_root the folder being closed (a worktree sprint fills the worktree's own file); with no
  # second argument they are the same folder
  ( cd "$1" && MAIN="${2:-$1}" && project_root() { echo "$MAIN"; } && worktree_root() { pwd; } && eval "$fn" \
    && case "${3:-focus}" in mark) _handoff_mark "$4" ;; stale) _notice_handoff_stale "$4" ;; *) _notice_handoff_focus ;; esac; echo "rc=$?" )
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
# a worktree sprint: the main checkout's Current Focus is empty but the worktree's is filled -> silent; and the other way round -> the notice
main_empty="$(mk mainempty $'## Current Focus\n\n## In Progress\n')"; wt_full="$(mk wtfull $'## Current Focus\nthe worktree\'s own focus\n')"
out="$(run_notice "$wt_full" "$main_empty")"; assert_eq "rc=0" "$out"
main_full="$(mk mainfull $'## Current Focus\nmain has text\n')"; wt_empty="$(mk wtempty $'## Current Focus\n\n## In Progress\n')"
out="$(run_notice "$wt_empty" "$main_full")"; assert_contains "$out" "$NOTE"
# t-10ac: the narrative unchanged since the plan was approved gets one line; changed, never marked, no markers or an empty focus get none
H=$'# Handoff\n<!-- canon:handoff:BEGIN -->\n## Current Focus\nBuilding t-l17n.\n\n## In Progress\nSprint started; plan NOT yet approved.\n\n<!-- canon:handoff:END -->\n'
STALE='HANDOFF.md: the narrative has not changed since this plan was approved'
d="$(mk stale "$H")"; td="$work/t-stale"; mkdir -p "$td"
out="$(run_notice "$d" "$d" stale "$td")"; assert_eq "rc=0" "$out"                      # never marked (an older sprint): silent
run_notice "$d" "$d" mark "$td" >/dev/null; [[ -s "$td/.cockpit-handoff-at-approve" ]] || fail "the approval mark was not written"
out="$(run_notice "$d" "$d" stale "$td")"; assert_contains "$out" "$STALE"; assert_contains "$out" "rc=0"   # unchanged since approval: the notice
printf '%s' "${H/plan NOT yet approved/work done and merged}" > "$d/HANDOFF.md"
out="$(run_notice "$d" "$d" stale "$td")"; assert_eq "rc=0" "$out"                      # refreshed after approval: silent
printf '%s\r\n' "$H" > "$d/HANDOFF.md"; run_notice "$d" "$d" mark "$td" >/dev/null; printf '%s' "${H//$'\n'/$'\r\n'}" > "$d/HANDOFF.md"
out="$(run_notice "$d" "$d" stale "$td")"; assert_contains "$out" "$STALE"             # CRLF line ends do not read as a change
d2="$(mk stalenomark $'## Current Focus\ntext\n')"; td2="$work/t-nomark"; mkdir -p "$td2"; run_notice "$d2" "$d2" mark "$td2" >/dev/null
[[ ! -s "$td2/.cockpit-handoff-at-approve" ]] || fail "a file with no handoff markers was marked"   # no markers: nothing to compare
d3="$(mk staleempty $'<!-- canon:handoff:BEGIN -->\n## Current Focus\n\n## In Progress\n\n<!-- canon:handoff:END -->\n')"; td3="$work/t-empty"; mkdir -p "$td3"
run_notice "$d3" "$d3" mark "$td3" >/dev/null
out="$(run_notice "$d3" "$d3" stale "$td3")"; assert_eq "rc=0" "$out"                    # an empty focus is the other notice's job
grep -q '^  _notice_handoff_stale "$tdir"$' "$SPRINT" || fail "sprint complete no longer calls _notice_handoff_stale"
grep -q '_handoff_mark "$(dirname "$plan")"' "$SPRINT" || fail "sprint approve no longer takes the Handoff mark"
grep -q '^  _notice_handoff_focus$' "$SPRINT" || fail "sprint complete no longer calls _notice_handoff_focus"
echo "sprint-handoff-notice: ok (empty, comment-only and CRLF notice; filled, missing section and missing file silent; unchanged-since-approval notice, refreshed/unmarked/no-marker/empty silent; never blocks; called from complete and approve)"
