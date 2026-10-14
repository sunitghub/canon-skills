#!/usr/bin/env bash
# test-select.sh — t-2633: which suites `scripts/test.sh --changed` runs. Sourced by scripts/test.sh; tests/test-sh-changed.sh drives it
# directly on a scratch repo. A fast pass for the builder between commits, never the close stamp (evidence.sh refuses a --changed run).
#
#   select_init <root> <base> <labels-file>
#                               (<labels-file>: every suite label test.sh runs, one per line; a label that is a directory is a
#                               Go package) sets SELECT_CHANGED (one path per line), SELECT_FULL ("" or why the full suite must
#                               run), SELECT_UNTRACKED (untracked paths not seen) and the term file the selection greps; returns 2 (with a message) when <base> is not a commit
#   select_suite <label>        true when the suite <label> (a repo-relative test file, or a Go package directory) should run
#
# Changed = the committed diff from <base> plus tracked edits in the working tree, minus the evidence-neutral paths (one list,
# tools/evidence-neutral.sh). Untracked files are not seen (a stray folder would force a full run every time): `git add -N` a new file
# to include it. A suite runs when it is itself changed, when it is the Go package a change sits in, or when its source mentions a
# changed path or file name, or a tool or script that mentions one (one level up). A changed path that no test file mentions that way
# runs the full suite: over-selecting is the safe direction, and a silent skip is not.


