#!/usr/bin/env bash
# pre-gate-check (t-014f) — tools/pre-gate-check.sh, the stamped deterministic step before `sprint complete`'s gates, in a scratch
# git repo: a seeded shellcheck error must fail (non-zero, stamped `exit 1`, which `sprint check-evidence` refuses), a clean
# change prints exactly one line, a missing shellcheck is `skipped | no shellcheck` and never a pass, an unreadable .css is named
# under "not scanned", an unreferenced Bash function is listed as dead code while one an UNCHANGED file calls is not, and dead
# code never fails the check. Needs shellcheck installed: it fails loudly, never skips, when it is missing.
# t-08ea: also in a checkout with no .tickets/ of its own (CANON_TICKETS_DIR), and, with a stub evidence.sh, when no readable log is named.
# Protects the pre-gate step of `sprint complete` (skills/sprint/reference/complete.md).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
command -v shellcheck >/dev/null 2>&1 || fail "pre-gate-check: shellcheck is not installed (apt install shellcheck / brew install shellcheck); this test needs it"

PG="$ROOT/tools/pre-gate-check.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C
# Hermetic: a canary proves nothing here writes into the caller's TMPDIR or CANON_HOME.
mkdir -p "$WORK/tmp" "$WORK/home"; : > "$WORK/home/canary"
export TMPDIR="$WORK/tmp" CANON_HOME="$WORK/home"
unset CANON_TICKETS_DIR
export GOCACHE="$WORK/gocache" GOPATH="$WORK/gopath" GOTOOLCHAIN=local GOFLAGS=-mod=mod

ID=t-abcd
R="$WORK/repo"; mkdir -p "$R/tools" && cd "$R"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p ".tickets/$ID"; echo '# t' > ".tickets/$ID/ticket.md"
printf '#!/usr/bin/env bash\nunchanged_caller() { shared_helper; }\nunchanged_caller\n' > tools/caller.sh
git add tools && git add -f ".tickets/$ID/ticket.md" && git commit -qm base
BASE="$(git rev-parse HEAD)"

run() { set +e; out="$(cd "$R" && PRE_GATE_BASE="$BASE" bash "$PG" "$@" 2>&1)"; code=$?; set -e; }
reset() { git reset -q --hard "$BASE"; git clean -fdq -e .tickets; rm -rf ".tickets/$ID/evidence"; }
commit() { git add -A && git commit -qm change; }

# --- clean change: one line, stamped ---
reset
printf '#!/usr/bin/env bash\necho ok\n' > tools/clean.sh; commit
run "$ID"
assert_eq 0 "$code"
assert_eq 1 "$(wc -l <<<"$out" | tr -d ' ')"
assert_contains "$out" "pre-gate | shellcheck 1 ok" "pre-gate-check: clean line"
assert_contains "$out" "not scanned: none" "pre-gate-check: nothing unscanned"
[[ "$(tail -n1 ".tickets/$ID/evidence/pre-gate.log")" == "exit 0" ]] || fail "pre-gate-check: log not stamped with exit 0"

# --- seeded shellcheck error: fails ---
reset
printf '#!/usr/bin/env bash\ncd "$1"\nls\n' > tools/bad.sh; commit
run "$ID"
[[ "$code" != 0 ]] || fail "pre-gate-check: a seeded shellcheck error passed"
assert_contains "$out" "shellcheck FAIL" "pre-gate-check: failure line"
assert_contains "$out" "SC2164" "pre-gate-check: the tool's own finding is shown"
[[ "$(tail -n1 ".tickets/$ID/evidence/pre-gate.log")" == "exit 1" ]] || fail "pre-gate-check: failing log not stamped exit 1"

# --- info-level findings alone never refuse a close (SC2086 is info) ---
reset
printf '#!/usr/bin/env bash\necho $1\n' > tools/info.sh; commit
run "$ID"
assert_eq 0 "$code"

