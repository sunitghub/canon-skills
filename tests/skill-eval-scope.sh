#!/usr/bin/env bash
# skill-eval-scope (t-8d28) — tools/skill-eval-scope.sh maps a diff to the skills whose instructions changed, and
# tools/skill-eval-history.sh appends one pass rate per run and says how it moved. Both read paths and arguments they do not control,
# so the hostile shapes and a random loop are here. Everything runs in a throwaway git repo; nothing touches the real tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
SCOPE="$ROOT/tools/skill-eval-scope.sh"
HIST="$ROOT/tools/skill-eval-history.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C   # C: the tool sorts names bytewise, so [[ > ]] must too
REPO="$WORK/repo"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t

put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2-x}" > "$1"; }
put skills/alpha/SKILL.md; put skills/alpha/reference/a.md; put skills/alpha/evals/evals.json '{"evals":[]}'
put skills/beta/SKILL.md                                  # no evals/evals.json
put skills/sprint/SKILL.md; put skills/sprint/evals/evals.json '{"evals":[]}'
put agents/canon-evaluator.md; put tools/x.sh; put scripts/y.sh; put README.md
git add -A && git commit -q -m base
BASE="$(git rev-parse HEAD)"
reset_repo() { git reset -q --hard "$BASE"; git clean -fdq; }

scope() {   # scope [args]: output in $out, exit code in $code
  set +e; out="$(cd "$REPO" && bash "$SCOPE" "$@" 2>&1)"; code=$?; set -e
}
expect() {   # expect <label> <expected output> [args]: the diff the caller made against BASE
  local label="$1" want="$2"; shift 2
  scope "${@-$BASE}"; [[ "$code" == 0 ]] || fail "skill-eval-scope: $label exited $code: $out"
  assert_eq "$want" "$out"
}

# --- what counts -----------------------------------------------------------------------------------------------------------------
reset_repo; expect "an empty diff" "" "$BASE"
reset_repo; echo more >> skills/alpha/SKILL.md;              expect "SKILL.md" "run alpha" "$BASE"
reset_repo; echo more >> skills/alpha/reference/a.md;        expect "a reference file" "run alpha" "$BASE"
reset_repo; put skills/alpha/gates/g.md; git add -A;         expect "a new tracked gates/ file" "run alpha" "$BASE"
reset_repo; put skills/alpha/reference/new.md;               expect "an untracked new reference file" "run alpha" "$BASE"
reset_repo; echo more >> skills/beta/SKILL.md;               expect "a skill with no evals.json" "skip beta (no evals/evals.json)" "$BASE"
reset_repo; echo more >> agents/canon-evaluator.md;          expect "a gate agent" "run sprint" "$BASE"
reset_repo; echo more >> skills/alpha/SKILL.md; echo more >> skills/alpha/reference/a.md
expect "two files in one skill" "run alpha" "$BASE"
reset_repo; echo more >> skills/sprint/SKILL.md; echo more >> skills/beta/SKILL.md; echo more >> skills/alpha/SKILL.md; echo more >> agents/canon-evaluator.md
expect "several skills, sorted, the agent and the sprint skill once" "run alpha
skip beta (no evals/evals.json)
run sprint" "$BASE"
reset_repo; echo more >> skills/alpha/evals/evals.json; put skills/alpha/evals/history.jsonl; put skills/alpha/evals/notes.md
put skills/alpha/skill-eval-result.md; put skills/alpha/reference/skill-eval-result.md; put skills/alpha/scripts/s.sh; put agents/sub/x.md
echo more >> tools/x.sh; echo more >> scripts/y.sh; echo more >> README.md; put skills/alpha/SKILL.md.bak
expect "evals/, result files, scripts, tools, README, nested agents, SKILL.md.bak" "" "$BASE"
reset_repo; echo more >> skills/alpha/SKILL.md; git commit -qam "edit"
expect "a committed change against its base" "run alpha" "$BASE"
scope; [[ "$code" != 0 ]] || fail "skill-eval-scope: with no origin/main and no base it should refuse"
assert_contains "$out" "origin/main"
git update-ref refs/remotes/origin/main "$BASE"; scope
[[ "$code" == 0 ]] || fail "skill-eval-scope: the default base failed: $out"
assert_eq "run alpha" "$out"

