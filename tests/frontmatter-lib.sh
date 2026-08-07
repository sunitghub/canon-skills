#!/usr/bin/env bash
# frontmatter-lib — get_field CRLF tolerance + LF regression (t-4fca).
# get_field must read frontmatter fields identically whether the file uses LF or
# CRLF line endings (a CRLF ticket.md hand-edited on Windows must still parse),
# and must never return a trailing carriage return in the value.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
source "$ROOT/tools/frontmatter-lib.sh"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# LF fixture
printf -- '---\nid: t-abcd\nstatus: open\ndemo: true\npriority: 2\n---\n# fixture\n' > "$WORK/lf.md"
# CRLF fixture — same content, Windows line endings
printf -- '---\r\nid: t-abcd\r\nstatus: open\r\ndemo: true\r\npriority: 2\r\n---\r\n# fixture\r\n' > "$WORK/crlf.md"

# LF regression: fields parse as before
assert_eq "true"    "$(get_field "$WORK/lf.md" demo)";     echo "  ok   LF: demo=true"
assert_eq "t-abcd"  "$(get_field "$WORK/lf.md" id)";       echo "  ok   LF: id=t-abcd"
assert_eq "open"    "$(get_field "$WORK/lf.md" status)";   echo "  ok   LF: status=open"

# CRLF tolerance: identical values, and no trailing \r (assert_eq would fail on "true\r")
assert_eq "true"    "$(get_field "$WORK/crlf.md" demo)";   echo "  ok   CRLF: demo=true (no trailing CR)"
assert_eq "t-abcd"  "$(get_field "$WORK/crlf.md" id)";     echo "  ok   CRLF: id=t-abcd"
assert_eq "open"    "$(get_field "$WORK/crlf.md" status)"; echo "  ok   CRLF: status=open"

# Explicit byte check: the CRLF value is exactly 4 bytes ("true"), not 5 ("true\r")
crlf_demo="$(get_field "$WORK/crlf.md" demo)"
assert_eq "4" "$(printf '%s' "$crlf_demo" | wc -c | tr -d ' ')"; echo "  ok   CRLF: demo value is 4 bytes (CR stripped)"

# Absent field → empty, on both
assert_eq "" "$(get_field "$WORK/lf.md" missing)";   echo "  ok   LF: absent field → empty"
assert_eq "" "$(get_field "$WORK/crlf.md" missing)"; echo "  ok   CRLF: absent field → empty"

echo "frontmatter-lib: ok"