# --- node --check and go vet: pass, fail, one vet per package, nested package under its module ---
reset
printf 'const a = 1;\n' > tools/ok.js; commit
run "$ID"; assert_eq 0 "$code"; assert_contains "$out" "node --check 1 ok" "pre-gate-check: node ok"
printf 'function (\n' > tools/broken.js; commit
run "$ID"
[[ "$code" != 0 ]] || fail "pre-gate-check: a syntax error passed node --check"
assert_contains "$out" "node --check FAIL" "pre-gate-check: node failure line"
reset
mkdir -p gomod/sub
printf 'module m\n\ngo 1.21\n' > gomod/go.mod
printf 'package m\n\nfunc A() {}\n' > gomod/a.go; printf 'package m\n\nfunc B() {}\n' > gomod/b.go
printf 'package sub\n\nfunc C() {}\n' > gomod/sub/c.go; commit
run "$ID"; assert_eq 0 "$code"; assert_contains "$out" "go vet 2 pkg ok" "pre-gate-check: two packages (a.go and b.go share one), nested under the module root"
printf 'package sub\n\nimport "fmt"\n\nfunc D() { fmt.Printf("%%d", "x") }\n' > gomod/sub/d.go; commit
run "$ID"
[[ "$code" != 0 ]] || fail "pre-gate-check: a vet error passed"
assert_contains "$out" "go vet FAIL" "pre-gate-check: go vet failure line"

# --- shellcheck absent from PATH: skipped, never a pass ---
reset
printf '#!/usr/bin/env bash\necho ok\n' > tools/clean.sh; commit
NOSC="$WORK/nosc"; mkdir -p "$NOSC"
for c in bash git awk sed grep head tail paste dirname mktemp date uname rm mv chmod mkdir cat tr cut sort readlink wc env test; do
  p="$(command -v "$c" 2>/dev/null || true)"; [[ -x "$p" ]] && ln -sf "$p" "$NOSC/$c"
done
set +e; out="$(cd "$R" && PATH="$NOSC" PRE_GATE_BASE="$BASE" "$NOSC/bash" "$PG" "$ID" 2>&1)"; code=$?; set -e
assert_eq 0 "$code"
assert_contains "$out" "shellcheck skipped | no shellcheck" "pre-gate-check: missing tool is skipped"
printf 'const a = 1;\n' > tools/ok.js; printf 'package m\n' > gomod-x.go; commit
set +e; out="$(cd "$R" && PATH="$NOSC" PRE_GATE_BASE="$BASE" "$NOSC/bash" "$PG" "$ID" 2>&1)"; code=$?; set -e
assert_contains "$out" "node --check skipped | no node" "pre-gate-check: no node is skipped"
assert_contains "$out" "go vet skipped | no go" "pre-gate-check: no go is skipped"
[[ "$out" != *"shellcheck 1 ok"* ]] || fail "pre-gate-check: a missing shellcheck reported ok"

# --- dead code (advisory), a caller in an unchanged file, and a .css file ---
reset
printf '#!/usr/bin/env bash\nshared_helper() { :; }\norphan_fn() { :; }\n' > tools/lib.sh
printf 'a { color: red; }\n' > tools/style.css; commit
run "$ID"
assert_eq 0 "$code"   # dead code never fails the check
assert_contains "$out" "tools/lib.sh:3:orphan_fn" "pre-gate-check: unreferenced function listed"
[[ "$out" != *shared_helper* ]] || fail "pre-gate-check: a symbol only an unchanged file calls was reported dead"
assert_contains "$out" "not scanned: tools/style.css" "pre-gate-check: .css named under not scanned"

# --- refusals: a bad id, a dirty tree (nothing stamped), no baseline ---
reset
run "bad"; assert_eq 2 "$code"; assert_contains "$out" "usage: pre-gate-check.sh" "pre-gate-check: usage"
printf 'x\n' >> tools/caller.sh
run "$ID"; assert_eq 125 "$code"; assert_contains "$out" "commit first" "pre-gate-check: a dirty tree refuses"
[[ ! -e ".tickets/$ID/evidence/pre-gate.log" ]] || fail "pre-gate-check: a refused run wrote a log"
git checkout -q tools/caller.sh
set +e; out="$(cd "$R" && env -u PRE_GATE_BASE bash "$PG" "$ID" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "no git baseline" "pre-gate-check: no baseline fails loudly"

