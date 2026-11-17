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
for flag in gate slug miss source cmd expect-exit expect-text expect needs state; do   # a flag with no value after it
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

# an option nobody gave writes no line; the frontmatter is closed; one expectation is enough; the JSON is valid and a pass carries no "why"
rc "$G" add --gate guard --slug only-text --cmd 'echo hi' --miss m --expect-text hi;  assert_eq 0 "$code"
rc "$G" add --gate guard --slug only-exit --cmd true --miss m --expect-exit 0;       assert_eq 0 "$code"
for c in only-text only-exit; do assert_eq 2 "$(grep -c '^---$' "$CASES/$c/case.md")"; assert_eq 0 "$(grep -c '^source:' "$CASES/$c/case.md")"; done
assert_eq 0 "$(grep -c '^expect_exit:' "$CASES/only-text/case.md")"; assert_eq 0 "$(grep -c '^expect_text:' "$CASES/only-exit/case.md")"
rc "$G" run --json; assert_eq 0 "$code"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["run"] == 2 and len(d["cases"]) == 2 and all("why" not in c for c in d["cases"])' || fail "gate-cases: the JSON of two passing cases is not valid or carries a why: $out"
rm -rf "$CASES"

# no cases folder: text and JSON say so and exit 0; a folder inside the cases folder with no case.md is ignored
rc "$G" run; assert_eq 0 "$code"; assert_eq "gate cases: none (no $CASES)" "$out"
rc "$G" run --json; assert_eq 0 "$code"; assert_eq '{"pass":0,"run":0,"recorded":0,"replay":0,"skipped":0,"cases":[]}' "$out"
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
mal $'gate: reviewer\nkind: recorded\nmiss: m\nexpect_exit: 0' reviewer "a recorded case needs expect"   # expect_exit is not expect
mal $'gate: guard\nkind: run\ncmd: true\nexpect_exit: 0\n---\nmiss: only in the body' guard "it needs gate"                  # the body is not frontmatter

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
mkdir -p "$WORK/bin"; phys_bin="$(cd "$WORK/bin" && pwd -P)"   # physical path: a relative link is resolved against the real folder, not through /var -> /private/var
ln -s "$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$G" "$phys_bin")" "$WORK/bin/gc-link"   # a RELATIVE link, so the script must resolve it against the link's folder
mkdir -p "$CASES/root-default"; printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: test -f "$CANON_ROOT/tools/gate-cases.sh"\nexpect_exit: 0\n---\n' > "$CASES/root-default/case.md"
set +e; out="$(cd "$WORK" && env -u CANON_ROOT "$WORK/bin/gc-link" run 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_contains "$out" "  ok        root-default (guard)"
rm -rf "$CASES/root-default"
mkdir -p "$WORK/gitrepo" "$WORK/nogit"; git -C "$WORK/gitrepo" init -q
set +e; out="$(cd "$WORK/gitrepo" && env -u GATE_CASES_DIR "$G" add --gate reviewer --slug in-repo --miss m --expect e 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_file_exists "$WORK/gitrepo/tests/gate-cases/in-repo/case.md"; assert_contains "$out" "gate-cases: added in-repo (reviewer, recorded) → $(cd "$WORK/gitrepo" && pwd -P)/tests/gate-cases/in-repo"
set +e; out="$(cd "$WORK/nogit" && env -u GATE_CASES_DIR GIT_CEILING_DIRECTORIES="$WORK" "$G" run 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "not inside a git repository"
rm -rf "$CASES"

