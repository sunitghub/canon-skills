#!/usr/bin/env bash
# no-browser-in-tests — every place a test starts the Go board server must set
# SPRINT_CHECK_NO_BROWSER=1 (t-269d).
#
# The Go server opens the developer's real browser at startup (`open`/`xdg-open`,
# tools/sprint-check-go/main.go) unless that variable is set. Two scripts forgot it and every
# suite run opened real tabs pointing at ports that died seconds later (~26 accumulated in one
# session). scripts/test.sh exports the variable for the suite; this keeps each start safe when a
# script is run by hand, and fails when a NEW start lacks it.
#
# Per start, not per file: a start counts as safe when the variable is on that line, on one of the
# few lines above it (the env-var continuation style several scripts use), or exported earlier in the
# file. Comment lines never count, and `go build` lines and plain path assignments are not starts. Known limit: a start is
# recognised by the binary spellings below ($GO_BIN, /sc-go, /sprint-check-go, `go run …/sprint-check-go`);
# a script that invents a new variable name for the binary would be missed, which is why the pattern
# is checked for staleness below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${NO_BROWSER_TESTS_DIR:-$ROOT/tests}"   # overridable so the guard can be reverted on a scratch copy
SELF="$(basename "${BASH_SOURCE[0]}")"

# awk: for each non-comment, non-build line naming the Go server binary, require the variable within
# the previous 4 non-comment lines or an earlier `export`. Prints "file:line" for each unsafe start,
# and "START file" for every start seen (so the caller can detect a stale pattern).
scan() {
  awk -v file="$(basename "$1")" '
    /^[[:space:]]*#/ { next }
    /export SPRINT_CHECK_NO_BROWSER=1/ { exported = 1 }
    {
      skip = ($0 ~ /go build|go test|rm -|dirname|mktemp|GO_BIN=|\[\[/) ||
             ($0 ~ /^[[:space:]]*[A-Za-z_]+="[^"]*"[[:space:]]*$/) ||   # a pure path assignment is not a start
             ($0 ~ /main\.go/)
      start = !skip && ($0 ~ /(\$\{?GO_BIN\}?|\/sc-go|\/sprint-check-go|go run [.\/]*tools\/sprint-check-go)/)
    }
    start {
      print "START " file
      safe = exported || ($0 ~ /SPRINT_CHECK_NO_BROWSER=1/)
      for (i = 1; i <= 4 && !safe; i++) if (hist[(NR - i) % 5] ~ /SPRINT_CHECK_NO_BROWSER=1/) safe = 1
      if (!safe) print "UNSAFE " file ":" NR
    }
    # A start line never vouches for the NEXT start: only non-start lines (env-var continuations) go in the window.
    { hist[NR % 5] = start ? "" : $0 }
  ' "$1"
}

offenders=""
starts=0
for f in "$TESTS_DIR"/*.sh; do
  [[ "$(basename "$f")" == "$SELF" ]] && continue
  out="$(scan "$f")"
  n="$(printf '%s\n' "$out" | grep -c '^START ' || true)"
  starts=$((starts + n))
  bad="$(printf '%s\n' "$out" | grep '^UNSAFE ' | sed 's/^UNSAFE //' | tr '\n' ' ' || true)"
  [[ -z "$bad" ]] || offenders="$offenders $bad"
done

[[ "$starts" -gt 0 ]] || { echo "FAIL: no test starts of the Go server were found — the match pattern is stale (t-269d)" >&2; exit 1; }
if [[ -n "$offenders" ]]; then
  echo "FAIL: these Go-server starts in tests lack SPRINT_CHECK_NO_BROWSER=1, so each run opens real browser tabs (file:line):$offenders" >&2
  exit 1
fi
echo "no-browser-in-tests: ok ($starts Go-server starts; all set SPRINT_CHECK_NO_BROWSER=1)"
