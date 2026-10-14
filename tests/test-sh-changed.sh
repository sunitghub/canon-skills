#!/usr/bin/env bash
# test-sh-changed (t-2633) — scripts/test.sh's --changed selection (scripts/test-select.sh) and its timing table. Selection runs on a
# throwaway git repo shaped like canon (tests/, tools/, a Go package dir, the neutral-path list); the timing table runs a copy of the
# real scripts/test.sh with two fake suites. Nothing touches the real tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sh-changed.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export SPRINT_CHECK_NO_BROWSER=1   # tests/no-browser-in-tests.sh reads any sprint-check-go mention as a board start; none starts here
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
REPO="$WORK/repo"; mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p tests tools/sprint-check-go scripts
cp "$ROOT/tools/evidence-neutral.sh" tools/; cp "$ROOT/scripts/test-select.sh" scripts/
printf 'bash "$ROOT/tools/alpha.sh"\n' > tests/a.sh                  # names a tool
printf 'bash "$ROOT/tools/beta.sh"\n' > tests/b.sh                   # names a tool that names another
printf 'const g = "gamma.txt";\n' > tests/c.js                       # names a data file by its base name
printf 'source "$(dirname "$0")/delta.sh"\n' > tools/beta.sh         # one level up: beta names delta
echo alpha > tools/alpha.sh; echo delta > tools/delta.sh; echo gamma > tools/gamma.txt
echo 'package main' > tools/sprint-check-go/main.go
echo orphan > tools/orphan.sh                                        # named by nothing
echo helper > tests/not-a-suite.sh                                   # in tests/, but not a suite test.sh runs
echo l > LEARNINGS.md
printf 'source "$HERE/epsilon.sh"\n' > tests/e.sh                  # names a tool by its file name only
printf '. "$(dirname "$0")/zeta.sh"  # needs zeta.sh\n' > tools/epsilon.sh   # epsilon names zeta
printf '# zeta.sh\n' > tools/zeta.sh                                # zeta names itself
printf 'const g = "gamma.txt";\n' > tests/kappa.js                 # a suite whose name is another path plus an extension
mkdir -p tools/other tools/x tools/y
echo 'package other' > tools/other/main.go                           # a second main.go: that name is shared, so it matches by path
printf 'go vet ./tools/other/main.go\n' > tests/g.sh                 # names the OTHER main.go only
printf 'bash "$ROOT/tools/runner"\n' > tests/h.sh                    # names an extensionless tool by path
printf 'echo the runner is fine\n' > tests/i.sh                      # only the word "runner": must not count as naming tools/runner
printf 'exec delta2.sh\n' > tools/runner; echo d2 > tools/delta2.sh # tools/runner (no extension) names delta2.sh
echo a > tools/x/big-alpha.sh; echo a > tools/y/big-alpha.sh        # a shared name that contains the unique name alpha.sh
printf 'source "$D/alpha.sh"\n' > tests/j.sh                         # names alpha.sh by its (unique) file name only
mkdir -p skills/one skills/two; echo s > skills/one/SKILL.md; echo s > skills/two/SKILL.md   # a shared name
printf 'file="$ROOT/skills/$skill/SKILL.md"\n' > tests/s.sh           # builds the path: only the file name is spelled out
mkdir -p tools/app/widgets; echo w > tools/app/widgets/dial.js         # a folder a suite lists
printf "fs.readdirSync(path.join(app, 'widgets')).filter(f => /^d/.test(f))\n" > tests/w.js   # names the folder, never the file
mkdir -p tools/app/panels; echo p > tools/app/panels/knob.js         # reached only through test helpers
printf "const dir = path.join(app, 'panels');\n" > tests/panel-loader.js   # a JS helper (no suite) that names the folder
printf "require('./panel-loader.js')\n" > tests/p.js                  # a suite that uses the JS helper
printf '# panels are listed below (a comment does not count)\npanel_src() {\n  cat "$1"/tools/app/panels/*.js\n}\nother_fn() {\n  echo hi\n}\n' > tests/lib2.sh   # a shell helper
printf 'source tests/lib2.sh\npanel_src .\n' > tests/q.sh            # calls the function that names the folder
printf 'source tests/lib2.sh\nother_fn\n' > tests/r.sh                # sources the same helper, calls another function
git add -A && git commit -qm base
BASE="$(git rev-parse HEAD)"
LABELS="$WORK/labels"; printf '%s\n' tests/a.sh tests/b.sh tests/c.js tests/e.sh tests/kappa.js tools/sprint-check-go tests/ghost.sh tests/g.sh tests/h.sh tests/i.sh tests/j.sh tests/s.sh tests/w.js tests/p.js tests/q.sh tests/r.sh > "$LABELS"