# --- review findings (t-2178): a clean environment, a missing tool is a skip, valid JSON for any text, the refusals added with them ---
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 0 --expect e; assert_eq 2 "$code"; assert_contains "$out" "--expect belongs to a recorded case"
rc "$G" add --gate guard --slug edge-255 --miss m --cmd true --expect-exit 255; assert_eq 0 "$code"; rm -rf "$CASES"   # 255 is the largest exit code
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 256;          assert_eq 2 "$code"; assert_contains "$out" "from 0 to 255"
rc "$G" add --gate guard --slug a --miss m --cmd true --expect-exit 0 --needs "a b"; assert_eq 2 "$code"; assert_contains "$out" "--needs must be one command name"
rc "$G" add --gate reviewer --slug a --miss m --expect e --needs node;            assert_eq 2 "$code"; assert_contains "$out" "--needs belongs to a run case"
mkdir -p "$WORK/st2"; chmod 000 "$WORK/st2"
if [[ "$(id -u)" != 0 ]]; then
  rc "$G" add --gate guard --slug half --miss m --cmd true --expect-exit 0 --state "$WORK/st2"; assert_eq 2 "$code"; assert_contains "$out" "could not copy --state: nothing was added"
  [[ ! -e "$CASES/half" ]] || fail "gate-cases: a failed copy of --state left a half-written case"
fi
chmod 755 "$WORK/st2"; rm -rf "$CASES"
# a missing tool skips a run case, never fails it
rc "$G" add --gate guard --slug needs-tool --miss "needs a tool nobody has" --cmd true --expect-exit 0 --needs no-such-tool-for-gate-cases; assert_eq 0 "$code"
assert_grep "^needs: no-such-tool-for-gate-cases$" "$CASES/needs-tool/case.md"
rc "$G" run; assert_eq 0 "$code"; assert_contains "$out" "  skipped   needs-tool (guard): needs no-such-tool-for-gate-cases, which is not installed"
assert_contains "$out" "gate cases: 0 of 0 pass, 0 recorded, 1 skipped"
rc "$G" run --json; assert_contains "$out" '"skipped":1'; assert_contains "$out" '"result":"skipped"'
rm -rf "$CASES"
# the clean environment: a caller's CANON_TICKETS_DIR and GIT_DIR never reach a case, setup or command; nothing is written into them
mkdir -p "$CASES/clean-env/state" "$WORK/caller-tickets" "$WORK/caller-gitdir"
printf '#!/usr/bin/env bash\nprintf "S[%%s][%%s][%%s]\\n" "${CANON_TICKETS_DIR-}" "${GIT_DIR-}" "${COCKPIT_STATE_DIR-}" > setup-env.txt\n' > "$CASES/clean-env/state/setup.sh"
printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: cat setup-env.txt; printf "C[%%s][%%s][%%s]\\n" "${CANON_TICKETS_DIR-}" "${GIT_DIR-}" "${COCKPIT_STATE_DIR-}"\nexpect_exit: 0\nexpect_text: C[][][]\n---\n' > "$CASES/clean-env/case.md"
set +e; out="$(CANON_TICKETS_DIR="$WORK/caller-tickets" GIT_DIR="$WORK/caller-gitdir" COCKPIT_STATE_DIR="$WORK/caller-cockpit" "$G" run 2>&1)"; code=$?; set -e
assert_eq 0 "$code" "gate-cases: a case saw the caller's environment: $out"
mkdir -p "$CASES/xdg-pinned"; printf -- '---\ngate: guard\nkind: run\nmiss: m\ncmd: echo "X[${XDG_CONFIG_HOME##*gate-case.}]"\nexpect_exit: 1\n---\n' > "$CASES/xdg-pinned/case.md"
rc "$G" run; assert_contains "$out" "X[" ; [[ "$out" =~ X\[[A-Za-z0-9]{6}/xdg\] ]] || fail "gate-cases: XDG_CONFIG_HOME is not pinned inside the scratch folder: $out"
rm -rf "$CASES/xdg-pinned"
rm -rf "$CASES"
# JSON stays valid for any text: quotes, backslashes, tabs, newlines and control characters in a miss
rc "$G" add --gate reviewer --slug json-text --miss 'quote " backslash \ tab '$'\t'' esc '$'\033''[31m bell '$'\001'' end' --expect 'x'
assert_eq 0 "$code"
rc "$G" run --json; assert_eq 0 "$code"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["cases"][0]["miss"]; assert "quote \" backslash \\ tab" in m and "\x1b" not in m and "\x01" not in m, m' || fail "gate-cases: --json is invalid or kept a control character: $out"
rm -rf "$CASES"

