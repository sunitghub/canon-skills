#!/usr/bin/env bash
# test-hermetic — run every suite scripts/test.sh runs, one by one, from a fresh copy of canon under an empty,
# pinned environment (t-c8be): `env -i`, empty HOME/TMPDIR/XDG, no global or system git config, offline Go.
# This is the run CI would do (t-18a7); scripts/test.sh in a developer's own checkout can pass on ambient state
# (a global git config, a registered project, a leftover log) that a clean machine lacks.
#
#   scripts/test-hermetic.sh                 # clone HEAD (committed work only)
#   scripts/test-hermetic.sh --working-tree  # copy tracked + untracked-not-ignored files (pre-commit check)
#   scripts/test-hermetic.sh --repeat 3      # run every suite 3 times in the SAME copy, HOME and TMPDIR:
#                                            # a suite that leaves state behind fails its second pass
#
# Exit 0 only if every suite ran, passed and did not end on a "skipped" line (a suite that cannot run says so last). Each non-zero or skipped suite is named, with the
# tail of its log. Logs and the copy are removed on success; kept (path printed) on failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODE=head; REPEAT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --working-tree) MODE=worktree; shift ;;
    --repeat) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "test-hermetic: --repeat needs a positive number" >&2; exit 2; }; REPEAT="$2"; shift 2 ;;
    *) echo "usage: scripts/test-hermetic.sh [--working-tree] [--repeat N]" >&2; exit 2 ;;
  esac
done

for tool in git rsync; do command -v "$tool" >/dev/null 2>&1 || { echo "test-hermetic: $tool is required" >&2; exit 2; }; done

# Physical path: macOS's /var -> /private/var symlink otherwise makes some suites compare unequal paths.
W="$(mktemp -d "${TMPDIR:-/tmp}/canon-hermetic.XXXXXX")"; W="$(cd "$W" && pwd -P)"
CL="$W/clone"; mkdir -p "$W/home/.config" "$W/tmp" "$W/logs"

if [[ "$MODE" == head ]]; then
  git clone -q "$ROOT" "$CL"
else
  mkdir -p "$CL"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- ./ "$CL/")
  git -C "$CL" init -q 2>/dev/null || true
fi

# Go needs its module cache offline; resolve it from the caller's environment before pinning.
GM=""; GC=""
if command -v go >/dev/null 2>&1; then GM="$(go env GOMODCACHE)"; GC="$(go env GOCACHE)"; fi

pinned() {
  env -i HOME="$W/home" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/home/.config" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" \
    GOMODCACHE="$GM" GOCACHE="$GC" GOPROXY=off SPRINT_CHECK_NO_BROWSER=1 SKILLS_SH_NO_TTY=1 "$@"
}

FAILED=0; RAN=0
record() {   # record <name> <rc> <logfile>
  local name="$1" rc="$2" log="$3" bad=""
  RAN=$((RAN + 1))
  if [[ "$rc" != 0 ]]; then bad="exit $rc"
  elif tail -n 1 "$log" | grep -qi 'skipped'; then bad="skipped (a green run where something did not run proves nothing)"; fi
  if [[ -n "$bad" ]]; then
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s — %s\n' "$name" "$bad"
    tail -n 6 "$log" | sed 's/^/        /'
  else
    printf 'ok    %s\n' "$name"
  fi
}

# The suite list is scripts/test.sh's own: the bash array, then the node files; Go packages are fixed below.
BASH_SUITES=(); NODE_SUITES=()   # bash 3.2 (macOS) has no mapfile
while IFS= read -r l; do BASH_SUITES+=("$l"); done < <(awk '/^tests=\(/{f=1;next} /^\)/{f=0} f' "$CL/scripts/test.sh" | grep -o 'tests/[^"]*')
while IFS= read -r l; do NODE_SUITES+=("$l"); done < <(grep -o 'node "\$ROOT/tests/[^"]*"' "$CL/scripts/test.sh" | sed 's/.*\$ROOT\///;s/"//')
[[ "${#BASH_SUITES[@]}" -gt 0 && "${#NODE_SUITES[@]}" -gt 0 ]] || { echo "test-hermetic: could not read the suite list from scripts/test.sh" >&2; exit 2; }

run_all() {
  cd "$CL"
  for t in "${BASH_SUITES[@]}"; do
    log="$W/logs/$(echo "$t" | tr '/' '_').log"; rc=0
    if [[ ! -f "$t" ]]; then echo "no such suite" > "$log"; rc=1; else pinned timeout 600 bash "$t" > "$log" 2>&1 || rc=$?; fi
    record "$t" "$rc" "$log"
  done
  for t in "${NODE_SUITES[@]}"; do
    log="$W/logs/$(echo "$t" | tr '/' '_').log"; rc=0
    if ! command -v node >/dev/null 2>&1; then echo "node absent: skipped" > "$log"; rc=0
    elif [[ ! -f "$t" ]]; then echo "no such suite" > "$log"; rc=1
    else pinned timeout 600 node "$t" > "$log" 2>&1 || rc=$?; fi
    record "$t" "$rc" "$log"
  done
  if command -v go >/dev/null 2>&1; then
    for g in tools/sprint-check-go tools/sprint-headless-json-go; do
      log="$W/logs/go_$(basename "$g").log"; rc=0
      pinned env GO111MODULE=off timeout 600 go test -count=1 "./$g" > "$log" 2>&1 || rc=$?
      record "go $g" "$rc" "$log"
    done
    log="$W/logs/go_cockpit-daemon.log"; rc=0
    (cd tools/cockpit-daemon && pinned timeout 900 go test -count=1 ./... > "$log" 2>&1) || rc=$?
    record "go tools/cockpit-daemon" "$rc" "$log"
  else
    echo "go absent: skipped" > "$W/logs/go.log"; record "go suites" 0 "$W/logs/go.log"
  fi

}

for pass in $(seq 1 "$REPEAT"); do
  [[ "$REPEAT" -gt 1 ]] && echo "--- pass $pass of $REPEAT"
  run_all
done

echo "test-hermetic: $RAN suites, $FAILED failed ($MODE)"
if [[ "$FAILED" -eq 0 ]]; then
  cd / && rm -rf "$W"
  exit 0
fi
echo "test-hermetic: logs kept in $W/logs (the copy is $CL)" >&2
exit 1
