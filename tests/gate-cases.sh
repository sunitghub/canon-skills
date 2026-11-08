#!/usr/bin/env bash
# gate-cases (t-2178) — tools/gate-cases.sh, the gate eval set: `add` writes a case from a finding and refuses the shapes that would make a useless one,
# `run` checks guard cases in a scratch copy with HOME and CANON_HOME pinned and lists recorded (reviewer, evaluator) cases without running them, and the
# real cases in tests/gate-cases/ pass on the real guards while a deliberately weakened guard fails its case. Protects the case set that `pre-gate-check`
# runs at every close and the one command that turns a gate miss into a case. Everything runs in scratch folders; the weakened guards are copies.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
G="$ROOT/tools/gate-cases.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C
mkdir -p "$WORK/tmp" "$WORK/home"; : > "$WORK/home/canary"
export TMPDIR="$WORK/tmp" HOME="$WORK/home" CANON_HOME="$WORK/home/canon"
CASES="$WORK/cases"; export GATE_CASES_DIR="$CASES"
rc() { set +e; out="$("$@" 2>&1)"; code=$?; set -e; }   # out and code of a command that may fail

# --- add: the shapes it refuses (nothing is written) ---
rc "$G" add --gate judge --slug a --miss m --expect e;                    assert_eq 2 "$code"; assert_contains "$out" "--gate must be"
rc "$G" add --gate guard --slug "Bad Slug" --miss m --cmd true --expect-exit 0; assert_eq 2 "$code"; assert_contains "$out" "--slug must be"
rc "$G" add --gate guard --slug a --cmd true --expect-exit 0;             assert_eq 2 "$code"; assert_contains "$out" "--miss is required"
rc "$G" add --gate guard --slug a --miss m;                               assert_eq 2 "$code"; assert_contains "$out" "a guard case needs --cmd"
rc "$G" add --gate guard --slug a --miss m --cmd true;                    assert_eq 2 "$code"; assert_contains "$out" "--expect-exit or --expect-text"
rc "$G" add --gate reviewer --slug a --miss m;                            assert_eq 2 "$code"; assert_contains "$out" "needs --expect"
rc "$G" add --gate reviewer --slug a --miss m --expect e --cmd true;      assert_eq 2 "$code"; assert_contains "$out" "recorded, not run"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit x;    assert_eq 2 "$code"; assert_contains "$out" "--expect-exit must be a number"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 0 --source nope; assert_eq 2 "$code"; assert_contains "$out" "--source must be a ticket id"
rc "$G" add --gate guard --slug a --miss "two"$'\n'"lines" --cmd true --expect-exit 0; assert_eq 2 "$code"; assert_contains "$out" "--miss must be one line"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 0 --state "$WORK/nope"; assert_eq 2 "$code"; assert_contains "$out" "--state is not a folder"
[[ ! -e "$CASES" ]] || fail "gate-cases: a refused add wrote a folder"

# --- add, then run: a pass, a wrong exit, a missing text, a recorded case, a malformed one ---
mkdir "$WORK/st"; printf 'hello\n' > "$WORK/st/data.txt"
rc "$G" add --gate guard --slug says-hello --source t-abcd --miss "a guard that must print hello" --cmd 'cat data.txt' --expect-exit 0 --expect-text hello --state "$WORK/st"
assert_eq 0 "$code"; assert_file_exists "$CASES/says-hello/case.md"; assert_file_exists "$CASES/says-hello/state/data.txt"
assert_grep "^gate: guard$" "$CASES/says-hello/case.md"; assert_grep "^kind: run$" "$CASES/says-hello/case.md"; assert_grep "^source: t-abcd$" "$CASES/says-hello/case.md"
rc "$G" add --gate guard --slug says-hello --miss m --cmd true --expect-exit 0; assert_eq 2 "$code"; assert_contains "$out" "already exists"
rc "$G" add --gate reviewer --slug a-false-positive --miss "flagged something that was fine" --expect "no finding"
assert_eq 0 "$code"; assert_grep "^kind: recorded$" "$CASES/a-false-positive/case.md"; assert_grep "^expect: no finding$" "$CASES/a-false-positive/case.md"
rc "$G" add --gate guard --slug open-guard-miss --miss "no guard catches this yet" --expect "the guard says X"
assert_eq 0 "$code"; assert_grep "^kind: recorded$" "$CASES/open-guard-miss/case.md"
rc "$G" run; assert_eq 0 "$code"
assert_contains "$out" "  ok        says-hello (guard)"; assert_contains "$out" "  recorded  a-false-positive (reviewer): flagged something that was fine"
assert_contains "$out" "gate cases: 1 of 1 pass, 2 recorded"
rc "$G" run --json; assert_eq 0 "$code"
assert_contains "$out" '"pass":1,"run":1,"recorded":2'; assert_contains "$out" '"slug":"says-hello"'; assert_contains "$out" '"result":"recorded"'
rc "$G" ls; assert_contains "$out" "says-hello  guard  run  a guard that must print hello"