# --- replay (t-b809): re-runs today's gates on a past commit through `claude -p`. A stub claude records its arguments and environment
# and answers with a real reply's JSON shape; a scratch repo holds the base, the graded commit and the fix. Protects the trial that decides
# whether the reviewer folds into the evaluator, and `run` (pre-gate, every close) never spending a call. ---
use_fresh_board "$WORK/board"
REPO="$WORK/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/x.txt"; git -C "$REPO" add x.txt; git -C "$REPO" commit -qm base; BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'b\n' > "$REPO/x.txt"; git -C "$REPO" commit -qam graded; REF_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'c\n' > "$REPO/x.txt"; git -C "$REPO" commit -qam fix; FIX_SHA="$(git -C "$REPO" rev-parse HEAD)"
export GATE_CASES_DIR="$REPO/tests/gate-cases"
mkcase() {  # mkcase <slug> <extra frontmatter lines...>: a replay case on the scratch repo
  local s="$1"; shift; mkdir -p "$GATE_CASES_DIR/$s/state/ticket"
  { printf -- '---\ngate: evaluator\nkind: replay\nmiss: a FIFO .gitignore blocks forever\nticket: t-abcd\nbase: %s\n' "$BASE_SHA"
    printf '%s\n' "$@"; printf -- '---\n'; } > "$GATE_CASES_DIR/$s/case.md"
  printf '# Acceptance\n- [ ] 1. the file says b\n' > "$GATE_CASES_DIR/$s/state/ticket/acceptance.md"
}
mkcase rp "ref: $REF_SHA" "fix: $FIX_SHA" 'catch: fifo|named pipe'
STUB="$WORK/stub"; mkdir -p "$STUB/bin" "$STUB/calls"
cat > "$STUB/bin/claude" <<'EOF'
#!/usr/bin/env bash
# a stand-in for claude -p: logs each call, answers with a real reply's JSON (2026-11-17) around the text in $STUB/reply-<agent>.txt
args=("$@"); agent=probe
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[$i]}" == --agent ]] && agent="${args[$((i + 1))]}"; done
if [[ "$agent" == probe ]]; then exit "${STUB_AUTH_RC:-0}"; fi
n=$(($(ls "$STUB/calls" | wc -l) + 1)); log="$STUB/calls/$n"
{ printf 'arg=%s\n' "${args[@]}"; printf 'pwd=%s\nhome=%s\ncanon_home=%s\ntmpdir=%s\nxdg=%s\nscope=%s\ntickets=%s\npid=%s\n' "$PWD" "$HOME" "$CANON_HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$CANON_GATE_SCOPE_DIR" "$CANON_TICKETS_DIR" "$$"
  [[ -f ".tickets/t-abcd/acceptance.md" ]] && echo "ticket=present"; [[ -L .claude/agents ]] && echo "agents=linked"; } > "$log"
case "${STUB_MODE:-ok}" in
  sleep) exec sleep 60 ;;
  fail) [[ "$n" == "${STUB_FAIL_CALL:-1}" ]] && { echo "boom" >&2; exit 3; } ;;
  iserror) printf '{"is_error":true,"result":"rate limited"}'; exit 0 ;;
