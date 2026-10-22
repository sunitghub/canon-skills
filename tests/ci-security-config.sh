#!/usr/bin/env bash
# ci-security-config (t-b525, t-93ff) — every workflow in .github/workflows/ stays least-privilege and pinned, and no
# Dependabot config appears. canon-skills (public) mirrors every canon commit, so the workflows run there too: read-only,
# no pull_request_target, no secrets, no writes (issues, PRs, commits).
# A .github/dependabot.yml would switch version updates on in the mirror, which t-8493 keeps off on purpose.
# grep/awk only (no YAML parser). Each failure case is planted in a scratch copy below, so a pass proves the checks bite.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
WFD=.github/workflows
EXPECTED="govulncheck.yml vendored-updates.yml"

check_common() {   # check_common <workflow file>: the rules every workflow keeps
  local wf="$1"
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
  ! grep -qE 'GITHUB_TOKEN|github\.token' "$wf" || echo "GITHUB_TOKEN used"
  ! grep -qE '@latest' "$wf" || echo "@latest present"
  ! grep -qE 'continue-on-error|\|\|[[:space:]]*true' "$wf" || echo "a step failure is swallowed"
  ! grep -qE '(gh[[:space:]]+(issue|pr|release|api)|git[[:space:]]+(commit|push|tag))([[:space:]]|$)' "$wf" || echo "a write command (issue, PR, commit) present"
}

check() {   # check <root>: print one line per broken rule ("<file>: <rule>"), nothing when all hold
  local r="$1" wf name
  for name in $EXPECTED; do [[ -f "$r/$WFD/$name" ]] || echo "missing $WFD/$name"; done
  for wf in "$r/$WFD"/*.yml "$r/$WFD"/*.yaml; do
    [[ -e "$wf" ]] || continue
    name="$(basename "$wf")"
    check_common "$wf" | sed "s/^/$name: /"
    case "$name" in
      govulncheck.yml)
        { grep -qE 'go install golang\.org/x/vuln/cmd/govulncheck@v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' "$wf" \
            || echo "govulncheck not installed at an exact vX.Y.Z"
          grep -qE 'run:[[:space:]]*govulncheck[[:space:]]+\./\.\.\.[[:space:]]*$' "$wf" || echo "scan is not a bare 'govulncheck ./...'"
          grep -qE 'go-version-file:[[:space:]]*tools/canon-go/go\.mod' "$wf" || echo "no go-version-file: tools/canon-go/go.mod"
        } | sed "s/^/$name: /" ;;
      vendored-updates.yml)
        { grep -qE 'run:[[:space:]]*bash scripts/check-vendored\.sh --summary[[:space:]]*$' "$wf" \
            || echo "does not run a bare 'bash scripts/check-vendored.sh --summary'"
          grep -qE '^[[:space:]]+- cron:' "$wf" || echo "no schedule"
          grep -qE '^[[:space:]]+workflow_dispatch:' "$wf" || echo "no workflow_dispatch"
        } | sed "s/^/$name: /" ;;
    esac
  done
  # two scheduled workflows never share a minute (t-93ff: a different minute from govulncheck's)
  cat "$r/$WFD"/*.yml "$r/$WFD"/*.yaml 2>/dev/null | grep -E '^[[:space:]]+- cron:' | sort | uniq -d | sed 's/^ */cron shared by two workflows: /' || true
  [[ ! -e "$r/.github/dependabot.yml" && ! -e "$r/.github/dependabot.yaml" ]] || echo "dependabot config present"
}

got="$(check "$ROOT")"
[[ -z "$got" ]] || fail "ci-security-config: $got"

# revert checks: break one rule per scratch copy; the check must name it
T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/ci-security-config.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
n=0
plant() {   # plant <expected substring> <workflow | "dependabot"> <sed expression | "rm">
  n=$((n + 1)); local d="$WORK/$n"; mkdir -p "$d/$WFD"; cp "$ROOT/$WFD"/* "$d/$WFD/"
  if [[ "$2" == dependabot ]]; then : > "$d/.github/dependabot.yml"; elif [[ "$3" == rm ]]; then rm "$d/$WFD/$2"; else sed -i.bak -E "$3" "$d/$WFD/$2" && rm "$d/$WFD/$2.bak"; fi
  local out; out="$(check "$d")"
  [[ "$out" == *"$1"* ]] || fail "ci-security-config: planting '$3' in $2 should report '$1', got: ${out:-nothing}"
}
G=govulncheck.yml; V=vendored-updates.yml
plant "$G: action not pinned to a full SHA" $G 's/(checkout@)[0-9a-f]{40}/\1v7.0.1/'
plant "$G: no top-level permissions" $G '/^permissions:/,/^  contents: read/d'
plant "$G: permission beyond contents: read" $G 's/^  contents: read/  contents: write/'
plant "$G: top-level permissions not the block form" $G 's/^permissions:$/permissions: write-all/'
plant "$G: job-level permissions present" $G 's/^    runs-on: ubuntu-latest$/    permissions: write-all/'
plant "$G: pull_request_target present" $G 's/^  pull_request:/  pull_request_target:/'
plant "$G: secrets referenced" $G 's/^(          cache: false)$/          token: ${{ secrets.GITHUB_TOKEN }}/'
plant "$G: govulncheck not installed at an exact" $G 's/govulncheck@v[0-9.]+/govulncheck@latest/'
plant "$G: @latest present" $G 's/govulncheck@v[0-9.]+/govulncheck@latest/'
plant "$G: govulncheck not installed at an exact" $G 's/govulncheck@v[0-9.]+$/govulncheck/'
plant "$G: a step failure is swallowed" $G 's/run: govulncheck \.\/\.\.\./run: govulncheck .\/... || true/'
plant "$G: a step failure is swallowed" $G 's/^        working-directory: tools\/canon-go$/        continue-on-error: true/'
plant "$G: no go-version-file" $G '/go-version-file:/d'
plant "$V: action not pinned to a full SHA" $V 's/(checkout@)[0-9a-f]{40}/\1v7.0.1/'
plant "$V: permission beyond contents: read" $V 's/^  contents: read/  contents: read\n  issues: write/'
plant "$V: job-level permissions present" $V 's/^    timeout-minutes: 10$/    permissions:\n      pull-requests: write/'
plant "$V: pull_request_target present" $V 's/^  workflow_dispatch:/  workflow_dispatch:\n  pull_request_target:/'
plant "$V: secrets referenced" $V 's/^(        run: bash scripts\/check-vendored\.sh --summary)$/\1\n        env:\n          T: ${{ secrets.NPM_TOKEN }}/'
plant "$V: GITHUB_TOKEN used" $V 's/^(        run: bash scripts\/check-vendored\.sh --summary)$/\1\n        env:\n          GH_TOKEN: ${{ github.token }}/'
plant "$V: a step failure is swallowed" $V 's/--summary$/--summary || true/'
plant "$V: a write command (issue, PR, commit) present" $V 's/--summary$/--summary; gh issue create --title advisory/'
plant "$V: does not run a bare 'bash scripts/check-vendored.sh --summary'" $V 's/ --summary$//'
plant "$V: no schedule" $V '/- cron:/d'
plant "$V: no workflow_dispatch" $V '/workflow_dispatch:/d'
plant "cron shared by two workflows" $V 's/"41 6 \* \* 1"/"17 6 * * 1"/'
plant "missing $WFD/$V" $V rm
plant "dependabot config present" dependabot ""

echo "ci-security-config: ok ($(ls "$ROOT/$WFD" | wc -l | tr -d ' ') workflows pinned and read-only, no dependabot config; $n planted breaks caught)"
