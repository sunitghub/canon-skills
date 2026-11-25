#!/usr/bin/env bash
# sprint-validate (t-c2de) — `sprint validate <id | path>`, the artifact schema (canon-go validate, internal/artifact) on a ticket's
# folder or one artifact file, through a fresh build: a well-formed folder is 0 with `artifacts: ok (<n> files)`, a broken strict line
# is 1 with `<path>:<line>: <rule>: <problem>; allowed: <shape>`, an unreadable or non-artifact path is 2, and a board without
# `validate` is 2 saying so. It never writes.
# Protects: the shipped `sprint validate` command and the pre-gate `artifacts` field that runs the same binary word.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
use_fresh_board "$WORK/bin"

P="$WORK/proj"; T="$P/.tickets/t-abcd"; mkdir -p "$T"
printf -- '---\nid: t-abcd\nstatus: open\ntype: task\npriority: 2\n---\n# A ticket\n' > "$T/ticket.md"
printf '# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved — proceed to implementation\n\n## Approach\nprose\n' > "$T/plan.md"
(cd "$P" && git init -q -b main . )

run() { set +e; out="$(cd "$P" && "$SPRINT" validate "$@" 2>&1)"; code=$?; set -e; }

before="$(cd "$T" && ls -la | cksum)"
run t-abcd
assert_eq 0 "$code"; assert_eq "artifacts: ok (2 files)" "$out"
run "$T/plan.md"
assert_eq 0 "$code"; assert_eq "artifacts: ok (1 files)" "$out"

sed -i.bak 's/^status: open$/status: done/' "$T/ticket.md"; rm -f "$T/ticket.md.bak"
run t-abcd
assert_eq 1 "$code"
assert_eq "$T/ticket.md:3: ticket.status: \`status\` is \`done\`; allowed: \`status:\` open, in_progress, closed, cancelled or archived" "$out"
sed -i.bak 's/^status: done$/status: open/' "$T/ticket.md"; rm -f "$T/ticket.md.bak"
[[ "$(cd "$T" && ls -la | cksum)" == "$before" ]] || fail "sprint validate: the ticket folder changed"

run "$T/summary.md"
assert_eq 2 "$code"; assert_contains "$out" "validate:" "sprint validate: a missing file is a read error"
: > "$T/summary.md"; run "$T/summary.md"; rm "$T/summary.md"
assert_eq 2 "$code"; assert_contains "$out" "not a ticket artifact" "sprint validate: a non-artifact file is refused"
run
assert_eq 2 "$code"; assert_contains "$out" "usage: sprint validate" "sprint validate: no argument is a usage error"
run ""
assert_eq 2 "$code"; assert_contains "$out" "usage: sprint validate" "sprint validate: an empty argument is a usage error"
run -x
assert_eq 2 "$code"; assert_contains "$out" "usage: canon-go validate" "sprint validate: a flag reaches canon-go as a usage error"
# Only a bare id is a ticket id: a folder path ending in one and a relative file under one are paths
run "$T"
assert_eq 0 "$code"; assert_eq "artifacts: ok (2 files)" "$out"
set +e; out="$(cd "$P/.tickets" && "$SPRINT" validate t-abcd/plan.md 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_eq "artifacts: ok (1 files)" "$out"

printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/old-board"; chmod +x "$WORK/old-board"
set +e; out="$(cd "$P" && SPRINT_CHECK_BIN="$WORK/old-board" "$SPRINT" validate t-abcd 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "this install's canon-go has no validate" "sprint validate: an older board says so"

assert_contains "$("$SPRINT" help)" "  validate <id|path>" "sprint validate: help lists it"
echo "sprint-validate: ok"