# a command that runs in the scratch copy, never in the repo or the real HOME
rc "$G" add --gate guard --slug pinned-env --miss "a guard that must see the pinned environment" --cmd 'test "$HOME" != "'"$HOME"'" && test "$CANON_HOME" != "'"$CANON_HOME"'" && echo pinned' --expect-exit 0 --expect-text pinned
rc "$G" run; assert_contains "$out" "  ok        pinned-env (guard)"
rc "$G" add --gate guard --slug wrong-exit --miss "exits 0 where 1 is expected" --cmd true --expect-exit 1
rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "FAIL      wrong-exit (guard): expected exit 1, got 0"
assert_contains "$out" "gate cases: 2 of 3 pass, 2 recorded"
rm -rf "$CASES/wrong-exit"
rc "$G" add --gate guard --slug missing-text --miss "prints no hello" --cmd 'echo bye' --expect-exit 0 --expect-text hello
rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "expected the output to contain: hello"
rm -rf "$CASES/missing-text"
mkdir -p "$CASES/broken"; printf -- '---\ngate: guard\n---\n' > "$CASES/broken/case.md"
rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "FAIL      broken (guard): malformed case.md"
rm -rf "$CASES/broken"
mkdir -p "$CASES/bad-setup/state"; printf 'exit 4\n' > "$CASES/bad-setup/state/setup.sh"
printf -- '---\ngate: guard\nkind: run\nmiss: setup fails\ncmd: true\nexpect_exit: 0\n---\n' > "$CASES/bad-setup/case.md"
rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "setup.sh failed (exit 4)"
rm -rf "$CASES"
rc "$G" run; assert_eq 0 "$code"; assert_contains "$out" "gate cases: none"

# --- arguments, shapes and messages (each was a surviving mutant of the first version) ---
rc "$G";                              assert_eq 2 "$code"; assert_contains "$out" "usage: gate-cases.sh add"
rc "$G" bogus;                        assert_eq 2 "$code"; assert_contains "$out" "usage: gate-cases.sh add"
rc "$G" add --bogus x;                assert_eq 2 "$code"; assert_contains "$out" "unknown option: --bogus"
rc "$G" run --bogus;                  assert_eq 2 "$code"; assert_contains "$out" "unknown option: --bogus"
for flag in gate slug miss source cmd expect-exit expect-text expect state; do   # a flag with no value after it
  rc "$G" add "--$flag"; assert_eq 2 "$code"; assert_contains "$out" "--$flag needs a value"
done
rc "$G" add --gate guard --slug "ok!" --miss m --cmd true --expect-exit 0;       assert_eq 2 "$code"; assert_contains "$out" "--slug must be"
rc "$G" add --gate guard --slug "-lead" --miss m --cmd true --expect-exit 0;     assert_eq 2 "$code"; assert_contains "$out" "--slug must be"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 0 --source t-abcdx; assert_eq 2 "$code"; assert_contains "$out" "--source must be"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 0 --source xt-abcd; assert_eq 2 "$code"; assert_contains "$out" "--source must be"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 1x;          assert_eq 2 "$code"; assert_contains "$out" "--expect-exit must be"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit x1;          assert_eq 2 "$code"; assert_contains "$out" "--expect-exit must be"
rc "$G" add --gate reviewer --slug a --miss m --expect "a"$'\r'"b";              assert_eq 2 "$code"; assert_contains "$out" "--expect must be one line"
rc "$G" add --gate guard --slug a --miss m --cmd "a"$'\n'"b" --expect-exit 0;    assert_eq 2 "$code"; assert_contains "$out" "--cmd must be one line"
[[ ! -e "$CASES" ]] || fail "gate-cases: a refused add wrote a folder"

# no cases folder: text and JSON say so and exit 0; a folder inside the cases folder with no case.md is ignored
rc "$G" run; assert_eq 0 "$code"; assert_eq "gate cases: none (no $CASES)" "$out"
rc "$G" run --json; assert_eq 0 "$code"; assert_eq '{"pass":0,"run":0,"recorded":0,"cases":[]}' "$out"
rc "$G" ls; assert_eq 0 "$code"; assert_eq "gate cases: none (no $CASES)" "$out"
mkdir -p "$CASES/not-a-case" "$CASES/frontmatter-only"
rc "$G" run; assert_eq 0 "$code"; assert_eq "gate cases: 0 of 0 pass, 0 recorded" "$out"
rc "$G" ls; assert_eq "" "$out"