source "$REPO/scripts/test-select.sh"
selected() {   # selected <base>: the labels select_suite picks, space-joined, or FULL:<reason>
  local l out=""
  select_init "$REPO" "$1" "$LABELS" || return $?
  while IFS= read -r l; do if select_suite "$l"; then out+="${out:+ }$l"; fi; done < "$LABELS"
  if [[ -n "$SELECT_FULL" ]]; then out="FULL[$out]"; fi
  select_cleanup; printf '%s' "$out"
}
reset() { git reset -q --hard "$BASE"; git clean -qfd; }

reset; echo more >> tools/alpha.sh; git commit -qam alpha
assert_eq "tests/a.sh tests/j.sh" "$(selected "$BASE")"                          # a committed change; alpha.sh is unique though big-alpha.sh exists
reset; echo more >> tools/delta.sh
assert_eq "tests/b.sh" "$(selected "$BASE")"                                     # a working-tree change, one level up
reset; echo more >> tools/gamma.txt
assert_eq "tests/c.js tests/kappa.js" "$(selected "$BASE")"                      # a base-name mention
reset; echo '// x' >> tests/c.js
assert_eq "tests/c.js" "$(selected "$BASE")"                                     # a changed suite runs itself
reset; echo '// x' >> tools/sprint-check-go/main.go
assert_eq "tools/sprint-check-go tests/g.sh" "$(selected "$BASE")"               # its Go package, and (safe side) a suite naming any main.go
reset; echo '// x' >> tools/app/widgets/dial.js
assert_eq "tests/w.js" "$(selected "$BASE")"                                     # a suite that lists the changed file's folder (t-2633 eval)
reset; echo '// x' >> tools/app/panels/knob.js
assert_eq "tests/p.js tests/q.sh" "$(selected "$BASE")"                         # through a JS helper, and through one shell-helper function (t-2633 eval 2)
reset; echo more >> skills/one/SKILL.md
assert_eq "tests/s.sh" "$(selected "$BASE")"                                     # a shared name a suite only spells as a file name (t-2633 eval)
reset; echo more >> tools/delta2.sh
assert_eq "tests/h.sh" "$(selected "$BASE")"                                     # an extensionless referrer matches by path, not by the word
reset; echo more >> LEARNINGS.md; git commit -qam learnings
assert_eq "" "$(selected "$BASE")"                                               # evidence-neutral only: nothing to run
reset; echo more >> tools/zeta.sh
assert_eq "tests/e.sh" "$(selected "$BASE")"                                     # one level up, by file name only
reset; echo k > tests/kappa; git add tests/kappa; git commit -qm kappa
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tests/e.sh tests/kappa.js tools/sprint-check-go tests/ghost.sh tests/g.sh tests/h.sh tests/i.sh tests/j.sh tests/s.sh tests/w.js tests/p.js tests/q.sh tests/r.sh]" "$(selected "$BASE")"   # tests/kappa is not tests/kappa.js
reset; echo more >> tools/alpha.sh; select_init "$REPO" "$BASE" "$LABELS"
if select_suite tests/ghost.sh 2> "$WORK/ghost.err"; then fail "a label with no file was selected"; fi
assert_eq "" "$(cat "$WORK/ghost.err")"; select_cleanup                         # and no grep error for it
reset; echo more >> tools/orphan.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tests/e.sh tests/kappa.js tools/sprint-check-go tests/ghost.sh tests/g.sh tests/h.sh tests/i.sh tests/j.sh tests/s.sh tests/w.js tests/p.js tests/q.sh tests/r.sh]" "$(selected "$BASE")"   # named by nothing: everything
reset; echo more >> tests/not-a-suite.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tests/e.sh tests/kappa.js tools/sprint-check-go tests/ghost.sh tests/g.sh tests/h.sh tests/i.sh tests/j.sh tests/s.sh tests/w.js tests/p.js tests/q.sh tests/r.sh]" "$(selected "$BASE")"   # in tests/ but no suite: everything
reset; echo more >> tools/alpha.sh; echo more >> tools/orphan.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tests/e.sh tests/kappa.js tools/sprint-check-go tests/ghost.sh tests/g.sh tests/h.sh tests/i.sh tests/j.sh tests/s.sh tests/w.js tests/p.js tests/q.sh tests/r.sh]" "$(selected "$BASE")"   # one unmapped path is enough
reset; echo new > tools/untracked.sh
assert_eq "" "$(selected "$BASE")"                                               # untracked files are not seen ...
git add -N tools/untracked.sh
assert_eq "FULL[tests/a.sh tests/b.sh tests/c.js tests/e.sh tests/kappa.js tools/sprint-check-go tests/ghost.sh tests/g.sh tests/h.sh tests/i.sh tests/j.sh tests/s.sh tests/w.js tests/p.js tests/q.sh tests/r.sh]" "$(selected "$BASE")"   # ... until intent-added
reset
set +e; out="$(selected not-a-ref 2>&1)"; rc=$?; set -e
assert_eq 2 "$rc"; assert_contains "$out" "test.sh --changed: 'not-a-ref' is not a commit"
assert_eq "" "$(ls "$TMPDIR" | grep '^test-select\.' || true)"                  # select_cleanup removes its temp files