# --- a long dead-code list is capped with a count, never cut silently ---
reset
{ printf '#!/usr/bin/env bash\n'; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'dead_fn_%s() { :; }\n' "$i"; done; } > tools/many.sh; commit
run "$ID"; assert_eq 0 "$code"; assert_contains "$out" "+2 more" "pre-gate-check: dead-code list capped with a count"

# --- t-08ea: a checkout with NO .tickets/ of its own (a land worktree, a plain clone) stamps into the project's folder via CANON_TICKETS_DIR; the wrapper
# reads the log where evidence.sh wrote it, so a clean change still prints one line and exits 0 (it once recomputed the path under the checkout and exited 1) ---
PT="$WORK/project-tickets"; mkdir -p "$PT/$ID"; echo '# t' > "$PT/$ID/ticket.md"
R2="$WORK/clone"; mkdir -p "$R2/tools" && cd "$R2"
git init -q -b main . && git config user.name t && git config user.email t@t
echo base > base.txt; git add base.txt && git commit -qm base; BASE2="$(git rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho ok\n' > tools/clean.sh; git add tools && git commit -qm change
[[ ! -e .tickets ]] || fail "pre-gate-check: the clone must have no .tickets/ for this case"
set +e; out="$(cd "$R2" && CANON_TICKETS_DIR="$PT" PRE_GATE_BASE="$BASE2" bash "$PG" "$ID" 2>&1)"; code=$?; set -e
assert_eq 0 "$code" "pre-gate-check: a clean change in a checkout with no .tickets/ exits 0 (output: $out)"
assert_eq 1 "$(wc -l <<<"$out" | tr -d ' ')" "pre-gate-check: that run prints exactly one line (output: $out)"
[[ -f "$PT/$ID/evidence/pre-gate.log" && ! -e "$R2/.tickets" ]] || fail "pre-gate-check: the log must be under CANON_TICKETS_DIR and nothing under the checkout"
assert_eq "exit 0" "$(tail -1 "$PT/$ID/evidence/pre-gate.log")"
# the same checkout with a seeded shellcheck error still fails, and says what failed
printf '#!/usr/bin/env bash\ncd /nonexistent\nrm -rf *\n' > tools/bad.sh; git add tools && git commit -qm bad
set +e; out="$(cd "$R2" && CANON_TICKETS_DIR="$PT" PRE_GATE_BASE="$BASE2" bash "$PG" "$ID" 2>&1)"; code=$?; set -e
assert_eq 1 "$code" "pre-gate-check: a seeded shellcheck error in that checkout still exits 1 (output: $out)"
assert_contains "$out" "shellcheck FAIL" "pre-gate-check: the failure is named"
# when evidence.sh stamps but names no log (a stub playing it), the wrapper says so on stderr and exits with the stamp's code, never on a failed sed
S="$WORK/stub"; mkdir -p "$S"; cp "$PG" "$S/pre-gate-check.sh"; printf '#!/usr/bin/env bash\nexit "${STUB_RC:-0}"\n' > "$S/evidence.sh"; chmod +x "$S/evidence.sh"
set +e; out="$(cd "$R2" && STUB_RC=0 bash "$S/pre-gate-check.sh" "$ID" 2>&1)"; code=$?; set -e
assert_eq 0 "$code" "pre-gate-check: a stamp that succeeded keeps its exit code when no log is named (output: $out)"
assert_contains "$out" "evidence.sh did not name a readable log" "pre-gate-check: the missing log is said, not a sed error"
[[ "$out" != *"sed:"* ]] || fail "pre-gate-check: a sed error leaked: $out"
set +e; out="$(cd "$R2" && STUB_RC=1 bash "$S/pre-gate-check.sh" "$ID" 2>&1)"; code=$?; set -e
assert_eq 1 "$code" "pre-gate-check: a failed check's exit code survives a missing log (output: $out)"
printf 'HEAD x\n$ y\n# z\nok\nexit 0\n' > "$WORK/unreadable.log"; chmod 000 "$WORK/unreadable.log"
printf '#!/usr/bin/env bash\necho "evidence: wrote %s (HEAD abc1234, exit 0)" >&2\nexit 0\n' "$WORK/unreadable.log" > "$S/evidence.sh"
if [[ "$(id -u)" != 0 ]]; then
  set +e; out="$(cd "$R2" && bash "$S/pre-gate-check.sh" "$ID" 2>&1)"; code=$?; set -e
  assert_eq 0 "$code" "pre-gate-check: a named but unreadable log keeps the stamp's exit code"; assert_contains "$out" "did not name a readable log" "pre-gate-check: the unreadable log is said"