esac
python3 -c 'import json,sys; print(json.dumps({"duration_ms":1513,"total_cost_usd":0.0030145700000000003,"modelUsage":{"claude-sonnet-5-5":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":11457,"cacheCreationInputTokens":14489}},"is_error":False,"session_id":"s","result":open(sys.argv[1]).read()}))' "$STUB/reply-$agent.txt"
EOF
chmod +x "$STUB/bin/claude"; export STUB
SP="$STUB/bin:$PATH"
rp() { set +e; out="$(PATH="$SP" "$G" replay "$@" 2>&1)"; code=$?; set -e; }
calls() { ls "$STUB/calls" | wc -l | tr -d ' '; }
row() { sed -n "${1}p" "$WORK/r.jsonl"; }
reply() { printf '%s\n' "$2" > "$STUB/reply-$1.txt"; }
reset() { rm -f "$WORK/r.jsonl"; rm -rf "$WORK/r-reports" "$STUB/calls"; mkdir -p "$STUB/calls"; }
REPO_STATUS="$(git -C "$REPO" status --porcelain)"

# no --yes: the count, exit 2, no call (not even the auth probe)
rp rp --config split --runs 2; assert_eq 2 "$code"; assert_contains "$out" "would make 4 claude -p calls"; assert_eq 0 "$(calls)"
[[ ! -e "$WORK/r.jsonl" ]] || fail "replay without --yes wrote results"
rp rp --config folded --runs 3; assert_contains "$out" "would make 3 claude -p calls"
# split: the reviewer's Act On names it (caught), the evaluator passes; the stub saw the pinned env, the agent, the mode and the allowlist
reset
reply canon-reviewer $'Changed files: x.txt\n## Triage\n- Act On: x.txt:1 reads a FIFO and blocks forever\n- Consider: none\n- Noted: none\n- Dismissed: none\nNO — one Act On'
reply canon-evaluator $'## Criteria\n| 1 | pass |\npass: the file says b'
rp rp --config split --runs 1 --yes --out "$WORK/r.jsonl"; assert_eq 0 "$code" "replay split: $out"
assert_eq 2 "$(calls)"; assert_eq 2 "$(wc -l < "$WORK/r.jsonl" | tr -d ' ')"
assert_contains "$(row 1)" '"case":"rp","kind":"defect","config":"split","run":1,"gate":"reviewer","model":"claude-sonnet-5-5","verdict":"fail","caught":true,"leak":false,"tokens":25952,"duration_ms":1513,"cost_usd":0.0030'
assert_contains "$(row 2)" '"gate":"evaluator","model":"claude-sonnet-5-5","verdict":"pass","caught":false'
c1="$STUB/calls/1"
assert_grep "^arg=canon-reviewer$" "$c1"; assert_grep "^arg=claude-sonnet-5-5$" "$c1"; assert_grep "^arg=dontAsk$" "$c1"; assert_grep "^arg=Write$" "$c1"; assert_grep "^arg=Edit$" "$c1"
grep -qxF "arg=Bash($ROOT/tools/git-read:*)" "$c1" || fail "replay: the Bash allowlist is not the git-read wrapper alone"; assert_grep "^arg=canon-evaluator$" "$STUB/calls/2"
assert_grep "^home=$HOME$" "$c1"; assert_grep "^ticket=present$" "$c1"; assert_grep "^agents=linked$" "$c1"
for k in canon_home tmpdir xdg scope; do v="$(sed -n "s/^$k=//p" "$c1")"; [[ "$v" == "$TMPDIR"/gate-replay.* ]] || fail "replay: $k was not pinned to scratch: $v"; done
[[ "$(sed -n 's/^pwd=//p' "$c1")" == "$TMPDIR"/gate-replay.*/wt ]] || fail "replay: the gate did not run in the scratch worktree: $(sed -n 's/^pwd=//p' "$c1")"
grep -q "^arg=.*Base ref: \`$BASE_SHA\`" "$c1" || grep -q "Base ref: \`$BASE_SHA\`" "$c1" || fail "replay: the prompt does not name the base"
grep -q "{{" "$c1" && fail "replay: a prompt placeholder was left unfilled"
assert_eq 1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"; assert_eq "$REPO_STATUS" "$(git -C "$REPO" status --porcelain)"
[[ -z "$(ls -A "$TMPDIR")" ]] || fail "replay left scratch behind: $(ls -A "$TMPDIR")"
assert_file_exists "$WORK/r-reports/rp-split-1-reviewer.md"
# a reviewer finding only under Noted is not a catch; an evaluator pass that mentions it is not a catch; a fail that names it is
reset
reply canon-reviewer $'## Triage\n- Act On: none\n- Consider: none\n- Noted: a FIFO could block\n- Dismissed: none\nYES'
reply canon-evaluator $'Findings: a fifo is mentioned\npass: fine'
rp rp --config split --runs 1 --yes --out "$WORK/r.jsonl"; assert_contains "$(row 1)" '"verdict":"pass","caught":false'; assert_contains "$(row 2)" '"verdict":"pass","caught":false'
reset; reply canon-evaluator $'## Findings\n- x.txt:1 blocks on a named pipe\nfail: criterion 1'
rp rp --config folded --runs 1 --yes --out "$WORK/r.jsonl"; assert_contains "$(row 1)" '"gate":"folded","model":"claude-sonnet-5-5","verdict":"fail","caught":true'
assert_grep "^arg=canon-evaluator$" "$STUB/calls/1"; grep -q "Reviewer findings (advisory)" "$STUB/calls/1" || fail "replay: the folded prompt was not sent"
# folded: the advisory section's Consider is a catch; its Noted is not; the leak flag reads the fix sha
reset; reply canon-evaluator $'## Reviewer findings (advisory)\n- Act On: none\n- Consider: x.txt:1 FIFO read blocks\n- Noted: none\n## Verdict\npass: fine'
rp rp --config folded --runs 1 --yes --out "$WORK/r.jsonl"; assert_contains "$(row 1)" '"verdict":"pass","caught":true,"leak":false'
reset; reply canon-evaluator $'## Reviewer findings (advisory)\n- Act On: none\n- Noted: a FIFO, see '"${FIX_SHA:0:9}"$'\n## Verdict\npass: fine'
rp rp --config folded --runs 1 --yes --out "$WORK/r.jsonl"; assert_contains "$(row 1)" '"verdict":"pass","caught":false,"leak":true'
# errors: a failed call, is_error, a timeout killed by its PID, a bad ref (no call); each is an error row, the run goes on, exit 1
mkcase rp2 "ref: $REF_SHA" "fix: $FIX_SHA" 'catch: fifo'
reset; reply canon-evaluator 'pass: fine'
set +e; out="$(STUB_MODE=fail STUB_FAIL_CALL=1 PATH="$SP" "$G" replay rp rp2 --config folded --runs 1 --yes --out "$WORK/r.jsonl" 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$(row 1)" '"verdict":"error","caught":false'; assert_contains "$(row 1)" '"error":"claude exited 3: boom'; assert_contains "$(row 2)" '"case":"rp2"'; assert_contains "$(row 2)" '"verdict":"pass"'
reset; set +e; out="$(STUB_MODE=iserror PATH="$SP" "$G" replay rp --config folded --runs 1 --yes --out "$WORK/r.jsonl" 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$(row 1)" '"error":"claude reported an error'
reset; set +e; out="$(STUB_MODE=sleep GATE_REPLAY_TIMEOUT=2 PATH="$SP" "$G" replay rp --config folded --runs 1 --yes --out "$WORK/r.jsonl" 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$(row 1)" '"error":"timeout after 2s"'
spid="$(sed -n 's/^pid=//p' "$STUB/calls/1")"; ! kill -0 "$spid" 2>/dev/null || fail "replay: the timed-out call $spid is still running"
assert_eq 1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"
mkcase badref "ref: 0123456789abcdef0123456789abcdef01234567" "fix: $FIX_SHA" 'catch: fifo'
reset; rp badref --config split --runs 1 --yes --out "$WORK/r.jsonl"; assert_eq 1 "$code"; assert_eq 0 "$(calls)"
assert_contains "$(row 1)" '"gate":"-"'; assert_contains "$(row 1)" 'does not resolve'
rm -rf "$GATE_CASES_DIR/badref" "$GATE_CASES_DIR/rp2"
# the auth probe fails: exit 2 before any case
reset; set +e; out="$(STUB_AUTH_RC=1 PATH="$SP" "$G" replay rp --config split --runs 1 --yes --out "$WORK/r.jsonl" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "not logged in"; assert_eq 0 "$(calls)"; [[ ! -s "$WORK/r.jsonl" ]] || fail "replay wrote rows after a failed auth probe"
# --out default: a fresh scratch dir, named in the output
reset; reply canon-evaluator 'pass: fine'; rp rp --config folded --runs 1 --yes; assert_eq 0 "$code"
dflt="$(sed -n 's/^gate-cases: results in //p' <<<"$out")"; [[ "$dflt" == "$TMPDIR"/gate-replay-out.*/replay.jsonl && -s "$dflt" ]] || fail "replay: no default results file: $out"
rm -rf "$(dirname "$dflt")"
# run lists a replay case and never calls claude; ls shows it; malformed replay cases fail run, naming the field
reset; set +e; out="$(PATH="$SP" "$G" run 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_contains "$out" "  replay    rp (evaluator): a FIFO .gitignore blocks forever"; assert_contains "$out" "gate cases: 0 of 0 pass, 0 recorded, 1 replay"; assert_eq 0 "$(calls)"
rc "$G" run --json; assert_contains "$out" '"replay":1'
rc "$G" ls; assert_contains "$out" "rp  evaluator  replay"
mkcase ctl "ref: $REF_SHA" 'catch: ' 'expect_verdict: pass'; rc "$G" run; assert_eq 0 "$code" "a control with an empty catch: $out"
mkcase nocatch "ref: $REF_SHA" "fix: $FIX_SHA"; rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "FAIL      nocatch (evaluator): malformed case.md: a replay case needs catch"
rm -rf "$GATE_CASES_DIR/nocatch"; mkcase nofix "ref: $REF_SHA" 'catch: x'; rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "a replay case needs fix (the commit"
rm -rf "$GATE_CASES_DIR/nofix"; mkcase badre "ref: $REF_SHA" "fix: $FIX_SHA" 'catch: (unclosed'; rc "$G" run; assert_eq 1 "$code"; assert_contains "$out" "catch is not a valid regex"
rp badre --config split --runs 1; assert_eq 2 "$code"; assert_contains "$out" "malformed case.md: catch is not a valid regex"
rm -rf "$GATE_CASES_DIR/badre"
# the control: never caught, never a leak (it has no fix), its verdict in the summary
reset; reply canon-evaluator 'pass: fine, see '"${FIX_SHA:0:9}"; rp ctl --config folded --runs 1 --yes --out "$WORK/r.jsonl"; assert_contains "$(row 1)" '"kind":"control"'; assert_contains "$(row 1)" '"caught":false,"leak":false'
# --summary on a fixture with known numbers: split close = reviewer + evaluator per case and run; a case-run is caught when any row is
cat > "$WORK/fx.jsonl" <<'EOF'
{"case":"a","kind":"defect","config":"split","run":1,"gate":"reviewer","verdict":"fail","caught":true,"leak":false,"tokens":100,"duration_ms":60000,"cost_usd":0.1}
{"case":"a","kind":"defect","config":"split","run":1,"gate":"evaluator","verdict":"pass","caught":false,"leak":false,"tokens":200,"duration_ms":120000,"cost_usd":0.2}
{"case":"b","kind":"defect","config":"split","run":1,"gate":"reviewer","verdict":"pass","caught":false,"leak":true,"tokens":50,"duration_ms":60000,"cost_usd":0.1}
{"case":"b","kind":"defect","config":"split","run":1,"gate":"evaluator","verdict":"error","caught":false,"leak":false,"tokens":0,"duration_ms":0,"cost_usd":0}
{"case":"c","kind":"control","config":"split","run":1,"gate":"reviewer","verdict":"pass","caught":false,"leak":false,"tokens":10,"duration_ms":60000,"cost_usd":0.1}
{"case":"c","kind":"control","config":"split","run":1,"gate":"evaluator","verdict":"pass","caught":false,"leak":false,"tokens":20,"duration_ms":60000,"cost_usd":0.1}
{"case":"a","kind":"defect","config":"folded","run":1,"gate":"folded","verdict":"pass","caught":true,"leak":false,"tokens":150,"duration_ms":180000,"cost_usd":0.1}
{"case":"b","kind":"defect","config":"folded","run":1,"gate":"folded","verdict":"pass","caught":true,"leak":false,"tokens":90,"duration_ms":60000,"cost_usd":0.1}
{"case":"c","kind":"control","config":"folded","run":1,"gate":"folded","verdict":"fail","caught":false,"leak":false,"tokens":60,"duration_ms":60000,"cost_usd":0.1}
EOF
rc "$G" replay --summary "$WORK/fx.jsonl"; assert_eq 0 "$code"
assert_contains "$out" "split   1   1/2       pass     1     1      50           380          2.0"
assert_contains "$out" "folded  1   2/2       fail     0     0      90           300          1.0"
assert_contains "$out" "case b split run 1: missed"; assert_contains "$out" "case b folded run 1: caught"
rm -rf "$REPO"
export GATE_CASES_DIR="$CASES"

