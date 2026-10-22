#!/usr/bin/env bash
# ci-security-config (t-b525) — the govulncheck workflow stays least-privilege and pinned, and no Dependabot config appears.
# canon-skills (public) mirrors every canon commit, so the workflow runs there too: read-only, no pull_request_target.
# A .github/dependabot.yml would switch version updates on in the mirror, which t-8493 keeps off on purpose.
# grep/awk only (no YAML parser). Each failure case is planted in a scratch copy below, so a pass proves the checks bite.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
WF=.github/workflows/govulncheck.yml

check() {   # check <root>: print one line per broken rule, nothing when all hold
  local r="$1" wf="$1/$WF"
  [[ -f "$wf" ]] || { echo "missing $WF"; return 0; }
  # every `uses:` names an action at a full 40-hex commit SHA
  grep -nE '^[[:space:]-]*uses:' "$wf" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' \
    | sed 's/^/action not pinned to a full SHA: /' || true
  grep -qE '^permissions:' "$wf" || echo "no top-level permissions"
  ! grep -qE '^permissions:[[:space:]]*[^[:space:]#]' "$wf" || echo "top-level permissions not the block form"
  ! grep -qE '^[[:space:]]+permissions:' "$wf" || echo "job-level permissions present"
  awk '/^permissions:/{p=1;next} p&&/^[^[:space:]#]/{p=0} p&&/[^[:space:]]/{print}' "$wf" \
    | grep -vE '^[[:space:]]*contents:[[:space:]]*read[[:space:]]*$' | sed 's/^/permission beyond contents: read: /' || true
  ! grep -q 'pull_request_target' "$wf" || echo "pull_request_target present"
  ! grep -qE 'secrets\.' "$wf" || echo "secrets referenced"
  grep -qE 'go install golang\.org/x/vuln/cmd/govulncheck@v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' "$wf" \
    || echo "govulncheck not installed at an exact vX.Y.Z"
  ! grep -qE '@latest' "$wf" || echo "@latest present"
  grep -qE 'run:[[:space:]]*govulncheck[[:space:]]+\./\.\.\.[[:space:]]*$' "$wf" || echo "scan is not a bare 'govulncheck ./...'"
  ! grep -qE 'continue-on-error|\|\|[[:space:]]*true' "$wf" || echo "scan failure is swallowed"
  grep -qE 'go-version-file:[[:space:]]*tools/canon-go/go\.mod' "$wf" || echo "no go-version-file: tools/canon-go/go.mod"
  [[ ! -e "$r/.github/dependabot.yml" && ! -e "$r/.github/dependabot.yaml" ]] || echo "dependabot config present"
}

got="$(check "$ROOT")"
[[ -z "$got" ]] || fail "ci-security-config: $got"

# revert checks: break one rule per scratch copy; the check must name it
T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/ci-security-config.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
n=0
plant() {   # plant <expected substring> <sed expression | "dependabot">
  n=$((n + 1)); local d="$WORK/$n"; mkdir -p "$d/.github/workflows"; cp "$ROOT/$WF" "$d/$WF"
  if [[ "$2" == dependabot ]]; then : > "$d/.github/dependabot.yml"; else sed -i.bak -E "$2" "$d/$WF"; fi
  local out; out="$(check "$d")"
  [[ "$out" == *"$1"* ]] || fail "ci-security-config: planting '$2' should report '$1', got: ${out:-nothing}"
}
plant "action not pinned to a full SHA" 's/(checkout@)[0-9a-f]{40}/\1v7.0.1/'
plant "no top-level permissions" '/^permissions:/,/^  contents: read/d'
plant "permission beyond contents: read" 's/^  contents: read/  contents: write/'
plant "top-level permissions not the block form" 's/^permissions:$/permissions: write-all/'
plant "job-level permissions present" 's/^    runs-on: ubuntu-latest$/    permissions: write-all/'
plant "pull_request_target present" 's/^  pull_request:/  pull_request_target:/'
plant "secrets referenced" 's/^(          cache: false)$/          token: ${{ secrets.GITHUB_TOKEN }}/'
plant "govulncheck not installed at an exact" 's/govulncheck@v[0-9.]+/govulncheck@latest/'
plant "@latest present" 's/govulncheck@v[0-9.]+/govulncheck@latest/'
plant "govulncheck not installed at an exact" 's/govulncheck@v[0-9.]+$/govulncheck/'
plant "scan failure is swallowed" 's/run: govulncheck \.\/\.\.\./run: govulncheck .\/... || true/'
plant "scan failure is swallowed" 's/^        working-directory: tools\/canon-go$/        continue-on-error: true/'
plant "no go-version-file" '/go-version-file:/d'
plant "dependabot config present" dependabot

echo "ci-security-config: ok (govulncheck workflow pinned and read-only, no dependabot config; 14 planted breaks caught)"