# the frontmatter ends at its second ---: a later "gate:" or "miss:" line in the body is not read, and a value may hold ": "
printf -- '---\ngate: guard\nkind: run\nmiss: a miss: with a colon\ncmd: echo "x: y"\nexpect_exit: 0\nexpect_text: x: y\n---\ngate: reviewer\nmiss: the body must not win\n' > "$CASES/frontmatter-only/case.md"
rc "$G" run --json; assert_eq 0 "$code"
assert_contains "$out" '"gate":"guard","kind":"run","result":"pass","miss":"a miss: with a colon"'
rc "$G" run; assert_contains "$out" "  ok        frontmatter-only (guard)"; assert_contains "$out" "gate cases: 1 of 1 pass, 0 recorded"
rm -rf "$CASES/frontmatter-only" "$CASES/not-a-case"

# every malformed shape is a failure that names the file's problem; a recorded case with no expect, a run case with no command or no expectation
mal() { mkdir -p "$CASES/mal"; printf -- '---\n%s\n---\n' "$1" > "$CASES/mal/case.md"; rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "FAIL      mal ($2): malformed case.md: $3"; rm -rf "$CASES/mal"; }
mal $'kind: run\nmiss: m\ncmd: true\nexpect_exit: 0' "" "it needs gate"
mal $'gate: guard\nmiss: m\ncmd: true\nexpect_exit: 0' guard "it needs gate"
mal $'gate: guard\nkind: run\ncmd: true\nexpect_exit: 0' guard "it needs gate"
mal $'gate: guard\nkind: maybe\nmiss: m\ncmd: true\nexpect_exit: 0' guard "it needs gate"
mal $'gate: reviewer\nkind: recorded\nmiss: m' reviewer "a recorded case needs expect"
mal $'gate: guard\nkind: run\nmiss: m\nexpect_exit: 0' guard "a run case needs cmd"
mal $'gate: guard\nkind: run\nmiss: m\ncmd: true' guard "a run case needs cmd"

# a command's output is shown only for a failure; a case with only expect_text, or only expect_exit, passes on that alone
mkdir -p "$CASES/text-only" "$CASES/exit-only" "$CASES/shows-output"
printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: echo needle; exit 7\nexpect_text: needle\n---\n' > "$CASES/text-only/case.md"
printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: echo anything; exit 7\nexpect_exit: 7\n---\n' > "$CASES/exit-only/case.md"
printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: echo THE-OUTPUT; exit 0\nexpect_exit: 5\n---\n' > "$CASES/shows-output/case.md"
rc "$G" run; assert_eq 1 "$code"
assert_contains "$out" "  ok        text-only (guard)"; assert_contains "$out" "  ok        exit-only (guard)"
assert_contains "$out" "FAIL      shows-output (guard): expected exit 5, got 0. Output: THE-OUTPUT"
[[ "$out" != *"anything"* && "$out" != *"needle"* ]] || fail "gate-cases: a passing case printed its output: $out"
rc "$G" run --json; assert_contains "$out" '"slug":"shows-output","gate":"guard","kind":"run","result":"fail","miss":"m","why":"expected exit 5, got 0. Output: THE-OUTPUT"'
rm -rf "$CASES/text-only" "$CASES/exit-only" "$CASES/shows-output"

# a failing setup.sh stops the case: its command is not run and is not reported on; the whole environment is pinned for setup and command
mkdir -p "$CASES/bad-setup/state"; printf 'exit 4\n' > "$CASES/bad-setup/state/setup.sh"
printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: exit 9\nexpect_exit: 0\n---\n' > "$CASES/bad-setup/case.md"
rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "setup.sh failed (exit 4)"
[[ "$out" != *"expected exit 0, got 9"* ]] || fail "gate-cases: a case whose setup failed ran its command anyway: $out"
rm -rf "$CASES/bad-setup"
mkdir -p "$CASES/env-shown/state"
# each line is "<random>/home <random>/canon-home <random>/tmp" when the variable is the scratch one (the part after "gate-case."), a whole path when it is not
printf '#!/usr/bin/env bash\nprintf "S %%s %%s %%s\\n" "${HOME##*gate-case.}" "${CANON_HOME##*gate-case.}" "${TMPDIR##*gate-case.}" > setup-env.txt\n' > "$CASES/env-shown/state/setup.sh"
printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: cat setup-env.txt; printf "C %%s %%s %%s\\n" "${HOME##*gate-case.}" "${CANON_HOME##*gate-case.}" "${TMPDIR##*gate-case.}"; exit 1\nexpect_exit: 0\n---\n' > "$CASES/env-shown/case.md"
rc "$G" run; envout="$out"
for who in S C; do   # S: setup.sh saw it, C: the command saw it
  [[ -n "$(grep -oE "(^| )$who [A-Za-z0-9]{6}/home [A-Za-z0-9]{6}/canon-home [A-Za-z0-9]{6}/tmp" <<<"$envout" || true)" ]] || fail "gate-cases: $who did not see the scratch HOME, CANON_HOME and TMPDIR: $envout"