select_init() {
  local root="$1" base="$2" labels="$3" c mapped d l folder
  SELECT_ROOT="$root"; SELECT_CHANGED=""; SELECT_FULL=""; SELECT_UNTRACKED=0
  source "$root/tools/evidence-neutral.sh"
  base="$(git -C "$root" rev-parse --verify -q "$base^{commit}" 2>/dev/null)" || { echo "test.sh --changed: '$2' is not a commit" >&2; return 2; }
  SELECT_BASE="$base"
  SELECT_CHANGED="$( { git -C "$root" -c core.quotepath=off diff --name-only --no-renames "$base" HEAD -- . "${NEUTRAL[@]}"
    git -C "$root" -c core.quotepath=off diff --name-only --no-renames HEAD -- . "${NEUTRAL[@]}"; } | sort -u)"
  SELECT_UNTRACKED="$(git -C "$root" ls-files --others --exclude-standard -- . "${NEUTRAL[@]}" | grep -c . || true)"   # reported, not run
  SELECT_TERMS="$(mktemp "${TMPDIR:-/tmp}/test-select.XXXXXX")"
  [[ -n "$SELECT_CHANGED" ]] || return 0
  # File names that more than one tracked file has (main.go, README.md): such a name is matched by its path, never alone.
  git -C "$root" ls-files | awk -F/ '{print $NF}' | sort | uniq -d > "$SELECT_TERMS.dups"
  while IFS= read -r c; do
    # The terms for one change: the file's name, and each tool or script whose code names it (one level up). A doc gets no referrers: code
    # that names a doc does not run it, and neither does a doc that names a tool (*.md and *.json never count as referrers). Referrers
    # are found by the bare file name, since code calls a sibling by name ("$SCRIPT_DIR/evidence.sh"); over-including one is safe. A
    # referrer's term is its file name when that name is unique and has an extension, else its path (a bare `sprint` is in nearly every
    # test). Every term matches as a whole word (select_terms_re). The changed file's folder name counts too (below the top level), for a
    # suite that lists a folder. Known limit: a suite that builds a path from pieces it never spells out is invisible to a text search;
    # the full stamped run is the only evidence.
    folder=""; d="${c%/*}"; if [[ "$d" == */* ]]; then folder="${d##*/}"; fi   # its folder below the top level
    { printf '%s\n' "${c##*/}"   # the changed file by its name, even when shared: tests build such paths ("$ROOT/skills/$s/SKILL.md")
      if [[ -n "$folder" ]]; then printf '%s\n' "$folder"; fi   # a suite may list the folder (readdir of 'static')
      if [[ "$c" != *.md ]]; then
        { git -C "$root" grep -lF -e "${c##*/}" -- tools scripts agents ':(exclude)*.md' ':(exclude)*.json' 2>/dev/null
          # a test helper (a file under tests/ that is no suite) naming the file or its folder: suites reach code through it, as the
          # board suites reach static/*.js only through tests/board-script.js (t-2633 evaluator run 2)
          git -C "$root" grep -lwF -e "${c##*/}" ${folder:+-e "$folder"} -- tests ':(exclude)*.md' ':(exclude)*.json' 2>/dev/null \
            | grep -vxF -f "$labels" | sed 's/^/helper:/'; } | while IFS= read -r r; do
          if [[ "$r" == helper:*.sh ]]; then select_helper_terms "$root" "${r#helper:}" "${c##*/}" "$folder"; else select_term "${r#helper:}"; fi
        done || true
      fi; } | select_terms_re > "$SELECT_TERMS.one"
    cat "$SELECT_TERMS.one" >> "$SELECT_TERMS"
    mapped=0
    if grep -qxF -- "$c" "$labels"; then mapped=1; fi   # a changed suite runs itself (a whole line: tests/c is not tests/c.js)
    while IFS= read -r d; do if [[ "$c" == "$d"/* ]]; then mapped=1; fi; done < "$labels"   # inside a label: the Go package dir
    if (( ! mapped )); then   # mapped only when a suite test.sh really runs is selected by it
      while IFS= read -r l; do
        if [[ -f "$root/$l" ]] && grep -qE -f "$SELECT_TERMS.one" -- "$root/$l"; then mapped=1; break; fi
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
  if [[ -d "$SELECT_ROOT/$label" ]]; then [[ $'\n'"$SELECT_CHANGED" == *$'\n'"$label"/* ]]; return; fi   # a Go package: by its directory
  [[ -f "$SELECT_ROOT/$label" ]] || return 1   # no grep error for a label with no file
  grep -qE -f "$SELECT_TERMS" -- "$SELECT_ROOT/$label"   # an empty term file (nothing changed) matches nothing
}

# select_helper_terms <root> <helper.sh> <name> [<folder>] — a shell helper is sourced by most suites, so naming the helper would select
# them all: the terms are instead the functions whose code names <name> or <folder> (comment lines do not count), so only the suites
# that call those functions run. A match outside any function falls back to the helper's own path.
select_helper_terms() {
  local re
  re="$( { printf '%s\n' "$3"; [[ -z "${4:-}" ]] || printf '%s\n' "$4"; } | select_terms_re | paste -sd '|' -)"
  awk -v re="$re" -v path="$2" '
    /^[[:space:]]*#/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ { fn = $0; sub(/[[:space:]]*\(.*/, "", fn) }
    $0 ~ re { if (fn != "") print fn; else top = 1 }
    /^}/ { fn = "" }
    END { if (top) print path }' "$1/$2" | sort -u
}

# select_term <path> — the term for a path: its file name when unique in the repo and with an extension, else the path itself.
select_term() {
  local n="${1##*/}"
  if [[ "$n" == *.* ]] && ! grep -qxF -- "$n" "$SELECT_TERMS.dups"; then printf '%s\n' "$n"; else printf '%s\n' "$1"; fi
}

# select_terms_re — each term on stdin as a whole-word extended regex: escaped, and not part of a longer name on either side.
select_terms_re() { sed -e 's/[][\.*^$+?(){}|]/\\&/g' -e 's/^/(^|[^A-Za-z0-9_.-])/' -e 's/$/($|[^A-Za-z0-9_-])/'; }

select_cleanup() { [[ -z "${SELECT_TERMS:-}" ]] || rm -f "$SELECT_TERMS" "$SELECT_TERMS.one" "$SELECT_TERMS.dups"; }