# --- refusals --------------------------------------------------------------------------------------------------------------------
for bad in nope -- --all -x "HEAD~99" ""; do
  [[ -n "$bad" ]] || continue
  scope "$bad"; [[ "$code" != 0 ]] || fail "skill-eval-scope: base '$bad' was accepted: $out"
  [[ "$out" == skill-eval-scope:* ]] || fail "skill-eval-scope: base '$bad' failed without its own message: $out"
done
set +e; out="$(cd "$WORK" && bash "$SCOPE" "$BASE" 2>&1)"; code=$?; set -e
[[ "$code" != 0 ]] || fail "skill-eval-scope: ran outside a git repository: $out"
assert_contains "$out" "git repository"

# --- hostile paths ---------------------------------------------------------------------------------------------------------------
reset_repo; put "skills/alpha/reference/a b.md"; put $'skills/alpha/reference/x\nrun evil.md'; put $'skills/alpha/ref\nskip evil2 (no evals/evals.json)/z.md'
expect "spaces and newlines in file names add no line" "run alpha" "$BASE"
reset_repo; put skills/Alpha/SKILL.md; put skills/-x/SKILL.md; put skills/al_pha/SKILL.md; put "skills/a b/SKILL.md"; put skills/alpha.md; put skills/x/y
put skills/.hidden/SKILL.md; put "skills//SKILL.md"; put agents/.md; put Skills/alpha/SKILL.md
expect "names outside the pattern" "" "$BASE"
reset_repo; put skills/alpha/evals/../reference/b.md
expect ".. in a created path is normalised by the file system, not by the tool" "run alpha" "$BASE"
reset_repo; ln -s alpha skills/linked 2>/dev/null; ln -s ../alpha/evals skills/beta/evals 2>/dev/null || true
if [[ -L skills/linked && -L skills/beta/evals ]]; then
  echo more >> skills/beta/SKILL.md; git add -A
  expect "a symlinked skill link, a symlinked evals/ dir" "skip beta (no evals/evals.json)" "$BASE"
else
  echo "skill-eval-scope: SKIPPED the symlink cases (this system cannot create symlinks)"
fi

# --- random loop: whatever the paths, only well-formed lines come out, and every named skill really has a changed path ----------------
reset_repo
segs=(skills agents tools scripts Skills alpha beta gamma sprint Alpha -x a.b evals reference gates sub SKILL.md x.md "a b.md" skill-eval-result.md history.jsonl evals.json '..' . '')
RANDOM="${CANON_FUZZ_SEED:-42}"; N="${CANON_FUZZ_N:-300}"; made=0
: > "$WORK/paths.txt"
for ((i = 0; i < N; i++)); do
  depth=$((RANDOM % 4 + 1)); p=""
  for ((j = 0; j < depth; j++)); do s="${segs[RANDOM % ${#segs[@]}]}"; [[ "$s" == .. || "$s" == . || -z "$s" ]] && s=z; p+="${p:+/}$s"; done
  case $((RANDOM % 3)) in 0) p="skills/${segs[RANDOM % 7 + 5]}/$p" ;; 1) p="agents/$p" ;; esac
  [[ "$p" == *.md || $((RANDOM % 2)) == 0 ]] || p+=".md"
  if mkdir -p -- "$(dirname -- "$p")" 2>/dev/null && [[ ! -d "$p" ]] && printf x > "$p" 2>/dev/null; then printf '%s\n' "$p" >> "$WORK/paths.txt"; made=$((made + 1)); fi
done
[[ "$made" -ge $((N / 2)) ]] || fail "skill-eval-scope: the random loop only created $made of $N paths"
scope "$BASE"; [[ "$code" == 0 ]] || fail "skill-eval-scope: the random loop crashed it ($code): $out"
if [[ -n "$out" ]]; then
  prev=""   # the tool sorts by skill name, so the order check is on the name
  while IFS= read -r line; do
    [[ "$line" =~ ^(run\ ([a-z0-9][a-z0-9-]*)|skip\ ([a-z0-9][a-z0-9-]*)\ \(no\ evals/evals\.json\))$ ]] || fail "skill-eval-scope: odd output line '$line'"
    name="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    [[ "$name" > "$prev" ]] || fail "skill-eval-scope: output is not sorted and unique at '$line'"; prev="$name"
    grep -qE "^(skills/$name/|agents/[^/]+\.md$)" "$WORK/paths.txt" || fail "skill-eval-scope: named '$name' with no path under it"
  done <<< "$out"
fi
reset_repo

