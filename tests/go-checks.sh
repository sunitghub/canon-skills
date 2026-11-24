#!/usr/bin/env bash
# go-checks (t-9a2b) — tools/go-checks.sh, the one owner of the staticcheck and gosec command lines that
# .github/workflows/go-checks.yml (with --require) and tools/pre-gate-check.sh (advisory) run. With fake tools on PATH:
# clean is 0, a finding is 1, a missing tool is 2 under --require and `skipped` (0) without it, no packages means ./...,
# .gosec-excludes reaches gosec as one -exclude= list, and a line without a reason is 2 naming it. Also: every rule in
# canon's tools/canon-go/.gosec-excludes is in docs/ci-security.md's exclusions table (the user asked for the notes there).
# Protects: the go-checks.yml job on canon-skills and the pre-gate step of `sprint complete`.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
GC="$ROOT/tools/go-checks.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# PATH without any real staticcheck/gosec, plus a dir of fakes that log their argv
NOLINT=""; IFS=: read -ra pdirs <<<"$PATH"
for d in "${pdirs[@]}"; do [[ -x "$d/staticcheck" || -x "$d/gosec" ]] || NOLINT+="${NOLINT:+:}$d"; done
FAKE="$WORK/fake"; mkdir -p "$FAKE"
for t in staticcheck gosec; do
  printf '#!/usr/bin/env bash\necho "$*" > "%s/%s.argv"; pwd > "%s/%s.pwd"\n[[ "${FAKE_FIND:-}" != %s ]] || { echo "%s planted finding"; exit 1; }\n' "$WORK" "$t" "$WORK" "$t" "$t" "$t" > "$FAKE/$t"
  chmod +x "$FAKE/$t"
done
M="$WORK/mod"; mkdir -p "$M"; printf 'module m\n\ngo 1.21\n' > "$M/go.mod"

run() { set +e; out="$(PATH="$1" bash "$GC" "${@:2}" 2>&1)"; code=$?; set -e; }

# clean, default packages, no excludes file
run "$FAKE:$NOLINT" --require "$M"
assert_eq 0 "$code"; assert_contains "$out" "staticcheck ok" "go-checks: staticcheck ok"; assert_contains "$out" "gosec ok" "go-checks: gosec ok"
assert_eq "./..." "$(cat "$WORK/staticcheck.argv")"
assert_eq "-quiet ./..." "$(cat "$WORK/gosec.argv")"
# both tools run inside the module, so ./... means its packages
assert_eq "$M" "$(cat "$WORK/staticcheck.pwd")"; assert_eq "$M" "$(cat "$WORK/gosec.pwd")"

# a finding from either tool is 1, with the tool's own output; a staticcheck finding still lets gosec run
for t in staticcheck gosec; do
  rm -f "$WORK"/*.argv
  set +e; out="$(FAKE_FIND=$t PATH="$FAKE:$NOLINT" bash "$GC" --require "$M" ./a 2>&1)"; code=$?; set -e
  assert_eq 1 "$code"; assert_contains "$out" "$t planted finding" "go-checks: $t finding shown"; assert_contains "$out" "$t FAIL" "go-checks: $t FAIL line"
  [[ -f "$WORK/staticcheck.argv" && -f "$WORK/gosec.argv" ]] || fail "go-checks: a $t finding stopped the other tool"
done
assert_eq "-quiet ./a" "$(cat "$WORK/gosec.argv")"

# missing tools: 2 under --require, skipped (0) without
run "$NOLINT" --require "$M"
assert_eq 2 "$code"; assert_contains "$out" "staticcheck not installed" "go-checks: --require names the missing tool"
run "$NOLINT" "$M"
assert_eq 0 "$code"; assert_contains "$out" "staticcheck skipped | not installed" "go-checks: missing tool is skipped"
assert_contains "$out" "gosec skipped | not installed" "go-checks: missing gosec is skipped"

# .gosec-excludes: comments and blanks skipped, rules joined into one -exclude=
printf '# note\n\nG104 a reason\nG304 another reason\n' > "$M/.gosec-excludes"
run "$FAKE:$NOLINT" --require "$M"
assert_eq 0 "$code"; assert_eq "-quiet -exclude=G104,G304 ./..." "$(cat "$WORK/gosec.argv")"
# a rule with no reason is refused, naming the line
printf 'G104 a reason\nG304\n' > "$M/.gosec-excludes"
run "$FAKE:$NOLINT" --require "$M"
assert_eq 2 "$code"; assert_contains "$out" ".gosec-excludes:2: needs 'G<nnn> <reason>'" "go-checks: reasonless exclude refused"
run "$FAKE:$NOLINT" "$M" "./..."
assert_eq 2 "$code"
# the rule must start the line
printf 'XG104 a reason\n' > "$M/.gosec-excludes"
run "$FAKE:$NOLINT" --require "$M"
assert_eq 2 "$code"; assert_contains "$out" ".gosec-excludes:1: needs" "go-checks: a line not starting with G<nnn> refused"
# a last line without a newline still counts
printf 'G104 a reason\nG304 another reason' > "$M/.gosec-excludes"
run "$FAKE:$NOLINT" --require "$M"
assert_eq 0 "$code"; assert_eq "-quiet -exclude=G104,G304 ./..." "$(cat "$WORK/gosec.argv")"
rm -f "$M/.gosec-excludes"

# usage: no module, or a dir with no go.mod
run "$FAKE:$NOLINT"; assert_eq 2 "$code"
run "$FAKE:$NOLINT" "$WORK"; assert_eq 2 "$code"; assert_contains "$out" "has no go.mod" "go-checks: no go.mod"

# canon's own excludes are each in docs/ci-security.md's exclusions table (`| G<nnn> |` rows)
doc_missing() {   # doc_missing <excludes file> <doc>: prints each excluded rule the doc's table lacks
  local r
  while read -r r _; do
    [[ "$r" =~ ^G[0-9]{3}$ ]] || continue
    grep -qE "^\| *$r *\|" "$2" || echo "$r"
  done < "$1"
}
miss="$(doc_missing "$ROOT/tools/canon-go/.gosec-excludes" "$ROOT/docs/ci-security.md")"
[[ -z "$miss" ]] || fail "go-checks: docs/ci-security.md's exclusions table lacks: $miss"
grep -v '^| *G104 *|' "$ROOT/docs/ci-security.md" > "$WORK/doc.md"
[[ "$(doc_missing "$ROOT/tools/canon-go/.gosec-excludes" "$WORK/doc.md")" == G104 ]] || fail "go-checks: a planted missing doc row was not caught"

echo "go-checks: ok"
