#!/usr/bin/env bash
# mutant-sweep (t-1fac) — tools/mutant-sweep mutates only a diff's changed lines, runs each mutant's test in a fresh copy, and
# leaves no process, temp folder or edit behind after a run, a timeout or a TERM. Everything runs in throwaway git repos.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TOOL="$ROOT/tools/mutant-sweep"
command -v node >/dev/null || fail "mutant-sweep: node not found (needed for the JS cases)"

T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/mutant-sweep-test.XXXXXX")"
PIDS="$WORK/pids"; TESTS="$WORK/tests"; : > "$PIDS"; : > "$TESTS"
reap() {   # a broken tool can leave its tests running: stop exactly the pids (and groups) they recorded
  local pid
  while read -r pid; do kill -KILL -- "-$pid" "$pid" 2>/dev/null || true; done < <(cat "$TESTS" "$PIDS" 2>/dev/null)
}
trap 'reap; rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" CANON_HOME="$WORK/canon-home"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"     # the tool's temp root lands here, so a leak is visible
REPO="$WORK/repo"
mkdir -p "$REPO/tests" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t

put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
put weak.sh '#!/usr/bin/env bash
old() { [[ "$1" == a ]]; }'
put strong.sh '#!/usr/bin/env bash'
put weak.js 'const old = (a) => a === 1;'
put loop.sh '#!/usr/bin/env bash'
put other.sh '#!/usr/bin/env bash'
put x.py 'x = 1'
git add -A && git commit -q -m base
BASE="$(git rev-parse HEAD)"

# The changed lines: one per operator family, so a test that always passes lets every valid mutant survive and be listed.
cat >> weak.sh <<'EOF'
is_json() { [[ "$1" == *.json && ! -L "$1" ]] || return 1; }
pick() { [[ $1 -lt 3 ]] && echo "low"; sort -u "$2" | uniq; }
[[ $x =~ ^ab$ ]] || exit 2
if [[ "$y" == cfg.json ]]; then
  echo true
fi
EOF
cat >> weak.js <<'EOF'
const f = (a, b, s) => { if (a !== 1 && b <= 2) return !s; return /^x$/.test(s) ? [3, 1].sort() : false; };
EOF
cat >> strong.sh <<'EOF'
pick() { if [[ "$1" == yes ]]; then echo Y; else echo N; fi; }
EOF
put tests/t-strong.sh '#!/usr/bin/env bash
source ./strong.sh
[[ "$(pick yes)" == Y && "$(pick no)" == N ]] || { echo "FAIL: pick"; exit 1; }'
cat >> loop.sh <<'EOF'
[[ "$1" == go ]] || exit 0
while :; do sleep 1; done
EOF
# The loop test leaves a background child in its process group and records it: every recorded pid must be gone afterwards.
put tests/t-loop.sh "#!/usr/bin/env bash
echo \$\$ >> '$TESTS'
sleep 300 & echo \$! >> '$PIDS'
bash ./loop.sh stop"
echo 'echo hi' >> other.sh
echo 'y = 2' >> x.py
git add -A && git commit -q -m change

TREE_BEFORE="$(git status --porcelain; find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum)"

bounded() {   # bounded <cmd...>: stdout+stderr in $out, exit code in $code; a run still going after 120 s fails the suite
  "$@" > "$WORK/out" 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( ++n > 1200 )); then kill -KILL "$pid"; fail "mutant-sweep: still running after 120 s: $*"; fi
    sleep 0.1
  done
  set +e; wait "$pid"; code=$?; set -e
  out="$(cat "$WORK/out")"
}
sweep() { bounded "$TOOL" --base "$BASE" --jobs 4 "$@"; }