# --- history ---------------------------------------------------------------------------------------------------------------------
hist() { set +e; out="$(cd "$REPO" && bash "$HIST" "$@" 2>&1)"; code=$?; set -e; }
H="$REPO/skills/alpha/evals/history.jsonl"
line_re='^\{"date":"[0-9]{4}-[0-9]{2}-[0-9]{2}","model":"[A-Za-z0-9._:-]+","pass":[0-9]+,"total":[0-9]+\}$'

hist alpha opus 3 5; [[ "$code" == 0 ]] || fail "skill-eval-history: first run refused: $out"
assert_eq "3/5 pass (first run on opus)" "$out"
assert_eq "1" "$(wc -l < "$H" | tr -d ' ')"
[[ "$(cat "$H")" =~ $line_re ]] || fail "skill-eval-history: line is not the documented shape: $(cat "$H")"
assert_contains "$(cat "$H")" '"model":"opus","pass":3,"total":5'
hist alpha opus 4 5; assert_eq "4/5 pass (was 3/5)" "$out"
hist alpha haiku 1 5; assert_eq "1/5 pass (first run on haiku)" "$out"
hist alpha opus 5 5; assert_eq "5/5 pass (was 4/5)" "$out"       # the haiku line in between is not compared
assert_eq "4" "$(wc -l < "$H" | tr -d ' ')"
while IFS= read -r l; do [[ "$l" =~ $line_re ]] || fail "skill-eval-history: bad line '$l'"; done < "$H"

# an earlier line that does not parse is skipped; the LAST line is both CRLF and unterminated, so it must still be read (CR stripped,
# no final newline needed) and our line must not be glued onto it
printf 'garbage\n{"date":"2026-01-01","model":"opus","pass":9,"total":2}\n{"date":"2026-01-03","model":"opus","pass":7,"total":9}\n{"date":"2026-01-02","model":"opus","pass":2,"total":6}\r' >> "$H"
hist alpha opus 1 2; [[ "$code" == 0 ]] || fail "skill-eval-history: a corrupt history failed the run: $out"
assert_eq "1/2 pass (was 2/6)" "$out"
[[ "$(tail -n1 "$H")" =~ $line_re ]] || fail "skill-eval-history: the appended line was glued onto an unterminated one: $(tail -n2 "$H")"
assert_contains "$(tail -n2 "$H" | head -n1)" '"pass":2,"total":6}'

# every refusal writes nothing and creates nothing
put skills/delta/evals/evals.json '{"evals":[]}'
refuses() {   # refuses <label> <expected message part> <skill> <model> <pass> <total>
  local label="$1" msg="$2" before_a before_d; shift 2
  before_a="$(cksum < "$H")"; before_d="$(find "$REPO/skills" -type f | LC_ALL=C sort | xargs cksum | cksum)"
  hist "$@"; [[ "$code" != 0 ]] || fail "skill-eval-history: did not refuse $label: $out"
  assert_contains "$out" "$msg"
  assert_eq "$before_a" "$(cksum < "$H")"
  assert_eq "$before_d" "$(find "$REPO/skills" -type f | LC_ALL=C sort | xargs cksum | cksum)"
}
refuses "an upper-case skill"        "skill name" Alpha opus 1 2
refuses "a skill with a slash"       "skill name" a/b opus 1 2
refuses "a skill with .."            "skill name" ../alpha opus 1 2
refuses "a leading dash skill"       "skill name" -x opus 1 2
refuses "an empty skill"             "skill name" "" opus 1 2
refuses "a model with a space"       "model" alpha "bad model" 1 2
refuses "a model with a semicolon"   "model" alpha 'a;b' 1 2
refuses "a model with a quote"       "model" alpha 'a"b' 1 2
refuses "an empty model"             "model" alpha "" 1 2
refuses "a 65-char model"            "model" alpha "$(printf 'm%.0s' $(seq 1 65))" 1 2
for p in -1 1.5 abc "" 01 1e3 9999999 "1 2" "+1"; do refuses "pass '$p'" "pass" alpha opus "$p" 5; done
for t in 0 -3 x "" 2.0 007; do refuses "total '$t'" "total" alpha opus 0 "$t"; done
refuses "pass above total"           "cannot exceed" alpha opus 6 5
refuses "a skill without evals.json" "evals.json" beta opus 1 2
refuses "a skill that is not there"  "skills/gamma" gamma opus 1 2
hist alpha opus 1; [[ "$code" != 0 ]] || fail "skill-eval-history: accepted too few arguments"
hist alpha opus 1 2 3; [[ "$code" != 0 ]] || fail "skill-eval-history: accepted too many arguments"
[[ ! -e "$REPO/skills/delta/evals/history.jsonl" ]] || fail "skill-eval-history: a refusal created a history file"
[[ ! -e "$REPO/skills/beta/evals/history.jsonl" ]] || fail "skill-eval-history: a refusal created a history file in a skill with no evals"