done
rm -rf "$CASES/env-shown"

# CANON_ROOT defaults to the repo the script lives in, also when it is run through a symlink; and the cases folder is found from the git repo you are in
ln -s "$G" "$WORK/gc-link"
mkdir -p "$CASES/root-default"; printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: test -f "$CANON_ROOT/tools/gate-cases.sh"\nexpect_exit: 0\n---\n' > "$CASES/root-default/case.md"
set +e; out="$(cd "$WORK" && env -u CANON_ROOT "$WORK/gc-link" run 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_contains "$out" "  ok        root-default (guard)"
rm -rf "$CASES/root-default"
mkdir -p "$WORK/gitrepo" "$WORK/nogit"; git -C "$WORK/gitrepo" init -q
set +e; out="$(cd "$WORK/gitrepo" && env -u GATE_CASES_DIR "$G" add --gate reviewer --slug in-repo --miss m --expect e 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_file_exists "$WORK/gitrepo/tests/gate-cases/in-repo/case.md"; assert_contains "$out" "gate-cases: added in-repo (reviewer, recorded) → $(cd "$WORK/gitrepo" && pwd -P)/tests/gate-cases/in-repo"
set +e; out="$(cd "$WORK/nogit" && env -u GATE_CASES_DIR GIT_CEILING_DIRECTORIES="$WORK" "$G" run 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "not inside a git repository"
rm -rf "$CASES"

# --- the real set: it passes on the real guards, and a weakened guard fails its case ---
export GATE_CASES_DIR="$ROOT/tests/gate-cases"   # explicit: this test also runs in a scratch copy that has no .git
rc "$G" run; assert_eq 0 "$code" "gate-cases: the real set fails: $out"
assert_contains "$out" "  ok        board-spec-zero-tests (guard)"; assert_contains "$out" "  ok        stale-evidence-stamp (guard)"
assert_contains "$out" "recorded  reviewer-mirror-push-false-positive"; assert_contains "$out" "recorded  eval-verdict-worktree-copy"

# a scratch tree of the guards, weakened one line each: the case that records the miss must fail
copy_tree() { mkdir -p "$1"; (cd "$ROOT" && tar -cf - --exclude=tools/canon-go --exclude=tools/canon-go-bin tools tests/board-spec-guard.js tests/board-spec-baseline.json) | tar -xf - -C "$1"; }
weak="$WORK/weak-guard"; copy_tree "$weak"
sed -i.bak 's/^\(.*\)!Object.keys(r.tests).length) violations.push(/\1false) violations.push(/' "$weak/tests/board-spec-guard.js"; rm -f "$weak/tests/board-spec-guard.js.bak"
cmp -s "$ROOT/tests/board-spec-guard.js" "$weak/tests/board-spec-guard.js" && fail "gate-cases: the weakened board-spec guard is identical to the real one"
set +e; out="$(CANON_ROOT="$weak" "$G" run 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "FAIL      board-spec-zero-tests (guard)"; assert_contains "$out" "  ok        stale-evidence-stamp (guard)"
weak2="$WORK/weak-evidence"; copy_tree "$weak2"
sed -i.bak 's/^  if \[\[ \${#names\[@\]} -eq 0 \]\]; then$/  if true; then/' "$weak2/tools/evidence.sh"; rm -f "$weak2/tools/evidence.sh.bak"
cmp -s "$ROOT/tools/evidence.sh" "$weak2/tools/evidence.sh" && fail "gate-cases: the weakened evidence.sh is identical to the real one"
set +e; out="$(CANON_ROOT="$weak2" "$G" run 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "FAIL      stale-evidence-stamp (guard)"

[[ -f "$HOME/canary" && -z "$(ls -A "$TMPDIR")" ]] || fail "gate-cases: left a temp file behind, or touched the pinned home"
echo "gate-cases: ok (add refusals, run pass/exit/text/recorded/malformed/setup, JSON, pinned environment, the real set, two weakened guards fail their cases)"
