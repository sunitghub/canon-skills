#!/usr/bin/env bash
# covering-suites — t-2912: which `scripts/test.sh --list` suites cover a set of changed paths, read from the project's
# tests/suite-map.txt (the one owner of the map). The pre-commit hook runs only these; the close's full stamp stays the gate.
#
# Usage: covering-suites.sh <project root> --staged | <project root> <path>...
#
# Prints one of:
#   ALL<TAB><reason>                  (one or more lines): run the full suite; each line names a path that forced it
#   LABEL<TAB><label><TAB><paths>     (one or more lines): run just these; <paths> pulled the label in
# Never exits 0 with neither. CANON_SUITE_RUNNER=<file>, when set, reads the labels from that runner's text instead of running
# `scripts/test.sh --list` (t-ef9c). Exit 1: the map fails its self-check (the row is named on stderr) or the suite list cannot be
# read; exit 2: usage.
#
# Map rows: `<pattern> <token>...  # why`. <pattern> is a shell `case` glob (`*` also matches `/`). A token is a --list label,
# `ALL` (that path runs the full suite), or `@named` (every suite whose source names the path, as written or by its last two
# path parts). A path is mapped when a row matches it; the union of every matching row is taken, and a mapped path that
# selects no suite (an `@named` row no suite names it under) runs the full suite. A path that is itself a
# --list label selects itself. Every scoped run adds the whole-repo pins in tests/pre-gate-suites.txt.
# Self-check on every run: each row's labels must be --list labels (a stale label would select the wrong suites). A pattern
# that matches nothing is harmless: an unmatched path runs the full suite (changelog.d/ is empty after each release).

set -euo pipefail

