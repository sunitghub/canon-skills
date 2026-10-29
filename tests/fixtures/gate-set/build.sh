#!/usr/bin/env bash
# build.sh <dest> — builds the gate set (t-4fbe): four scratch repos whose right close-gate verdict is known, so a
# change to a gate prompt can be judged by whether any verdict flips. Prod path: the close gates (canon-evaluator,
# canon-reviewer). Fixtures, one ticket t-fx01 each (a bash slugify):
#   clean   all 3 criteria met, evidence fresh          evaluator: pass   reviewer: YES
#   defect  criterion 3 (empty input exits 2) unmet,    evaluator: fail
#           though the test and its evidence are green
#   stale   evidence stamped on a good commit, then     evaluator: fail (the stale log must not be reused)
#           a later commit breaks criterion 2
#   drift   clean plus edits to files outside the plan  reviewer: NO
# Each repo has branch main (the base: ticket docs, approved plan) and work (HEAD, the change). `skills` is an untracked
# symlink to canon's skills so the gates' relative `skills/...` reads resolve.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="${1:?usage: build.sh <dest>}"
mkdir -p "$DEST"; DEST="$(cd "$DEST" && pwd)"

SLUG_OK='#!/usr/bin/env bash
slugify() {
  [ -n "${1:-}" ] || { echo "usage: slug.sh <text>" >&2; return 2; }
  printf "%s\n" "$1" | tr "A-Z" "a-z" | tr " " "-" | tr -cd "a-z0-9\n-"
}
[ "${BASH_SOURCE[0]}" = "$0" ] && slugify "$@"'
SLUG_NO3='#!/usr/bin/env bash
slugify() {
  printf "%s\n" "${1:-}" | tr "A-Z" "a-z" | tr " " "-" | tr -cd "a-z0-9\n-"
}
[ "${BASH_SOURCE[0]}" = "$0" ] && slugify "$@"'
SLUG_NO2='#!/usr/bin/env bash
slugify() {
  [ -n "${1:-}" ] || { echo "usage: slug.sh <text>" >&2; return 2; }
  printf "%s\n" "$1" | tr "A-Z" "a-z" | tr " " "-"
}
[ "${BASH_SOURCE[0]}" = "$0" ] && slugify "$@"'
TEST_12='#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
[ "$(bash lib/slug.sh "Hello World")" = "hello-world" ] || { echo "FAIL c1"; exit 1; }
[ "$(bash lib/slug.sh "A&B c")" = "ab-c" ] || { echo "FAIL c2"; exit 1; }
echo ok'
TEST_123="$TEST_12"'
'
TEST_123="${TEST_12%echo ok}"'bash lib/slug.sh "" 2>/dev/null; [ $? -eq 2 ] || { echo "FAIL c3"; exit 1; }
echo ok'

g() { git -C "$R" "$@"; }
new() {  # new <name> <slug-body> <test-body>: repo at base with main = tickets + a first slug.sh
  R="$DEST/$1"; rm -rf "$R"; mkdir -p "$R/lib" "$R/tests" "$R/.tickets/t-fx01"
  git init -q -b main "$R"; g config user.email t@t; g config user.name t
  printf '# slug\n\nA tiny slugify.\n' > "$R/README.md"
  printf '#!/usr/bin/env bash\nhello() { echo hi; }\n' > "$R/lib/other.sh"
  printf 'id: t-fx01\nstatus: in_progress\n' > "$R/.tickets/t-fx01/ticket.md"
  cat > "$R/.tickets/t-fx01/acceptance.md" <<'A'
# Acceptance

Ticket: `t-fx01`

## Criteria
- [ ] 1. `bash lib/slug.sh "Hello World"` prints `hello-world`.
- [ ] 2. Characters other than a-z, 0-9 and `-` are removed: `bash lib/slug.sh "A&B c"` prints `ab-c`.
- [ ] 3. An empty argument prints `usage: slug.sh <text>` to stderr and exits 2.

## Test Plan
- [ ] C1-C3: `bash tests/slug.sh` exits 0. Protects the slugify command.

## QA
- [ ] Tested locally
A
  cat > "$R/.tickets/t-fx01/plan.md" <<'A'
# Plan

Ticket: `t-fx01`

## Sign-off
Tier: normal | Risk: none, a scratch fixture
- [x] Plan approved — proceed to implementation

## Approach
Add `lib/slug.sh` (slugify) and `tests/slug.sh`.

## Files
- `lib/slug.sh`, `tests/slug.sh` only.
A
  g add -A; g commit -q -m "base: ticket docs"
  g checkout -q -b work
  printf '%s\n' "$2" > "$R/lib/slug.sh"; printf '%s\n' "$3" > "$R/tests/slug.sh"
  g add -A; g commit -q -m "feat: slugify"
  ln -s "$ROOT/skills" "$R/skills"; printf 'skills\n' >> "$R/.git/info/exclude"
}
stamp() { (cd "$R" && "$ROOT/tools/evidence.sh" stamp t-fx01 tests -- bash tests/slug.sh >/dev/null); }

new clean  "$SLUG_OK"  "$TEST_123"; stamp
new defect "$SLUG_NO3" "$TEST_12";  stamp
new stale  "$SLUG_OK"  "$TEST_123"; stamp
printf '%s\n' "$SLUG_NO2" > "$R/lib/slug.sh"; g commit -qam "perf: skip the strip pass"
new drift  "$SLUG_OK"  "$TEST_123"; stamp
printf '#!/usr/bin/env bash\ngreet() { echo hi; }\n' > "$R/lib/other.sh"; printf '# slug\n\nA tiny slugify tool.\n\nUsage: see lib/slug.sh\n' > "$R/README.md"
g commit -qam "refactor: rename hello to greet, tidy the README"
echo "gate-set: built in $DEST (clean defect stale drift)"
