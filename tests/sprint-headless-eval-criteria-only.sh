#!/usr/bin/env bash
# sprint-headless-eval-criteria-only.sh — unit tests for --criteria-only scoping
# in tools/sprint-headless-eval, via the --print-criteria seam (no claude/network).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
EVAL="tools/sprint-headless-eval"

fails=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
assert() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

tmp="$(mktemp -d "$repo_root/.cotest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

spec="$tmp/acc.md"
cat > "$spec" <<'EOF'
# sample acceptance
## Criteria
- [ ] criterion ALPHA
- [ ] criterion BETA
## Test Plan
- [ ] run `bash something.sh` and see PASS
## QA
- [ ] Tested locally
EOF

echo "--- default: grades Criteria + Test Plan (not QA) ---"
def="$(bash "$EVAL" "$spec" --base-ref HEAD --print-criteria)"
assert 'printf "%s\n" "$def" | grep -q "criterion ALPHA"'          "default includes Criteria items"
assert 'printf "%s\n" "$def" | grep -q "something.sh"'            "default includes Test Plan items"
assert '! printf "%s\n" "$def" | grep -q "Tested locally"'         "default excludes QA items"

echo "--- --criteria-only: grades Criteria, skips Test Plan + QA ---"
conly="$(bash "$EVAL" "$spec" --base-ref HEAD --criteria-only --print-criteria)"
assert 'printf "%s\n" "$conly" | grep -q "criterion ALPHA"'        "criteria-only includes Criteria items"
assert 'printf "%s\n" "$conly" | grep -q "criterion BETA"'         "criteria-only includes all Criteria items"
assert '! printf "%s\n" "$conly" | grep -q "bash .something.sh"'   "criteria-only EXCLUDES Test Plan items"
assert '! printf "%s\n" "$conly" | grep -q "Tested locally"'       "criteria-only excludes QA items"

echo "--- --criteria-only with no ## Criteria heading → clear error ---"
bare="$tmp/bare.md"; printf '# x\n- [ ] a bare item\n' > "$bare"
set +e; bout="$(bash "$EVAL" "$bare" --base-ref HEAD --criteria-only --print-criteria 2>&1)"; brc=$?; set -e
assert '[ "$brc" -ne 0 ]'                                          "criteria-only with no Criteria heading exits non-zero"
assert 'printf "%s" "$bout" | grep -q "criteria-only"'             "error hints about --criteria-only"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