usage() { echo "usage: covering-suites.sh <project root> --staged | <project root> <path>..." >&2; exit 2; }
[[ $# -ge 2 ]] || usage
ROOT="$1"; shift
[[ -d "$ROOT" ]] || { echo "covering-suites: no such folder: $ROOT" >&2; exit 2; }
MAP_NAME="tests/suite-map.txt"   # one literal: evidence.sh scope-audit reads a tests path followed by a variable as a suite built at run time
MAP="$ROOT/$MAP_NAME"
PINS="$ROOT/tests/pre-gate-suites.txt"
NL=$'\n'; TAB=$'\t'

if [[ "$1" == "--staged" ]]; then
  [[ $# -eq 1 ]] || usage
  PATHS="$(git -C "$ROOT" diff --cached --name-only --no-renames)" || { echo "covering-suites: cannot read the staged paths" >&2; exit 1; }
else
  PATHS="$(printf '%s\n' "$@")"
fi

if [[ ! -f "$MAP" ]]; then printf 'ALL\tno tests/suite-map.txt\n'; exit 0; fi

# t-ef9c: evidence.sh check names a copy of the graded runner instead, because check runs nothing from the tree it judges: the labels are
# its `"$ROOT/<label>"` lines and `suite <label> …` lines, read as text (tests/evidence.sh pins them equal to --list on canon's runner).
if [[ -n "${CANON_SUITE_RUNNER:-}" ]]; then
  LABELS="$(sed -nE -e 's#^  "\$ROOT/([A-Za-z0-9._/-]+)"$#\1#p' -e 's#^  suite ([A-Za-z0-9._/-]+) .*#\1#p' -- "$CANON_SUITE_RUNNER")" || { echo "covering-suites: cannot read $CANON_SUITE_RUNNER" >&2; exit 1; }
  [[ -n "$LABELS" ]] || { echo "covering-suites: $CANON_SUITE_RUNNER names no suite" >&2; exit 1; }
else LABELS="$(bash "$ROOT/scripts/test.sh" --list 2>/dev/null)" || { echo "covering-suites: scripts/test.sh --list failed" >&2; exit 1; }; fi
[[ -n "$LABELS" ]] || { echo "covering-suites: scripts/test.sh --list printed no suites" >&2; exit 1; }
is_label() { grep -qxF -- "$1" <<<"$LABELS"; }

# Rows: comments and blank lines dropped, one row per line as "<pattern> <tokens...>".
ROWS="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$MAP" | grep -v '^[[:space:]]*$' || true)"
[[ -n "$ROWS" ]] || { echo "covering-suites: $MAP has no rows" >&2; exit 1; }

# Self-check: every row, not only the ones this commit matches, so a stale label fails the first commit after it goes stale.
while read -r pat toks; do
  [[ -n "$toks" ]] || { echo "covering-suites: tests/suite-map.txt row '$pat' lists no suite" >&2; exit 1; }
  for t in $toks; do
    case "$t" in ALL|@named) ;; *) is_label "$t" || { echo "covering-suites: tests/suite-map.txt row '$pat': '$t' is not a scripts/test.sh --list label" >&2; exit 1; } ;; esac
  done
done <<<"$ROWS"

# Suites whose source names <path>: the path as written, or its last two parts (`reference/complete.md` from a skill folder).
named() {
  local p="$1" short files="" l
  short="$(basename "$(dirname "$p")")/$(basename "$p")"
  while IFS= read -r l; do if [[ -f "$ROOT/$l" ]]; then files+="$ROOT/$l$NL"; fi; done <<<"$LABELS"
  [[ -n "$files" ]] || return 0
  printf '%s' "$files" | tr '\n' '\0' | xargs -0 grep -lF -e "$p" -e "$short" 2>/dev/null | sed "s|^$ROOT/||" || true
}

FULL=""; SEL=""   # SEL: "<label>\t<path>" lines, in the order found
add() { SEL+="$1$TAB$2$NL"; }
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  case "$p" in .tickets/*|HANDOFF.md|LEARNINGS.md|LEARNINGS-*.md|DECISIONS.md|DECISIONS-*.md) continue ;; esac   # records: the hook's t-7db9 rule
  if is_label "$p"; then add "$p" "$p"; continue; fi
  mapped=0; before="$SEL$FULL"
  while read -r pat toks; do
    # shellcheck disable=SC2254
    case "$p" in $pat) ;; *) continue ;; esac
    mapped=1
    for t in $toks; do
      case "$t" in
        ALL) FULL+="$p: tests/suite-map.txt row '$pat' says ALL$NL" ;;
        @named) while IFS= read -r l; do if [[ -n "$l" ]]; then add "$l" "$p"; fi; done <<<"$(named "$p")" ;;
        *) add "$t" "$p" ;;
      esac
    done
  done <<<"$ROWS"
  if (( ! mapped )); then FULL+="$p: no row in $MAP_NAME$NL"
  elif [[ "$SEL$FULL" == "$before" ]]; then FULL+="$p: its $MAP_NAME rows select no suite (no suite names it)$NL"   # never dropped silently
  fi
done <<<"$PATHS"

if [[ -n "$FULL" ]]; then printf '%s' "$FULL" | sed 's/^/ALL	/'; exit 0; fi
if [[ -z "$SEL" ]]; then printf 'ALL\tno changed path outside the records\n'; exit 0; fi
if [[ -f "$PINS" ]]; then
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    is_label "$l" || { echo "covering-suites: tests/pre-gate-suites.txt: '$l' is not a scripts/test.sh --list label" >&2; exit 1; }
    add "$l" "tests/pre-gate-suites.txt"
  done <<<"$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$PINS" | grep -v '^$' || true)"
fi
# One line per label, its paths joined, in --list order (the order the runner prints them).
while IFS= read -r l; do
  ps="$(awk -F'\t' -v l="$l" '$1 == l && !seen[$2]++ { printf "%s%s", (n++ ? ", " : ""), $2 }' <<<"$SEL")"
  if [[ -n "$ps" ]]; then printf 'LABEL\t%s\t%s\n' "$l" "$ps"; fi
done <<<"$LABELS"
exit 0
