#!/usr/bin/env bash
# tkt github-doctor (t-90a3): the readiness checks Admin › GitHub and the worktree picker's GitHub row (t-24b1) render.
# Each gh / origin / test-command state gives its status and fix, the cloud recipe is docs/setup.md's, and nothing changes.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
CANON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

project="$(make_project)"
W="$(mktemp -d "${TMPDIR:-/tmp}/tkt-github-doctor.XXXXXX")"
trap 'rm -rf "$project" "$W"' EXIT
cd "$project"

# A stub gh that logs every call: STUB_GH=out fails `auth status`; STUB_VIS is the repo's visibility. curl is stubbed so
# the visibility fallback never reaches the network. nogh/ is PATH with every gh removed: the "not installed" case.
mkdir -p "$W/bin" "$W/nogh"
cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "auth status") [[ "${STUB_GH:-}" == out ]] && exit 1; exit 0 ;;
  "api user")    [[ "${STUB_GH:-}" == nouser ]] && exit 1; echo octo ;;
  "api repos/"*) [[ "${STUB_GH:-}" == out || "${STUB_VIS:-}" == none ]] && exit 1; echo "${STUB_VIS:-private}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho 000\n' > "$W/bin/curl"
chmod +x "$W/bin/gh" "$W/bin/curl"
# A PATH dir that holds gh is replaced by links to its other entries (never curl: the stub is copied in, not written
# through a link to the real one).
cp "$W/bin/curl" "$W/nogh/curl"; NOGH_PATH="$W/nogh"
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  if [[ -x "$d/gh" ]]; then
    for f in "$d"/*; do n="${f##*/}"; [[ "$n" != gh && ! -e "$W/nogh/$n" ]] && ln -s "$f" "$W/nogh/$n"; done
  else NOGH_PATH+=":$d"; fi
done
export STUB_LOG="$W/log"

doctor() { "$TKT" github-doctor --json; }
# field <json> <python expression over d>: the expressions are this file's own literals, never input.
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }
# check <json> <id>: "status|title|fix cmd|fix url", and "nofix" in place of the fix fields when the check has no fix key.
check() { field "$1" "'|'.join([c['status'], c['title']] + ([c['fix'].get('cmd',''), c['fix'].get('url','')] if 'fix' in c else ['nofix'])) if (c := next(c for c in d['checks'] if c['id'] == '$2')) else ''"; }
before="$(git status --porcelain; git for-each-ref)"

# Not installed; no origin; no commit yet, so no scripts/test.sh.
out="$(PATH="$NOGH_PATH" "$TKT" github-doctor --json)"
assert_eq "bad|GitHub CLI (gh) is not installed||https://github.com/cli/cli" "$(check "$out" gh)"
assert_eq "bad|No GitHub repository for this project|git remote add origin https://github.com/<owner>/<repo>.git|" "$(check "$out" origin)"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "no git remote named origin"
assert_eq "warn|No test command|nofix" "$(check "$out" tests)"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
assert_contains "$(field "$out" "d['checks'][2]['detail']")" "merges on the gates alone"

# Installed but signed out; a non-GitHub origin.
git remote add origin https://gitlab.com/acme/app.git
out="$(PATH="$W/bin:$PATH" STUB_GH=out doctor)"
assert_eq "bad|gh is installed, but not signed in|gh auth login|" "$(check "$out" gh)"
assert_eq "bad|No GitHub repository for this project|git remote add origin https://github.com/<owner>/<repo>.git|" "$(check "$out" origin)"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "https://gitlab.com/acme/app.git"

