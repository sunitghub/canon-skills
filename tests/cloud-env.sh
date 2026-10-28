#!/usr/bin/env bash
# t-9955: tools/cloud-env.sh owns the Claude cloud recipe. Protects `tkt cloud-env` (what a user pastes into the environment
# dialog), the doctor's `cloud` field (Factory › GitHub's Copy buttons) and docs/setup.md, which must show the same --go recipe.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
CE="$ROOT/tools/cloud-env.sh"

# Base vs --go: four base domains (getcanon.dev first: install.sh reads its release manifest), four more with --go;
# the Go toolchain block only with --go, between the install line and the tool wrappers.
assert_eq "getcanon.dev github.com raw.githubusercontent.com objects.githubusercontent.com" "$(bash "$CE" domains | paste -sd' ' -)"
assert_eq "8" "$(bash "$CE" domains --go | wc -l | tr -d ' ')"
assert_eq "go.dev dl.google.com proxy.golang.org sum.golang.org" "$(bash "$CE" domains --go | tail -4 | paste -sd' ' -)"
base="$(bash "$CE" script)"; go="$(bash "$CE" script --go)"
grep -q 'GOV=' <<< "$base" && fail "the base script carries the Go block"
grep -q 'GOV=' <<< "$go" || fail "the --go script lacks the Go block"
for s in "$base" "$go"; do
  assert_eq "#!/bin/bash" "$(head -1 <<< "$s")"
  assert_contains "$s" "https://getcanon.dev/install.sh | bash"
  assert_contains "$s" 'cp "$HOME/.canon/agents/canon-reviewer.md"'
done
[[ "$(grep -n 'GOV=' <<< "$go" | cut -d: -f1)" -lt "$(grep -n '^for t in' <<< "$go" | cut -d: -f1)" ]] || fail "the Go block is not before the wrappers"
rc=0; bash "$CE" domains --python >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"
rc=0; bash "$CE" >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"

# tkt cloud-env picks --go from a tracked go.mod at any depth (canon's own is tools/canon-go/go.mod); untracked does not count.
project="$(make_project)"; trap 'rm -rf "$project"' EXIT
cd "$project"
json() { "$TKT" cloud-env --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["go"], len(d["domains"]), "GOV=" in d["setup_script"])'; }
assert_eq "False 4 False" "$(json)"
mkdir -p tools/canon-go && printf 'module x\n' > tools/canon-go/go.mod
assert_eq "False 4 False" "$(json)"   # not tracked yet
git add tools/canon-go/go.mod
assert_eq "True 8 True" "$(json)"
txt="$("$TKT" cloud-env)"
assert_contains "$txt" "# Network access: Limited, with these domains added and Allow package managers ticked (a Go project: base plus Go)"
assert_contains "$txt" "sum.golang.org"
assert_eq "$go" "$(sed -n '/^# Setup script$/,$p' <<< "$txt" | tail -n +2)"
rc=0; "$TKT" cloud-env --yaml >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"
# A tools/ copy without cloud-env.sh: text mode says what is missing and exits 1 (not 127); --json gives empty values.
part="$(mktemp -d)"; cp "$ROOT/tools/tkt" "$ROOT/tools/ticket-root.sh" "$ROOT/tools/frontmatter-lib.sh" "$ROOT/tools/platform-lib.sh" "$part/"
rc=0; err="$("$part/tkt" cloud-env 2>&1 >/dev/null)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$err" "cloud-env.sh is missing; run canon update"
assert_eq '{"go":true,"domains":[],"setup_script":""}' "$("$part/tkt" cloud-env --json 2>/dev/null)"
rm -rf "$part"

# docs/setup.md shows the full (--go) recipe: the script block byte for byte and the same domain list.
doc="$ROOT/docs/setup.md"
blk="$(awk '/^## /{on = ($0 == "## Claude cloud sessions")} on && /^- \*\*Setup script\*\*/{s=1; next} s && /^  ```bash$/{b=1; next} b && /^  ```$/{exit} b{sub(/^  /, ""); print}' "$doc")"
assert_eq "$go" "$blk"
doms="$(awk '/^## /{on = ($0 == "## Claude cloud sessions")} on && /^- \*\*Network access:\*\*/{d=1} on && /^- \*\*Setup script\*\*/{d=0} d' "$doc" \
  | grep -oE '`[a-z0-9.-]+\.(dev|com|org)`' | tr -d '`' | paste -sd' ' -)"
assert_eq "$(bash "$CE" domains --go | paste -sd' ' -)" "$doms"
echo "cloud-env: ok"