# --- only changed lines, every operator family --------------------------------------------------------------------------------
sweep --map weak.sh='true ./other.sh' --map weak.js=true --map x.py=true --report "$WORK/report.md"   # a command naming other.sh does not map it
[[ "$code" == 0 ]] || fail "mutant-sweep: weak sweep exited $code: $out"
[[ "$out" != *"weak.sh:2 "* ]] || fail "mutant-sweep: mutated an unchanged line: $out"
for want in \
  'weak.sh:3 cmp: == -> !=@' 'weak.sh:3 bool: || -> &&@' 'weak.sh:3 negation: drop !@' 'weak.sh:3 code: return 1 -> return 0@' \
  'weak.sh:3 drop-conjunct: left of &&@' 'weak.sh:3 drop-conjunct: right of &&@' 'weak.sh:3 drop-conjunct: right of ||@' \
  'weak.sh:3 empty-string: "$1"@' 'weak.sh:3 delete-line |' \
  'weak.sh:4 cmp: -lt -> -ge@' 'weak.sh:4 off-by-one: -lt -> -le@' 'weak.sh:4 bool: && -> ||@' 'weak.sh:4 sort: sort -u -> sort@' \
  'weak.sh:4 sort: drop uniq@' \
  'weak.sh:5 drop-anchor: ^@' 'weak.sh:5 drop-anchor: $@' 'weak.sh:5 code: exit 2 -> exit 0@' \
  'weak.sh:6 widen: cfg.json -> cfg.*@' 'weak.sh:7 bool: true -> false@' \
  'weak.js:2 cmp: !== -> ===@' 'weak.js:2 cmp: <= -> >@' 'weak.js:2 off-by-one: <= -> <@' 'weak.js:2 bool: && -> ||@' \
  'weak.js:2 negation: drop !@' 'weak.js:2 drop-anchor: ^@' 'weak.js:2 drop-anchor: $@' "weak.js:2 sort: .sort() -> ''@" \
  'weak.js:2 bool: false -> true@' 'weak.js:2 drop-conjunct: left of &&@'; do
  assert_contains "$out" "$want"
done
assert_contains "$out" "unsupported: x.py"
assert_contains "$out" "unmapped: other.sh"
[[ "$out" =~ INVALID\ [1-9] ]] || fail "mutant-sweep: deleting the 'if' line should be INVALID: $out"
[[ "$out" =~ KILLED\ 0 ]] || fail "mutant-sweep: a test that always passes killed something: $out"
assert_contains "$(cat "$WORK/report.md")" "| weak.sh:3 | \`cmp: == -> !=@"
assert_contains "$(cat "$WORK/report.md")" "| weak.sh:3 | \`bool: \\|\\| -> &&@"   # a | in a cell would split the table row

# --- a test with teeth kills every mutant, quoting its FAIL line ---------------------------------------------------------------
sweep --map strong.sh='bash tests/t-strong.sh'
[[ "$code" == 0 ]] || fail "mutant-sweep: strong sweep exited $code: $out"
[[ "$out" =~ SURVIVED\ 0 ]] || fail "mutant-sweep: the strong test let a mutant survive: $out"
[[ "$out" =~ KILLED\ [1-9] ]] || fail "mutant-sweep: no KILLED count: $out"

# --- timeout: the whole process group dies, background children included -------------------------------------------------------
sweep --timeout 3 --map loop.sh='bash tests/t-loop.sh'
[[ "$code" == 0 ]] || fail "mutant-sweep: loop sweep exited $code: $out"
[[ "$out" =~ KILLED\(timeout\)\ [1-9] ]] || fail "mutant-sweep: the looping mutant was not KILLED(timeout): $out"
[[ "$(wc -l < "$PIDS")" -ge 2 ]] || fail "mutant-sweep: the loop test recorded no children"
while read -r pid; do
  ! kill -0 "$pid" 2>/dev/null || { kill "$pid"; fail "mutant-sweep: test child $pid outlived its mutant"; }
done < "$PIDS"

# --- refusals run nothing ----------------------------------------------------------------------------------------------------
MARK="$WORK/ran"
bounded "$TOOL" --base nope --map weak.sh="touch '$MARK'"
assert_eq 2 "$code"; assert_contains "$out" "--base nope is not a commit"
bounded "$TOOL" --map weak.sh="touch '$MARK'"   # no origin/main here
assert_eq 2 "$code"; assert_contains "$out" "git merge-base HEAD origin/main failed"
printf '#!/usr/bin/env bash\necho x\n' > "$WORK/x.sh"   # exists, so only the guard can refuse it
for bad in ../x.sh "$WORK/x.sh"; do
  bounded "$TOOL" --base "$BASE" --map "$bad=touch '$MARK'"
  assert_eq 2 "$code"; assert_contains "$out" "--map file must be inside the project: $bad"
done
[[ ! -e "$MARK" ]] || fail "mutant-sweep: a refused sweep ran its test"
sweep --map weak.sh="echo run >> '$MARK'; exit 3"
assert_eq 1 "$code"; assert_contains "$out" "baseline fails: echo run"
assert_eq 1 "$(grep -c . "$MARK")"     # the baseline only, no mutant
bounded "$TOOL" --base "$(git rev-parse HEAD)" --map weak.sh="touch '$MARK.none'"   # no changed line: no mutant, no baseline
assert_eq 0 "$code"; [[ ! -e "$MARK.none" ]] || fail "mutant-sweep: ran a baseline with no mutants"