fi
chmod 644 "$WORK/unreadable.log"
mkdir -p "$WORK/dir.log"   # a named log that is a directory is not a log: the same message, the stamp's code, no sed on it
printf '#!/usr/bin/env bash\necho "evidence: wrote %s (HEAD abc1234, exit 0)" >&2\nexit 0\n' "$WORK/dir.log" > "$S/evidence.sh"
set +e; out="$(cd "$R2" && bash "$S/pre-gate-check.sh" "$ID" 2>&1)"; code=$?; set -e
assert_eq 0 "$code" "pre-gate-check: a log that is a directory keeps the stamp's exit code"; assert_contains "$out" "did not name a readable log" "pre-gate-check: a directory is not read as a log"
cd "$R"

# --- t-2178: the gate eval set. No tests/gate-cases/: nothing added. A passing run case: `gate cases 1/1` (a recorded case is not counted). A failing case:
# non-zero, stamped, named in the output. Protects the pre-gate line that every close prints.
reset
printf '#!/usr/bin/env bash\necho ok\n' > tools/clean.sh; commit
run "$ID"; assert_eq 0 "$code" "pre-gate-check: without tests/gate-cases/ the check is unchanged"
[[ "$out" != *"gate cases"* ]] || fail "pre-gate-check: a project with no gate cases printed a gate cases field: $out"
mkdir -p tests/gate-cases/ok-case tests/gate-cases/note-case
printf -- '---\ngate: guard\nkind: run\nmiss: a guard that must exit 3\ncmd: exit 3\nexpect_exit: 3\n---\n' > tests/gate-cases/ok-case/case.md
printf -- '---\ngate: reviewer\nkind: recorded\nmiss: a false positive\nexpect: no finding\n---\n' > tests/gate-cases/note-case/case.md
git add tests && git commit -qm cases
run "$ID"; assert_eq 0 "$code" "pre-gate-check: passing gate cases keep the exit code"; assert_contains "$out" "| gate cases 1/1 |"
rm -rf ".tickets/$ID/evidence"
mkdir -p tests/gate-cases/bad-case
printf -- '---\ngate: guard\nkind: run\nmiss: a guard that stopped catching its miss\ncmd: exit 0\nexpect_exit: 1\n---\n' > tests/gate-cases/bad-case/case.md
git add tests && git commit -qm bad-case
run "$ID"; assert_eq 1 "$code" "pre-gate-check: a failing gate case is non-zero"
assert_contains "$out" "gate cases FAIL 1/2"; assert_contains "$out" "FAIL      bad-case (guard): expected exit 1, got 0"
git reset -q --hard "$BASE"; git clean -fdq -e .tickets; rm -rf ".tickets/$ID/evidence"
# the summary is the LAST `gate cases:` line (a failing case's output may print one), and a skipped case is named, not failed
mkdir -p tests/gate-cases/liar tests/gate-cases/needs-nothing
printf -- '---\ngate: guard\nkind: run\nmiss: prints a fake summary\ncmd: echo "gate cases: 9 of 9 pass, 0 recorded"; exit 0\nexpect_exit: 1\n---\n' > tests/gate-cases/liar/case.md
printf -- '---\ngate: guard\nkind: run\nmiss: needs a tool nobody has\nneeds: no-such-tool-for-pre-gate\ncmd: true\nexpect_exit: 0\n---\n' > tests/gate-cases/needs-nothing/case.md
git add tests && git commit -qm liar
run "$ID"; assert_eq 1 "$code"; assert_contains "$out" "gate cases FAIL 0/1 (1 skipped)"
git reset -q --hard "$BASE"; git clean -fdq -e .tickets; rm -rf ".tickets/$ID/evidence"
mkdir -p tests/gate-cases/needs-nothing; printf -- '---\ngate: guard\nkind: run\nmiss: needs a tool nobody has\nneeds: no-such-tool-for-pre-gate\ncmd: true\nexpect_exit: 0\n---\n' > tests/gate-cases/needs-nothing/case.md
git add tests && git commit -qm needs
run "$ID"; assert_eq 0 "$code" "pre-gate-check: a skipped case never fails the check"; assert_contains "$out" "| gate cases 0/0 (1 skipped) |"
git reset -q --hard "$BASE"; git clean -fdq -e .tickets; rm -rf ".tickets/$ID/evidence"