# Signed in; a private GitHub origin; an executable scripts/test.sh committed.
git remote set-url origin git@github.com:acme/app.git
mkdir -p scripts; printf '#!/bin/sh\n' > scripts/test.sh; chmod +x scripts/test.sh
git add scripts/test.sh; git -c user.name=t -c user.email=t@t commit -q -m tests
before="$(git status --porcelain; git for-each-ref)"; : > "$STUB_LOG"
out="$(PATH="$W/bin:$PATH" doctor)"
assert_eq "ok|Signed in to GitHub|nofix" "$(check "$out" gh)"; assert_eq "Signed in as octo." "$(field "$out" "d['checks'][0]['detail']")"
assert_eq "ok|Repository found, and private|nofix" "$(check "$out" origin)"; assert_eq "Issues go to acme/app (origin, private)." "$(field "$out" "d['checks'][1]['detail']")"
assert_eq "ok|Check & merge test command: scripts/test.sh|nofix" "$(check "$out" tests)"
# Read-only: only these gh reads ran, and the repo is as it was.
assert_eq "auth status|api user --jq .login|api repos/acme/app --jq .visibility" "$(paste -sd'|' "$STUB_LOG")"
assert_eq "$before" "$(git status --porcelain; git for-each-ref)"
# The plain form: one line per check, no fix line for a check without one, and no JSON after it.
plain="$(PATH="$W/bin:$PATH" "$TKT" github-doctor)"
assert_eq "ok    Repository found, and private — Issues go to acme/app (origin, private)." "$(sed -n 2p <<< "$plain")"
[[ "$plain" != *"fix:"* && "$plain" != *'{"checks"'* ]] || fail "plain output of an all-ok doctor: $plain"
# A gh that cannot name the account, and one that cannot read the repo (curl gives no answer either): still exit 0.
out="$(PATH="$W/bin:$PATH" STUB_GH=nouser STUB_VIS=none doctor)"
assert_eq "ok|Signed in to GitHub|nofix" "$(check "$out" gh)"; assert_eq "" "$(field "$out" "d['checks'][0]['detail']")"
assert_eq "warn|Repository found; visibility unknown|nofix" "$(check "$out" origin)"

# Public origin: a warning naming --public. A scripts/test.sh that is not executable is no test command.
chmod -x scripts/test.sh; git -c user.name=t -c user.email=t@t commit -q -am 'not executable'
out="$(PATH="$W/bin:$PATH" STUB_VIS=public doctor)"
assert_eq "warn|Repository found, and public|nofix" "$(check "$out" origin)"; assert_contains "$(field "$out" "d['checks'][1]['detail']")" "Send needs --public"
assert_eq "warn|No test command|nofix" "$(check "$out" tests)"

# The cloud recipe is docs/setup.md's setup-script block, byte for byte, and its domains; no docs gives empty values.
want="$(python3 - "$CANON/docs/setup.md" <<'EOF'
import sys
t = open(sys.argv[1]).read().split('\n## Claude cloud sessions\n', 1)[1].split('\n## ', 1)[0]
blk = t.split('**Setup script**', 1)[1].split('  ```bash\n', 1)[1].split('\n  ```\n', 1)[0]
print('\n'.join(l[2:] for l in blk.split('\n')))
EOF
)"
assert_eq "$want" "$(field "$out" "d['cloud']['setup_script']")"
assert_eq "True" "$(field "$out" "'getcanon.dev' in d['cloud']['domains'] and 'sum.golang.org' in d['cloud']['domains']")"
mkdir -p "$W/canon/tools"; cp "$CANON/tools/tkt" "$CANON/tools/ticket-root.sh" "$CANON/tools/frontmatter-lib.sh" "$W/canon/tools/"
out="$(PATH="$W/bin:$PATH" "$W/canon/tools/tkt" github-doctor --json)"
assert_eq "[]|" "$(field "$out" "str(d['cloud']['domains']) + '|' + d['cloud']['setup_script']")"

# Exits 0 when checks fail, and the plain form shows each fix.
rc=0; plain="$(PATH="$NOGH_PATH" "$TKT" github-doctor)" || rc=$?
assert_eq 0 "$rc"; assert_contains "$plain" "fix: https://github.com/cli/cli"
assert_contains "$plain" "bad   GitHub CLI (gh) is not installed — Every GitHub step runs gh as you."
rc=0; "$TKT" github-doctor --jsn >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"
echo "tkt-github-doctor: ok"
