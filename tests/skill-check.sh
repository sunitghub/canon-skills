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
# A non-object entry inside a valid list is a shape warning, not a crash.
echo '{"evals":[1,{"id":2,"case_type":"a","prompt":"p","expectations":["e"]},{"id":3,"case_type":"b","prompt":"p","expectations":["e"]}]}' > "$TMP/shape/evals/evals.json"
run "$TMP/shape"; assert_eq 0 "$rc"
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

# Must refuse: a path inside canon, including via a symlink; non-directory; bad usage.
rc=0; "$TOOL" "$ROOT/skills/capture" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
ln -s "$ROOT/skills/capture" "$TMP/link"
rc=0; "$TOOL" "$TMP/link" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
rc=0; "$TOOL" "$TMP/no-such-dir" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
rc=0; "$TOOL" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"

echo "skill-check: ok"
