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

TPL=tools/canon-gate-template.yml
check_template() {   # check_template <file> (t-04f4): the workflow the board writes into consumer repos
  local t="$1"
  grep -nE '^[[:space:]-]*uses:' "$t" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' \
    | sed 's/^/action not pinned to a full SHA: /' || true
  grep -qE '^permissions:$' "$t" || echo "no top-level permissions block"
  ! grep -qE '^[[:space:]]+permissions:' "$t" || echo "job-level permissions present"
  awk '/^permissions:/{p=1;next} p&&/^[^[:space:]#]/{p=0} p&&/[^[:space:]]/{print}' "$t" \
    | grep -vE '^[[:space:]]*contents:[[:space:]]*read[[:space:]]*$' | sed 's/^/permission beyond contents: read: /' || true
  grep -qE '^  pull_request:' "$t" || echo "not triggered by pull_request"
  ! grep -qE 'pull_request_target|workflow_run' "$t" || echo "pull_request_target or workflow_run present"
  local co pc; co="$(grep -cE 'uses:[[:space:]]*actions/checkout@' "$t" || true)"; pc="$(grep -cE '^[[:space:]]+persist-credentials:[[:space:]]*false[[:space:]]*$' "$t" || true)"
  [[ "$co" -ge 1 && "$co" == "$pc" ]] || echo "a checkout keeps its credentials ($co checkouts, $pc persist-credentials: false)"
  grep -qE '^[[:space:]]+ref:[[:space:]]*__CANON_REF__([[:space:]]|$)' "$t" || echo "canon checkout not pinned by the __CANON_REF__ placeholder"
  grep -qE 'npm install -g @anthropic-ai/claude-code@[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' "$t" || echo "Claude Code CLI not installed at an exact x.y.z"
  local secrets exprs   # captured first: no early-exit reader on a pipe (pipefail-early-exit)
  secrets="$(grep -oE 'secrets\.[A-Za-z_]+' "$t" | grep -vx 'secrets.ANTHROPIC_API_KEY' || true)"
  [[ -z "$secrets" ]] || echo "a secret other than ANTHROPIC_API_KEY"
  exprs="$(grep -nE '\$\{\{' "$t" | grep -vE '^[0-9]+:[[:space:]]+[A-Za-z_-]+:[[:space:]]*\$\{\{[^}]*\}\}[^$]*$' || true)"
  [[ -z "$exprs" ]] || echo "a \${{ }} expression outside a whole key value (e.g. inside run:)"
  ! grep -qE '@latest' "$t" || echo "@latest present"
  ! grep -qE 'continue-on-error|\|\|[[:space:]]*true' "$t" || echo "a step failure is swallowed"
  ! grep -qE '(gh[[:space:]]+(issue|pr|release|api)|git[[:space:]]+(commit|push|tag))([[:space:]]|$)' "$t" || echo "a write command (issue, PR, commit) present"
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
  if [[ -f "$r/$TPL" ]]; then check_template "$r/$TPL" | sed "s|^|$TPL: |"; else echo "missing $TPL"; fi
}

got="$(check "$ROOT")"
[[ -z "$got" ]] || fail "ci-security-config: $got"

# revert checks: break one rule per scratch copy; the check must name it
T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/ci-security-config.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
n=0
plant() {   # plant <expected substring> <workflow | "dependabot"> <sed expression | "rm">
  n=$((n + 1)); local d="$WORK/$n"; mkdir -p "$d/$WFD" "$d/tools"; cp "$ROOT/$WFD"/* "$d/$WFD/"; cp "$ROOT/$TPL" "$d/$TPL"
  local f="$d/$WFD/$2"; [[ "$2" == "$TPL" ]] && f="$d/$TPL"
  if [[ "$2" == dependabot ]]; then : > "$d/.github/dependabot.yml"; elif [[ "$3" == rm ]]; then rm "$f"; else sed -i.bak -E "$3" "$f" && rm "$f.bak"; fi
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
# the generated canon-gate template (t-04f4)
plant "$TPL: action not pinned to a full SHA" $TPL '1,/(checkout@)[0-9a-f]{40}/s/(checkout@)[0-9a-f]{40}/\1v7.0.1/'
plant "$TPL: no top-level permissions block" $TPL '/^permissions:$/,/^  contents: read$/d'
plant "$TPL: permission beyond contents: read" $TPL 's/^  contents: read$/  contents: read\n  pull-requests: write/'
plant "$TPL: job-level permissions present" $TPL 's/^    runs-on: ubuntu-latest$/    runs-on: ubuntu-latest\n    permissions: write-all/'
plant "$TPL: not triggered by pull_request" $TPL 's/^  pull_request:$/  push:/'
plant "$TPL: pull_request_target or workflow_run present" $TPL 's/^  pull_request:$/  pull_request_target:/'
plant "$TPL: a checkout keeps its credentials" $TPL '1,/persist-credentials: false/{/persist-credentials: false/d;}'
plant "$TPL: canon checkout not pinned by the __CANON_REF__ placeholder" $TPL 's/ref: __CANON_REF__/ref: main/'
plant "$TPL: Claude Code CLI not installed at an exact x.y.z" $TPL 's/claude-code@[0-9.]+$/claude-code/'
plant "$TPL: @latest present" $TPL 's/claude-code@[0-9.]+$/claude-code@latest/'
plant "$TPL: a secret other than ANTHROPIC_API_KEY" $TPL 's/secrets\.ANTHROPIC_API_KEY/secrets.DEPLOY_TOKEN/'
plant "$TPL: a \${{ }} expression outside a whole key value" $TPL 's/gate-ticket-check "\$BASE_SHA"/gate-ticket-check "${{ github.event.pull_request.base.sha }}"/'
plant "$TPL: a step failure is swallowed" $TPL 's/^(        run: npm install -g .*)$/\1 || true/'
plant "$TPL: a write command (issue, PR, commit) present" $TPL 's/^(        run: npm install -g .*)$/\1; gh pr comment 1 -b x/'
plant "missing $TPL" $TPL rm

echo "ci-security-config: ok ($(ls "$ROOT/$WFD" | wc -l | tr -d ' ') workflows and the canon-gate template pinned and least-privilege, no dependabot config; $n planted breaks caught)"