# --- the real scripts/test.sh: --list -------------------------------------------------------------------------------------------
LIST="$(bash "$ROOT/scripts/test.sh" --list)"
assert_eq "" "$(printf '%s\n' "$LIST" | sort | uniq -d)"                        # no suite listed twice
while IFS= read -r l; do [[ -e "$ROOT/$l" ]] || fail "test.sh --list names $l, which does not exist"; done <<< "$LIST"
# the dry pass reaches every invocation in the file: the .sh labels are the tests=( array, the .js labels every node line, plus the Go three
assert_eq "$(awk '/^tests=\(/{f=1;next} /^\)/{f=0} f' "$ROOT/scripts/test.sh" | grep -c 'tests/')" "$(printf '%s\n' "$LIST" | grep -c '\.sh$')"
assert_eq "$(grep -c '^  suite tests/[^ ]*\.js node "\$ROOT/tests/' "$ROOT/scripts/test.sh")" "$(printf '%s\n' "$LIST" | grep -c '\.js$')"
for g in tools/sprint-check-go tools/sprint-headless-json-go tools/cockpit-daemon; do assert_contains "$LIST" "$g"; done
assert_contains "$LIST" "tests/test-sh-changed.sh"
set +e; out="$(bash "$ROOT/scripts/test.sh" --help 2>&1)"; rc=$?; set -e
assert_eq 0 "$rc"; assert_contains "$out" "usage: scripts/test.sh [--changed [<base>] | --list]"
set +e; out="$(bash "$ROOT/scripts/test.sh" --bogus 2>&1)"; rc=$?; set -e; assert_eq 2 "$rc"; assert_contains "$out" "unknown option --bogus"

# --- copies of the real runner with fake suites; go and node kept off PATH -----------------------------------------------------------
mkdir -p "$WORK/bin"
for b in bash sh git sort head tail mktemp grep sed awk cat rm sleep dirname cut wc tr comm ps pgrep uniq basename env ls; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$WORK/bin/$b"
done
runner_copy() {   # runner_copy <dir> <suite...>: the real test.sh with its tests=( list replaced by the given suites
  local d="$1"; shift
  mkdir -p "$d/scripts" "$d/tests" "$d/tools"
  cp "$ROOT/scripts/test-select.sh" "$d/scripts/"; cp "$ROOT/tools/evidence-neutral.sh" "$d/tools/"
  { awk '/^tests=\(/{exit} {print}' "$ROOT/scripts/test.sh"; echo 'tests=('; for t in "$@"; do echo "  \"\$ROOT/$t\""; done; echo ')'
    awk 'f; /^tests=\(/{s=1} s && /^\)/{f=1}' "$ROOT/scripts/test.sh"; } > "$d/scripts/test.sh"
}
leftovers() { ls "$TMPDIR" | grep -E '^test-(select|labels)\.' || true; }

# A full run: twelve timed suites, the slowest first, the failing one timed and marked, the run's own exit code kept.
T="$WORK/runner"; names=(tests/slow.sh); for k in 01 02 03 04 05 06 07 08 09 10; do names+=("tests/t$k.sh"); done; names+=(tests/bad.sh)
runner_copy "$T" "${names[@]}"
printf 'sleep 2\necho slow-ok\n' > "$T/tests/slow.sh"; printf 'sleep 1\necho bad-runs; exit 3\n' > "$T/tests/bad.sh"
for k in 01 02 03 04 05 06 07 08 09 10; do echo 'true' > "$T/tests/t$k.sh"; done
set +e; out="$(PATH="$WORK/bin" bash "$T/scripts/test.sh" 2>&1)"; rc=$?; set -e
assert_eq 3 "$rc"                                                                  # the failing suite's own code
assert_contains "$out" "==> tests/slow.sh"; assert_contains "$out" "slow-ok"; assert_contains "$out" "==> tests/bad.sh"
assert_contains "$out" "== suite times (s), in run order"; assert_contains "$out" "== total "; assert_contains "$out" "for 12 suite(s)"
slowest="$(printf '%s\n' "$out" | sed -n '/^== slowest 10 (s)$/,/^== total/p' | sed '1d;$d')"
assert_eq 10 "$(printf '%s\n' "$slowest" | wc -l | tr -d ' ')"
[[ "$(printf '%s\n' "$slowest" | head -1)" =~ ^[2-9]\ tests/slow\.sh$ ]] || fail "test.sh: slowest 10 must start with the slow suite: $slowest"
[[ "$out" =~ (^|$'\n')[1-9][0-9]*\ tests/bad\.sh\ \(failed\) ]] || fail "test.sh: the failing suite's time is missing or zero: $out"
[[ "$out" != *"PARTIAL RUN"* ]] || fail "test.sh: a full run must not call itself partial"