# --- t-835f: the advisory size field. Protects the pre-gate line every close prints (the reviewer quotes it). No plan.md: skipped, exit 0.
reset
printf '#!/usr/bin/env bash\necho ok\n' > tools/clean.sh; commit
run "$ID"; assert_eq 0 "$code"; assert_contains "$out" "| size: skipped | no plan.md" "pre-gate-check: no plan.md is skipped, never a pass"
# the repo's tools/ has no size-caps.tsv: the script's own table is read from its own directory, so a stub dir without one says so
reset
printf '#!/usr/bin/env bash\necho ok\n' > tools/planned.sh
printf '#!/usr/bin/env bash\necho ok\n' > tools/stray.sh
mkdir -p lib; printf 'x\n' > lib/under.txt
seq 1 600 | sed 's/^/echo /' | { printf '#!/usr/bin/env bash\n'; cat; } > tools/big.sh
commit
printf '# Plan\n\n## Files\ntools/planned.sh; tools/big.sh; lib/\n\n## Decisions\ntools/stray.sh is named here, outside Files\n' > ".tickets/$ID/plan.md"
run "$ID"; assert_eq 0 "$code" "pre-gate-check: size flags never change the exit code"
assert_contains "$out" "size (advisory): planned 3 files, changed 4, +606/-0;" "pre-gate-check: planned/changed/+A/-D"
assert_contains "$out" "unplanned: tools/stray.sh" "pre-gate-check: a file only named outside ## Files is unplanned"
[[ "$out" == *"unplanned: tools/stray.sh;"* ]] || fail "pre-gate-check: a dir/ entry must name the files under it: $out"
assert_contains "$out" "large: tools/big.sh +601" "pre-gate-check: a file over file-net"
assert_contains "$out" "no test: lib/under.txt tools/big.sh tools/planned.sh tools/stray.sh" "pre-gate-check: new source files and no test in the diff"
grep -q "size (advisory)" ".tickets/$ID/evidence/pre-gate.log" || fail "pre-gate-check: the size field is not in the stamped log"
# a test file in the diff clears no-test; a total over total-net is named
mkdir -p tests; printf '#!/usr/bin/env bash\ntrue\n' > tests/one.sh; commit
run "$ID"; [[ "$out" != *"no test:"* ]] || fail "pre-gate-check: a test file in the diff must clear no test: $out"
seq 1 450 | sed 's/^/echo /' > tools/more.txt; seq 1 450 | sed 's/^/echo /' > tools/more2.txt; commit
run "$ID"; assert_contains "$out" "; total +1" "pre-gate-check: total over total-net"
# no test file in the diff: a modified source file and a new .tickets file raise no `no test:`; a new non-ASCII source file does, named as is
reset
printf '# c\n' >> tools/caller.sh; printf 'x\n' > ".tickets/$ID/extra.txt"
printf '# Plan\n\n## Files\ntools/caller.sh\n' > ".tickets/$ID/plan.md"; git add -A -f . && git commit -qm modonly
run "$ID"; assert_contains "$out" "size (advisory): planned 1 files, changed 1, +1/-0; flags none" "pre-gate-check: no test file in the diff, no new source file: no flag"
printf '#!/usr/bin/env bash\ntrue\n' > "tools/ü.sh"; commit
run "$ID"; assert_contains "$out" "no test: tools/ü.sh" "pre-gate-check: a new non-ASCII source file with no test is named as is"
# a new doc alone is not a new source file; a new *_test.go counts as the test for a new source file
reset
mkdir -p docs; printf '# d\n' > docs/n.md; printf '# Plan\n\n## Files\ndocs/n.md\n' > ".tickets/$ID/plan.md"; git add -A -f . && git commit -qm doconly
run "$ID"; assert_contains "$out" "planned 1 files, changed 1, +1/-0; flags none" "pre-gate-check: a new .md is not a new source file"
printf '#!/usr/bin/env bash\ntrue\n' > tools/n.sh; printf 'package x\n' > x_test.go; commit
run "$ID"; [[ "$out" != *"no test:"* ]] || fail "pre-gate-check: a *_test.go in the diff must clear no test: $out"
# a plan saved with CRLF line endings (Windows) still names a dir/ entry; a glob character in a dir entry is literal, never expanded against the checkout
reset
mkdir -p generated lib; printf 'x\n' > generated/x.txt; printf 'x\n' > lib/y.txt
printf '# Plan\r\n\r\n## Files\r\nlib/\r\nge*/\r\n' > ".tickets/$ID/plan.md"; git add -A -f . && git commit -qm crlf
run "$ID"; assert_contains "$out" "planned 1 files, changed 2," "pre-gate-check: a CRLF plan names lib/, and ge*/ is not a glob"
assert_contains "$out" "unplanned: generated/x.txt" "pre-gate-check: a glob in a dir entry must not name generated/"
# more than 8 unplanned files: the first 8 are named, the rest counted; no limits table beside the script: skipped, not a pass
reset
for i in 1 2 3 4 5 6 7 8 9 10; do printf '#!/usr/bin/env bash\ntrue\n' > "tools/u$i.sh"; done; mkdir -p tests; printf '#!/usr/bin/env bash\ntrue\n' > tests/t.sh; commit
printf '# Plan\n\n## Files\ntests/t.sh\n' > ".tickets/$ID/plan.md"
run "$ID"; assert_contains "$out" "+2 more" "pre-gate-check: unplanned beyond 8 is counted"
set +e; out="$(cd "$R" && PRE_GATE_BASE="$BASE" PRE_GATE_ID="$ID" bash "$S/pre-gate-check.sh" --run 2>&1)"; set -e
assert_contains "$out" "size: skipped | no limits in size-caps.tsv" "pre-gate-check: a missing limits table is skipped"
# clean diff with every exclusion at once: a modified (not new) source file, a binary (numstat `-`), a .tickets file, the plan naming files
# with commas and backticks. Expect `flags none` and the exact counts; then a non-ASCII unplanned name is printed as is, not git-quoted.
reset
printf '# c\n' >> tools/caller.sh; mkdir -p tests; printf '\0\1\2' > tests/data.bin; printf 'x\n' > ".tickets/$ID/extra.txt"
printf '# Plan\n\n## Files\n`tools/caller.sh`, `tests/`\n' > ".tickets/$ID/plan.md"; git add -A -f . && git commit -qm clean
run "$ID"; assert_eq 0 "$code"
assert_contains "$out" "size (advisory): planned 2 files, changed 2, +1/-0; flags none" "pre-gate-check: a modified file, a binary and a .tickets file add no flag"
printf '#!/usr/bin/env bash\ntrue\n' > "tools/é.sh"; commit
run "$ID"; assert_contains "$out" "unplanned: tools/é.sh" "pre-gate-check: a non-ASCII name is not git-quoted"
# no .tickets/ in the checkout: the plan is read from CANON_TICKETS_DIR
reset
printf '#!/usr/bin/env bash\necho ok\n' > tools/a.sh; commit
mkdir -p "$WORK/tk/$ID"; printf '# Plan\n\n## Files\ntools/a.sh\n' > "$WORK/tk/$ID/plan.md"; mv .tickets "$WORK/tk-away"
CANON_TICKETS_DIR="$WORK/tk" run "$ID"; mv "$WORK/tk-away" .tickets
assert_contains "$out" "planned 1 files, changed 1," "pre-gate-check: the plan is read from CANON_TICKETS_DIR when the checkout has no .tickets/"
# a malformed limit is skipped, whichever limit and whichever end
printf '# Plan\n\n## Files\ntools/a.sh\n' > ".tickets/$ID/plan.md"
for bad in "abc	5" "5	abc" "x12	5" "12x	5" "5	12x"; do
  printf 'file-net\t%s\ntotal-net\t%s\n' "${bad%%$'\t'*}" "${bad##*$'\t'}" > "$S/size-caps.tsv"
  set +e; out="$(cd "$R" && PRE_GATE_BASE="$BASE" PRE_GATE_ID="$ID" bash "$S/pre-gate-check.sh" --run 2>&1)"; set -e
  assert_contains "$out" "size: skipped | no limits in size-caps.tsv" "pre-gate-check: limits '$bad' are skipped"