# --- the real set: it passes on the real guards, and a weakened guard fails its case ---
export GATE_CASES_DIR="$ROOT/tests/gate-cases"   # explicit: this test also runs in a scratch copy that has no .git
rc "$G" run; assert_eq 0 "$code" "gate-cases: the real set fails: $out"
assert_contains "$out" "  ok        board-spec-zero-tests (guard)"; assert_contains "$out" "  ok        stale-evidence-stamp (guard)"
assert_contains "$out" ", 6 replay"   # t-b809: the trial's cases are listed, never run (pre-gate runs this at every close)
# t-b809: a replay case's ticket files are the ones the gate graded: none may name the finding it is scored on (a leak makes the catch free)
for c in "$ROOT"/tests/gate-cases/replay-*/; do
  re="$(sed -n 's/^catch: //p' "${c}case.md")"; [[ -n "$re" ]] || continue
  ! grep -qiE -- "$re" "${c}state/ticket/"*.md || fail "gate-cases: $(basename "$c")'s ticket files name its finding: $(grep -iE -- "$re" "${c}state/ticket/"*.md | head -c 300)"
done
assert_contains "$out" "recorded  reviewer-mirror-push-false-positive"; assert_contains "$out" "  ok        eval-verdict-worktree-copy (guard)"   # t-6be7: a run case since the warning exists

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
weak3="$WORK/weak-eval-verdict"; copy_tree "$weak3"   # t-6be7: without the warning line the worktree-copy case fails
sed -i.bak 's/^    echo "Sprint \$id: eval-report.md differs between this worktree.*$/    :/' "$weak3/tools/sprint"; rm -f "$weak3/tools/sprint.bak"
cmp -s "$ROOT/tools/sprint" "$weak3/tools/sprint" && fail "gate-cases: the weakened sprint is identical to the real one"
set +e; out="$(CANON_ROOT="$weak3" "$G" run 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "FAIL      eval-verdict-worktree-copy (guard)"

[[ -f "$HOME/canary" && -z "$(ls -A "$TMPDIR")" ]] || fail "gate-cases: left a temp file behind, or touched the pinned home"
echo "gate-cases: ok (add refusals, run pass/exit/text/recorded/malformed/setup, JSON, pinned environment, the real set, three weakened guards fail their cases, replay: pinned env, catch/leak/verdict rules, errors, timeout, bad ref, auth probe, run never replays, summary)"
