#!/usr/bin/env bash
# skill-check — tools/skill-check gates a later paid `claude plugin eval` run. Runs the
# real tool against fixtures; the reject cases feed it inputs it must fail or refuse.
# Fixtures are copied outside the repo because the tool refuses paths inside canon.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# Guarded skip: in scripts/test.sh's mandatory list, so a missing python3 must not abort the suite.
if ! command -v python3 >/dev/null 2>&1; then
  echo "skill-check: python3 absent — skipped"
  exit 0
fi

TOOL="$ROOT/tools/skill-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT/tests/fixtures/skill-check/." "$TMP/"

# status <json> <check-id> -> pass|warn|fail|absent
status() {
  python3 -c 'import json,sys
d=json.loads(sys.argv[1]); print(next((c["status"] for c in d["checks"] if c["id"]==sys.argv[2]),"absent"))' "$1" "$2"
}
run() { rc=0; out="$("$TOOL" "$@" 2>/dev/null)" || rc=$?; }

# Good skill: no fail, exit 0, every stage-1 check passes.
run "$TMP/good"; assert_eq 0 "$rc"
for id in evals-present evals-count evals-shape evals-variety frontmatter description-present side-effects-guarded trust-hooks; do
  assert_eq pass "$(status "$out" "$id")"
done

# No evals: hard fail with the how-to-create fix.
run "$TMP/no-evals"; assert_eq 1 "$rc"
assert_eq fail "$(status "$out" evals-present)"
assert_contains "$out" "evals/evals.json"

# Unparseable evals.json fails too.
mkdir "$TMP/no-evals/evals"; echo '{not json' > "$TMP/no-evals/evals/evals.json"
run "$TMP/no-evals"; assert_eq fail "$(status "$out" evals-present)"

# Too few / same-type / shapeless cases warn but never fail.
mkdir "$TMP/thin"; cp "$TMP/good/SKILL.md" "$TMP/thin/"; mkdir "$TMP/thin/evals"
echo '{"evals":[{"id":1,"case_type":"control","prompt":"x"},{"id":2,"case_type":"control","prompt":"y","expectations":["z"]}]}' > "$TMP/thin/evals/evals.json"
run "$TMP/thin"; assert_eq 0 "$rc"
assert_eq warn "$(status "$out" evals-count)"
assert_eq warn "$(status "$out" evals-shape)"
assert_eq warn "$(status "$out" evals-variety)"

# Bad frontmatter: hard fail.
run "$TMP/bad-frontmatter"; assert_eq 1 "$rc"
assert_eq fail "$(status "$out" frontmatter)"

# Hooks skill: bad boolean fails; hooks and an unguarded push are flagged.
run "$TMP/hooks"; assert_eq 1 "$rc"
assert_eq fail "$(status "$out" field-values)"
assert_eq warn "$(status "$out" trust-hooks)"
assert_eq warn "$(status "$out" side-effects-guarded)"

# Length rules: 500-line body, oversize description.
mkdir "$TMP/long"; cp -R "$TMP/good/evals" "$TMP/long/"
{ printf -- '---\nname: long\ndescription: %s\n---\n' "$(printf 'x%.0s' $(seq 1600))"; seq 1 600; } > "$TMP/long/SKILL.md"
run "$TMP/long"; assert_eq 0 "$rc"
assert_eq warn "$(status "$out" body-length)"
assert_eq warn "$(status "$out" description-length)"

# Shell injection blocks are flagged.
mkdir "$TMP/inject"; cp -R "$TMP/good/evals" "$TMP/inject/"
# shellcheck disable=SC2016  # the backticks are literal skill content
printf -- '---\nname: inject\ndescription: d\n---\nBranch: !`git branch`\n' > "$TMP/inject/SKILL.md"
run "$TMP/inject"; assert_eq warn "$(status "$out" trust-shell-injection)"

# Malformed evals.json shapes must fail cleanly with JSON, never crash (rc 1, not a traceback).
mkdir "$TMP/shape"; cp "$TMP/good/SKILL.md" "$TMP/shape/"; mkdir "$TMP/shape/evals"
for bad in '[1,2]' 'null' '{"evals":"nope"}' '{"evals":null}'; do
  echo "$bad" > "$TMP/shape/evals/evals.json"
  run "$TMP/shape"; assert_eq 1 "$rc"
  assert_eq fail "$(status "$out" evals-present)"
done
# A non-object entry inside a valid list is reported, not a crash: no usable id fails (t-a350), shape warns.
echo '{"evals":[1,{"id":2,"case_type":"a","prompt":"p","expectations":["e"]},{"id":3,"case_type":"b","prompt":"p","expectations":["e"]}]}' > "$TMP/shape/evals/evals.json"
run "$TMP/shape"; assert_eq 1 "$rc"
assert_eq fail "$(status "$out" evals-ids)"
assert_eq warn "$(status "$out" evals-shape)"