# --changed end to end, in a git repo with an origin: a.sh names alpha.sh, b.sh names nothing.
R="$WORK/proj"; runner_copy "$R" tests/a.sh tests/b.sh
printf 'echo a-ran # alpha.sh\n' > "$R/tests/a.sh"; echo 'echo b-ran' > "$R/tests/b.sh"; echo alpha > "$R/tools/alpha.sh"
(cd "$R" && git init -q -b main . && git config user.name t && git config user.email t@t && git add -A && git commit -qm base
 git init -q --bare "$WORK/origin.git" && git remote add origin "$WORK/origin.git" && git push -q origin main)
RBASE="$(git -C "$R" rev-parse HEAD)"
tsh() { set +e; out="$(cd "$R" && PATH="$WORK/bin" bash scripts/test.sh "$@" 2>&1)"; rc=$?; set -e; }
tsh --changed
assert_eq 0 "$rc"; assert_contains "$out" "PARTIAL RUN (--changed): 0 changed path(s) since ${RBASE:0:8}, 17 suite(s) known"
assert_contains "$out" "test.sh --changed: nothing changed outside the evidence-neutral docs; no suite to run"; assert_eq "" "$(leftovers)"
tsh --list; assert_eq 0 "$rc"; assert_eq 17 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"; [[ "$out" != *"==>"* ]] || fail "--list printed a run line: $out"   # go and node absent
echo more >> "$R/tools/alpha.sh"; git -C "$R" commit -qam alpha
tsh --changed
assert_eq 0 "$rc"; assert_contains "$out" "PARTIAL RUN (--changed): 1 changed path(s) since ${RBASE:0:8}"
assert_contains "$out" "==> tests/a.sh"$'\n'"a-ran"; assert_contains "$out" "==> tests/b.sh skipped (--changed)"
assert_contains "$out" "test.sh --changed: a fast pass by text search; a suite that builds paths at run time can be missed, so only the full run is evidence"
[[ "$out" != *"b-ran"* ]] || fail "test.sh --changed ran a suite it skipped"
for skipped_line in "==> tools/sprint-check-go skipped (go absent)" "==> tools/sprint-headless-json-go skipped (go absent)" \
  "==> tools/cockpit-daemon skipped (go absent)" "==> tests/sprint-check-gherkin.js skipped (node absent)"; do
  assert_eq 1 "$(printf '%s\n' "$out" | grep -cxF "$skipped_line")"           # once: never from the dry pass
done
assert_contains "$out" "PARTIAL RUN (--changed): ran 1, skipped 1 — not a close stamp"; assert_eq "" "$(leftovers)"
tsh --changed "$RBASE"; assert_eq 0 "$rc"; assert_contains "$out" "ran 1, skipped 1"     # an explicit base
[[ "$out" != *"untracked path(s) not seen"* ]] || fail "no untracked file, yet the banner says some"
echo new > "$R/tools/brand-new.sh"
tsh --changed "$RBASE"; assert_eq 0 "$rc"; assert_contains "$out" "test.sh --changed: 1 untracked path(s) not seen; git add -N a new file to include it"
rm "$R/tools/brand-new.sh"
tsh --changed HEAD; assert_eq 0 "$rc"; assert_contains "$out" "0 changed path(s)"         # nothing since HEAD
echo zz > "$R/tools/zz.sh"; git -C "$R" add tools/zz.sh; git -C "$R" commit -qm zz
tsh --changed
assert_eq 0 "$rc"; assert_contains "$out" "test.sh --changed: running every suite: tools/zz.sh maps to no suite"
assert_contains "$out" "a-ran"; assert_contains "$out" "b-ran"; assert_contains "$out" "ran 2, skipped 0"
tsh --changed --bogus; assert_eq 2 "$rc"; assert_contains "$out" "unknown option --bogus"   # an option is not a base
tsh --changed not-a-ref; assert_eq 2 "$rc"; assert_contains "$out" "'not-a-ref' is not a commit"
tsh; assert_eq 0 "$rc"; assert_contains "$out" "a-ran"; assert_contains "$out" "b-ran"; [[ "$out" != *"PARTIAL RUN"* ]] || fail "full run called itself partial"
git -C "$R" remote remove origin
tsh --changed; assert_eq 2 "$rc"; assert_contains "$out" "test.sh --changed: no origin/main to diff against; pass a base"
assert_eq "" "$(leftovers)"

echo "test-sh-changed: ok"