# --- TERM mid-run: every test stopped, temp root removed ------------------------------------------------------------------------
: > "$PIDS"
"$TOOL" --base "$BASE" --jobs 2 --timeout 60 --map weak.sh="sleep 120 & echo \$! >> '$PIDS'; wait" > "$WORK/term.out" 2>&1 &
SWEEP=$!
for _ in $(seq 100); do [[ "$(wc -l < "$PIDS")" -ge 2 ]] && break; sleep 0.1; done
[[ "$(wc -l < "$PIDS")" -ge 1 ]] || { kill "$SWEEP"; fail "mutant-sweep: TERM case never started a test"; }
kill -TERM "$SWEEP"
n=0   # promptly: the tests' own 60 s timeout would also end them, so waiting for it would hide a TERM that stops nothing
while kill -0 "$SWEEP" 2>/dev/null; do
  if (( ++n > 100 )); then kill -KILL "$SWEEP"; fail "mutant-sweep: still running 10 s after TERM"; fi
  sleep 0.1
done
set +e; wait "$SWEEP"; code=$?; set -e
assert_eq 130 "$code"
assert_contains "$(cat "$WORK/term.out")" "interrupted"
while read -r pid; do
  ! kill -0 "$pid" 2>/dev/null || { kill "$pid"; fail "mutant-sweep: test child $pid outlived a TERM'd sweep"; }
done < "$PIDS"
leftover="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'mutant-sweep.*')"
[[ -z "$leftover" ]] || fail "mutant-sweep: temp root left behind: $leftover"

# --- t-a5f6: no working Python 3 is a clean skip (exit 3), never a shebang error or a hang ---------------------------------------------
SKIP_MSG='mutant-sweep: skipped — no working python3 (record: mutation-test | skipped | no python3)'
BASH_BIN="$(command -v bash)"
stubs() {   # stubs <dir>: a PATH folder holding only what the launcher itself needs, and no interpreter
  mkdir -p "$1"; local b; for b in dirname sleep; do ln -sf "$(command -v "$b")" "$1/$b"; done
}
NOPY="$WORK/nopy"; stubs "$NOPY"
nopy_run() { bounded env PATH="$1" "$BASH_BIN" "$TOOL" "${@:2}"; }
nopy_run "$NOPY" --base "$BASE" --map weak.sh="touch '$MARK.py'"
assert_eq 3 "$code"; assert_contains "$out" "$SKIP_MSG"; [[ ! -e "$MARK.py" ]] || fail "mutant-sweep: ran a test with no Python"
STORE="$WORK/store"; stubs "$STORE"   # Windows' Store alias: on PATH, prints an install prompt, runs no Python
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store."\nexit 9009\n' > "$STORE/python3"
cp "$STORE/python3" "$STORE/python"; chmod +x "$STORE/python3" "$STORE/python"
nopy_run "$STORE" --check; assert_eq 3 "$code"; assert_contains "$out" "$SKIP_MSG"
PY2="$WORK/py2"; stubs "$PY2"   # a Python 2: runs whatever -c code it gets as Python 2 would, so a version-3 test is false, all else true
printf '#!/bin/sh\ncase "$2" in *"version_info[0] == 3"*) exit 1 ;; esac\nexit 0\n' > "$PY2/python"; chmod +x "$PY2/python"
nopy_run "$PY2" --check; assert_eq 3 "$code"
HANG="$WORK/hang"; stubs "$HANG"   # a probe that never returns: killed after 5 s by its PID
printf '#!/bin/sh\necho $$ > "%s/hang.pid"\nexec sleep 60\n' "$WORK" > "$HANG/python3"; chmod +x "$HANG/python3"
t0=$SECONDS; nopy_run "$HANG" --check
assert_eq 3 "$code"; (( SECONDS - t0 < 7 )) || fail "mutant-sweep: a hanging probe took $((SECONDS - t0)) s"
hp="$(cat "$WORK/hang.pid")"; ! kill -0 "$hp" 2>/dev/null || { kill "$hp"; fail "mutant-sweep: the hung probe $hp outlived the launcher"; }
FALL="$WORK/fall"; mkdir -p "$FALL"   # python3 broken, python is a real Python 3: the sweep runs on python
printf '#!/bin/sh\nexit 1\n' > "$FALL/python3"; chmod +x "$FALL/python3"; ln -sf "$(command -v python3)" "$FALL/python"
bounded env PATH="$FALL:$PATH" "$TOOL" --base "$BASE" --map weak.sh=true
assert_eq 0 "$code"; assert_contains "$out" "mutant-sweep: base"
bounded "$TOOL" --check; assert_eq 0 "$code"; assert_eq "" "$out"

# --- the real tree is untouched --------------------------------------------------------------------------------------------------
assert_eq "$TREE_BEFORE" "$(git status --porcelain; find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum)"

echo "PASS: mutant-sweep"
