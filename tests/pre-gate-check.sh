#!/usr/bin/env bash
# pre-gate-check (t-014f) — tools/pre-gate-check.sh, the stamped deterministic step before `sprint complete`'s gates, in a scratch
# git repo: a seeded shellcheck error must fail (non-zero, stamped `exit 1`, which `sprint check-evidence` refuses), a clean
# change prints exactly one line, a missing shellcheck is `skipped | no shellcheck` and never a pass, an unreadable .css is named
# under "not scanned", an unreferenced Bash function is listed as dead code while one an UNCHANGED file calls is not, and dead
# code never fails the check. Needs shellcheck installed: it fails loudly, never skips, when it is missing.
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
cd "$R"

[[ -f "$CANON_HOME/canary" && -z "$(ls -A "$TMPDIR")" ]] || fail "pre-gate-check: left a temp file behind"
echo "pre-gate-check: ok"