# Unhashable / odd-typed fields and pathological nesting must not crash either.
echo '{"evals":[{"id":1,"case_type":["a"],"prompt":"p","expectations":["e"]},{"id":2,"case_type":{"k":1},"prompt":"p","expectations":["e"]},{"id":3,"case_type":null,"prompt":"p","expectations":["e"]}]}' > "$TMP/shape/evals/evals.json"
run "$TMP/shape"; assert_eq 0 "$rc"
python3 -c 'print("[" * 100000)' > "$TMP/shape/evals/evals.json"
run "$TMP/shape"; assert_eq 1 "$rc"; assert_eq fail "$(status "$out" evals-present)"

# An unreadable SKILL.md fails cleanly (skipped when running as root, which ignores modes).
mkdir "$TMP/noread"; cp -R "$TMP/good/evals" "$TMP/noread/"; cp "$TMP/good/SKILL.md" "$TMP/noread/"; chmod 000 "$TMP/noread/SKILL.md"
if [[ ! -r "$TMP/noread/SKILL.md" ]]; then
  run "$TMP/noread"; assert_eq 1 "$rc"; assert_eq fail "$(status "$out" skill-md-present)"
fi

# Frontmatter: CRLF line endings are fine; a '----' line is not the closing fence.
mkdir "$TMP/crlf"; cp -R "$TMP/good/evals" "$TMP/crlf/"
printf -- '---\r\nname: crlf\r\ndescription: d\r\n---\r\nbody\r\n' > "$TMP/crlf/SKILL.md"
run "$TMP/crlf"; assert_eq 0 "$rc"; assert_eq pass "$(status "$out" frontmatter)"
mkdir "$TMP/fence"; cp -R "$TMP/good/evals" "$TMP/fence/"
printf -- '---\nname: fence\n----\ndescription: d\n---\nbody\n' > "$TMP/fence/SKILL.md"
run "$TMP/fence"; assert_eq pass "$(status "$out" description-present)"

# --- t-a350: defects found by the t-46dc break-it trial --------------------------------
GOODEVALS="$(cat "$ROOT/tests/fixtures/skill-check/good/evals/evals.json")"
# mkskill <name> <SKILL.md as a printf format> [evals.json]
mkskill() { local d="$TMP/$1"; mkdir -p "$d/evals"; printf '%b' "$2" > "$d/SKILL.md"; printf '%s' "${3:-$GOODEVALS}" > "$d/evals/evals.json"; }
FM='---\nname: t\ndescription: d\n---\nbody\n'
case3() { printf '{"evals":[{"id":%s,"case_type":"a","prompt":"p","expectations":["e"]},{"id":2,"case_type":"b","prompt":"p","expectations":["e"]},{"id":3,"case_type":"c","prompt":"p","expectations":["e"]}]}' "$1"; }

# Case ids become directory names in the generator: path syntax must fail the check.
for bad in '"x/../../../etc/y"' '".."' '"a/b"' '"/abs"' '""' '"has space"' '"a;b"' '["l"]' 'null'; do
  mkskill ids "$FM" "$(case3 "$bad")"; run "$TMP/ids"; assert_eq 1 "$rc"; assert_eq fail "$(status "$out" evals-ids)"
done
for good in '1' '"a-1"' '"todo_conv-2"'; do
  mkskill ids "$FM" "$(case3 "$good")"; run "$TMP/ids"; assert_eq pass "$(status "$out" evals-ids)"
done
mkskill ids "$FM" '{"evals":[{"id":1,"case_type":"a","prompt":"p","expectations":["e"]},{"id":"1","case_type":"b","prompt":"p","expectations":["e"]},{"id":3,"case_type":"c","prompt":"p","expectations":["e"]}]}'
run "$TMP/ids"; assert_eq 0 "$rc"; assert_eq warn "$(status "$out" evals-ids)"   # duplicate ids overwrite each other's case dir

# Trust: hooks must be detected however the key is written, and in ambiguous frontmatter.
mkskill hq1 '---\nname: t\n"hooks":\n  a: b\n---\nb\n';   run "$TMP/hq1"; assert_eq warn "$(status "$out" trust-hooks)"
mkskill hq2 "---\nname: t\n'hooks':\n  a: b\n---\nb\n";   run "$TMP/hq2"; assert_eq warn "$(status "$out" trust-hooks)"
mkskill hq3 '---\nname: t\nhooks :\n  a: b\n---\nb\n';    run "$TMP/hq3"; assert_eq warn "$(status "$out" trust-hooks)"
mkskill hq4 '---\nname: t\ndescription: "a\n---\nrest"\nhooks:\n  a: b\n---\nb\n'
run "$TMP/hq4"; assert_eq warn "$(status "$out" trust-hooks)"; assert_eq warn "$(status "$out" frontmatter-fences)"
mkskill hq5 "$FM"; run "$TMP/hq5"; assert_eq pass "$(status "$out" trust-hooks)"; assert_eq pass "$(status "$out" frontmatter-fences)"