done
rm -f "$S/size-caps.tsv"
rm -f ".tickets/$ID/plan.md"; reset

# --- t-dc18: the advisory agent-files field. Protects the pre-gate line every close prints (the reviewer quotes it): an always-on agent file edit is named, never blocking.
reset
printf '#!/usr/bin/env bash\ntrue\n' > tools/x.sh; commit
run "$ID"; assert_eq 0 "$code"; assert_contains "$out" "| agent files (advisory): none" "pre-gate-check: no watched file changed reads none"
reset
mkdir -p sub docs standards; printf 'a\n' > CLAUDE.md; printf 'one\n\ntwo\nthree\nfour\nfive\n' > sub/AGENTS.md
printf 'Deploy the Playwright server with %s\r\n' "$(printf 'x%.0s' $(seq 1 100))" > PROMOTED.md
printf 'n\n' > docs/CLAUDE.md.txt; printf 'n\n' > standards/efficiency.md; printf 'n\n' > standards/other.md; printf 'n\n' > xCLAUDE.md
commit
run "$ID"; assert_eq 0 "$code" "pre-gate-check: agent file flags never change the exit code"
assert_contains "$out" 'agent files (advisory): CLAUDE.md +1/-0 "a"; PROMOTED.md +1/-0 "Deploy the Playwright server with ' "pre-gate-check: a root file and a PROMOTED.md are named with the added line"
assert_contains "$out" 'sub/AGENTS.md +6/-0 "one" "two" "three" +2 more' "pre-gate-check: a nested bare name matches; blank lines skipped; 3 lines then +N more"
assert_contains "$out" 'standards/efficiency.md +1/-0 "n"' "pre-gate-check: a path row matches that path"
[[ "$out" != *"standards/other.md +"* && "$out" != *"xCLAUDE.md +"* && "$out" != *"CLAUDE.md.txt +"* ]] || fail "pre-gate-check: an unwatched name must not match: $out"
[[ "$out" != *"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"* ]] || fail "pre-gate-check: an added line is cut to 80 characters: $out"
grep -q "agent files (advisory)" ".tickets/$ID/evidence/pre-gate.log" || fail "pre-gate-check: the agent files field is not in the stamped log"
# a deletion-only edit is named with no lines; a 9th file is counted, not listed
printf '' > sub/AGENTS.md; git add -A && git commit -qm del
run "$ID"; assert_contains "$out" 'sub/AGENTS.md +0/-0' "pre-gate-check: an emptied file is named"
reset
for i in 1 2 3 4 5 6 7 8 9 10; do mkdir -p "d$i"; printf 'n\n' > "d$i/AGENTS.md"; done; commit
run "$ID"; assert_contains "$out" "; +2 more files" "pre-gate-check: files beyond 8 are counted"
# no agent-file row: skipped, never none
reset
printf 'n\n' > CLAUDE.md; commit
printf 'file-net\t400\ntotal-net\t1000\n' > "$S/size-caps.tsv"
set +e; out="$(cd "$R" && PRE_GATE_BASE="$BASE" PRE_GATE_ID="$ID" bash "$S/pre-gate-check.sh" --run 2>&1)"; set -e
assert_contains "$out" "agent files: skipped | no agent-file rows in size-caps.tsv" "pre-gate-check: a table with no agent-file row is skipped"
rm -f "$S/size-caps.tsv"; reset

[[ -f "$CANON_HOME/canary" && -z "$(ls -A "$TMPDIR")" ]] || fail "pre-gate-check: left a temp file behind"
echo "pre-gate-check: ok"
