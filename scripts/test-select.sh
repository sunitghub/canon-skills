#!/usr/bin/env bash
# test-select.sh — t-2633: which suites `scripts/test.sh --changed` runs. Sourced by scripts/test.sh; tests/test-sh-changed.sh drives it
# directly on a scratch repo. A fast pass for the builder between commits, never the close stamp (evidence.sh refuses a --changed run).
#
#   select_init <root> <base> <labels-file>
#                               (<labels-file>: every suite label test.sh runs, one per line) sets SELECT_CHANGED (one path per line), SELECT_FULL ("" or the reason the full suite must run) and the
#                               term file the selection greps; returns 2 (with a message) when <base> is not a commit
#   select_suite <label>        true when the suite <label> (a repo-relative test file, or a Go package directory) should run
#
# Changed = the committed diff from <base> plus tracked edits in the working tree, minus the evidence-neutral paths (one list,
# tools/evidence-neutral.sh). Untracked files are not seen (a stray folder would force a full run every time): `git add -N` a new file
# to include it. A suite runs when it is itself changed, when it is the Go package a change sits in, or when its source mentions a
# changed path or file name, or a tool or script that mentions one (one level up). A changed path that no test file mentions that way
# runs the full suite: over-selecting is the safe direction, and a silent skip is not.

SELECT_GO_DIRS=(tools/sprint-check-go tools/sprint-headless-json-go tools/cockpit-daemon)

select_init() {
  local root="$1" base="$2" labels="$3" c mapped d l
  SELECT_ROOT="$root"; SELECT_CHANGED=""; SELECT_FULL=""
  source "$root/tools/evidence-neutral.sh"
  base="$(git -C "$root" rev-parse --verify -q "$base^{commit}" 2>/dev/null)" || { echo "test.sh --changed: '$2' is not a commit" >&2; return 2; }
  SELECT_BASE="$base"
  SELECT_CHANGED="$( { git -C "$root" -c core.quotepath=off diff --name-only --no-renames "$base" HEAD -- . "${NEUTRAL[@]}"
    git -C "$root" -c core.quotepath=off diff --name-only --no-renames HEAD -- . "${NEUTRAL[@]}"; } | sort -u)"
  SELECT_TERMS="$(mktemp "${TMPDIR:-/tmp}/test-select.XXXXXX")"
  [[ -n "$SELECT_CHANGED" ]] || return 0
  while IFS= read -r c; do
    # The terms for one change: its file name and the names of the tools and scripts that name it (one level up). Names, not paths: a
    # file's name is in every path that holds it, so a path term would select nothing more.
    { printf '%s\n' "${c##*/}"
      git -C "$root" grep -lF -e "${c##*/}" -- tools scripts skills agents 2>/dev/null | sed 's#.*/##' || true; } > "$SELECT_TERMS.one"
    cat "$SELECT_TERMS.one" >> "$SELECT_TERMS"
    mapped=0
    if grep -qxF -- "$c" "$labels"; then mapped=1; fi   # a changed suite runs itself (a whole line: tests/c is not tests/c.js)
    for d in "${SELECT_GO_DIRS[@]}"; do if [[ "$c" == "$d"/* ]]; then mapped=1; fi; done
    if (( ! mapped )); then   # mapped only when a suite test.sh really runs is selected by it
      while IFS= read -r l; do
        if [[ -f "$root/$l" ]] && grep -qF -f "$SELECT_TERMS.one" -- "$root/$l"; then mapped=1; break; fi
      done < "$labels"
    fi
    if (( ! mapped )); then SELECT_FULL="${SELECT_FULL:+$SELECT_FULL; }$c maps to no suite"; fi
  done <<< "$SELECT_CHANGED"
  return 0
}

select_suite() {
  local label="$1" d
  [[ -z "$SELECT_FULL" ]] || return 0
  if [[ $'\n'"$SELECT_CHANGED"$'\n' == *$'\n'"$label"$'\n'* ]]; then return 0; fi
  for d in "${SELECT_GO_DIRS[@]}"; do
    if [[ "$label" == "$d" ]]; then [[ $'\n'"$SELECT_CHANGED" == *$'\n'"$d"/* ]]; return; fi
  done
  [[ -f "$SELECT_ROOT/$label" ]] || return 1   # no grep error for a label with no file
  grep -qF -f "$SELECT_TERMS" -- "$SELECT_ROOT/$label"   # an empty term file (nothing changed) matches nothing
}

select_cleanup() { [[ -z "${SELECT_TERMS:-}" ]] || rm -f "$SELECT_TERMS" "$SELECT_TERMS.one"; }