# Shell-injection and side-effect heuristics must not be evaded by adjacency, spacing or case.
# shellcheck disable=SC2016  # the backticks are literal skill content
{
  mkskill si1 '---\nname: t\ndescription: d\n---\nx!`id`\n';               run "$TMP/si1"; assert_eq warn "$(status "$out" trust-shell-injection)"
  mkskill si2 '---\nname: t\ndescription: d\n---\n(!`touch x`)\n';         run "$TMP/si2"; assert_eq warn "$(status "$out" trust-shell-injection)"
  mkskill si3 '---\nname: t\ndescription: d\n---\nWow! Use `ls` here.\n';  run "$TMP/si3"; assert_eq pass "$(status "$out" trust-shell-injection)"
}
mkskill se1 '---\nname: t\ndescription: d\n---\nGIT   PUSH when done\n';    run "$TMP/se1"; assert_eq warn "$(status "$out" side-effects-guarded)"
mkskill se2 '---\nname: t\ndescription: d\n---\nrun git\tcommit -m x\n';    run "$TMP/se2"; assert_eq warn "$(status "$out" side-effects-guarded)"

# BOM: parsed, but reported.
mkskill bom '\xef\xbb\xbf---\nname: t\ndescription: d\n---\nb\n'
run "$TMP/bom"; assert_eq 0 "$rc"; assert_eq pass "$(status "$out" frontmatter)"; assert_eq warn "$(status "$out" bom)"

# Wrong-typed prompt / expectations warn instead of passing.
for cs in '{"id":1,"case_type":"a","prompt":"p","expectations":"x"}' '{"id":1,"case_type":"a","prompt":"p","expectations":{"a":1}}' \
          '{"id":1,"case_type":"a","prompt":["p"],"expectations":["e"]}' '{"id":1,"case_type":"a","prompt":"p","expectations":[1,2]}'; do
  mkskill wt "$FM" "{\"evals\":[$cs,{\"id\":2,\"case_type\":\"b\",\"prompt\":\"p\",\"expectations\":[\"e\"]},{\"id\":3,\"case_type\":\"c\",\"prompt\":\"p\",\"expectations\":[\"e\"]}]}"
  run "$TMP/wt"; assert_eq warn "$(status "$out" evals-shape)"
done

# Enum fields compare case-insensitively (a false fail would block a valid skill).
mkskill en '---\nname: t\ndescription: d\neffort: HIGH\ncontext: Fork\nshell: Bash\n---\nb\n'
run "$TMP/en"; assert_eq pass "$(status "$out" field-values)"

# Seeded fuzz: hostile evals.json / SKILL.md combinations must never crash the tool.
python3 - "$TOOL" "$TMP" <<'PYFUZZ'
import json, os, random, subprocess, sys
tool, tmp = sys.argv[1:3]
random.seed(20260921)
d = os.path.join(tmp, "fuzz"); os.makedirs(os.path.join(d, "evals"))
vals = [None, 1, -1, 2**70, 1.5, float("nan"), "", "x", "a/b", "..", "\x00", "é", [], [1], {}, {"a": [1]}, True]
keys = ["id", "case_type", "prompt", "expectations", "expected_output"]
skills = ["", "---\n", "---\n---\n", "﻿---\nname: x\n---\n", "---\r\nname: x\r\n---\r\nb\r\n", "---\n\"hooks\":\n a: b\n---\n",
          "---\nhooks :\n a: b\n---\n!`id`\n", "---\ndescription: \"a\n---\nz\"\nhooks:\n a: b\n---\n", "\xff\xfe", "---\ncontext: Fork\n---\n" + "x" * 5000]
for i in range(400):
    ev = {"evals": [{random.choice(keys): random.choice(vals) for _ in range(random.randint(0, 5))} for _ in range(random.randint(0, 5))]}
    if random.random() < 0.25:
        ev = random.choice(vals)
    with open(os.path.join(d, "evals", "evals.json"), "w") as f:
        f.write(json.dumps(ev, allow_nan=True))
    with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(random.choice(skills))
    r = subprocess.run([tool, d], capture_output=True, text=True)
    assert r.returncode in (0, 1) and "Traceback" not in r.stderr, (i, r.returncode, r.stderr[-300:], ev)
    json.loads(r.stdout)
print("skill-check fuzz: 400 cases, no crash")
PYFUZZ

# Must refuse: a path inside canon, including via a symlink; non-directory; bad usage.
rc=0; "$TOOL" "$ROOT/skills/capture" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
ln -s "$ROOT/skills/capture" "$TMP/link"
rc=0; "$TOOL" "$TMP/link" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
rc=0; "$TOOL" "$TMP/no-such-dir" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
rc=0; "$TOOL" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"

echo "skill-check: ok"