mkdir -p "$REPO/skills/dirhist/evals/history.jsonl"; put skills/dirhist/evals/evals.json '{"evals":[]}'
hist dirhist opus 1 2; [[ "$code" != 0 ]] || fail "skill-eval-history: wrote through a history path that is a directory"

mkdir -p "$WORK/outside"; put "$WORK/outside/history.jsonl" keep
mkdir -p skills/lnk/evals; put skills/lnk/evals/evals.json '{"evals":[]}'; ln -s "$WORK/outside/history.jsonl" skills/lnk/evals/history.jsonl 2>/dev/null || true
if [[ -L skills/lnk/evals/history.jsonl ]]; then
  hist lnk opus 1 2; [[ "$code" != 0 ]] || fail "skill-eval-history: wrote through a symlinked history.jsonl"
  assert_eq "keep" "$(cat "$WORK/outside/history.jsonl")"
  mkdir -p "$WORK/outside/evals"; put "$WORK/outside/evals/evals.json" '{"evals":[]}'
  mkdir -p skills/lnk2; ln -s "$WORK/outside/evals" skills/lnk2/evals
  hist lnk2 opus 1 2; [[ "$code" != 0 ]] || fail "skill-eval-history: wrote through a symlinked evals/ dir"
  [[ ! -e "$WORK/outside/evals/history.jsonl" ]] || fail "skill-eval-history: a file appeared in the symlink's target"
  ln -s "$WORK/outside" skills/lnk3
  hist lnk3 opus 1 2; [[ "$code" != 0 ]] || fail "skill-eval-history: wrote through a symlinked skill dir"
else
  echo "skill-eval-history: SKIPPED the symlink cases (this system cannot create symlinks)"
fi

set +e; out="$(cd "$WORK" && bash "$HIST" alpha opus 1 2 2>&1)"; code=$?; set -e
[[ "$code" != 0 ]] || fail "skill-eval-history: ran outside a git repository"

# a held lock is respected (this is what keeps the concurrent runs below safe): the run waits, writes nothing, and appends once it is released
put skills/epsilon/evals/evals.json '{"evals":[]}'
E="$REPO/skills/epsilon/evals/history.jsonl"
mkdir "$E.lock"
( cd "$REPO" && bash "$HIST" epsilon held 1 2 > "$WORK/held.out" 2>&1 ) & held_pid=$!
sleep 1
[[ ! -e "$E" ]] || fail "skill-eval-history: wrote while another run held the lock"
kill -0 "$held_pid" 2>/dev/null || fail "skill-eval-history: gave up on a lock that was held for one second: $(cat "$WORK/held.out")"
rmdir "$E.lock"; wait "$held_pid" || fail "skill-eval-history: failed after the lock was released: $(cat "$WORK/held.out")"
assert_eq "1/2 pass (first run on held)" "$(cat "$WORK/held.out")"
assert_eq "1" "$(wc -l < "$E" | tr -d ' ')"
[[ ! -e "$E.lock" ]] || fail "skill-eval-history: left its lock directory behind"

# 40 concurrent runs keep every line whole, with no blank line between them (the unlocked version added one in about 1 trial in 9)
for i in $(seq 1 40); do ( cd "$REPO" && bash "$HIST" epsilon "m$((i % 3))" "$((i % 5))" 9 >/dev/null 2>&1 ) & done
wait
assert_eq "41" "$(wc -l < "$E" | tr -d ' ')"
[[ "$(grep -c '^$' "$E" || true)" == 0 ]] || fail "skill-eval-history: a concurrent run left a blank line"
while IFS= read -r l; do [[ "$l" =~ $line_re ]] || fail "skill-eval-history: a concurrent run tore a line: '$l'"; done < "$E"
[[ ! -e "$E.lock" ]] || fail "skill-eval-history: left its lock directory behind after concurrent runs"

echo "skill-eval-scope: ok"
