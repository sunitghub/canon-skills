#!/usr/bin/env bash
# tkt github-doctor (t-90a3): the readiness checks Factory › GitHub (t-9641) and the worktree picker's GitHub row (t-24b1) render.
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
  "repo view")   case "${STUB_REPO:-exists}" in
                   exists) echo "${STUB_EMPTY:-false}" ;;   # --json isEmpty --jq .isEmpty
                   missing) echo "GraphQL: Could not resolve to a Repository with the name '$3'. (repository)" >&2; exit 1 ;;
                   *) echo "dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
                 esac ;;
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
check() { field "$1" "'|'.join([c['status'], c['title']] + ([c['fix'].get('cmd',''), c['fix'].get('url','')] if 'fix' in c else ['nofix'])) if (c := next((c for c in d['checks'] if c['id'] == '$2'), None)) else ''"; }
before="$(git status --porcelain; git for-each-ref)"

# t-d287: step 2 is three ordered sub-steps (repo on GitHub, origin points at it, first push), each with at most one command, and
# no command is chained: Windows PowerShell 5.1 has no &&. Every state below reads the repo/origin/push checks; every fix is checked.
nochain() {   # no pasted command contains && ; | or a backtick/dollar: each pastes into PowerShell 5.1, 7 and Git Bash
  local cmds; cmds="$(field "$1" "'\n'.join(c['fix']['cmd'] for c in d['checks'] if c.get('fix',{}).get('cmd'))")"
  case "$cmds" in *'&&'*|*';'*|*'|'*|*'$'*|*'`'*) fail "a fix command is chained or unsafe: $cmds" ;; esac
}
grp() { field "$1" "','.join((c['id']+':'+c.get('group','-')+(':optional' if c.get('optional') else '')) for c in d['checks'])"; }

# Not installed; no origin; no commit yet, so no scripts/test.sh. gh cannot be asked, so the repo is not checked and the owner is a placeholder.
out="$(PATH="$NOGH_PATH" "$TKT" github-doctor --json)"
assert_eq "bad|GitHub CLI (gh) is not installed||https://github.com/cli/cli" "$(check "$out" gh)"
assert_eq "bad|Could not check GitHub for the repository|nofix" "$(check "$out" repo)"
assert_eq "bad|No git remote named origin|nofix" "$(check "$out" origin)"   # no signed-in owner: a pasted command would carry <owner>, so there is none
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='origin'][0]['detail']")" "Sign in first (step 1)"
assert_eq "gh:-,repo:repo-setup,origin:repo-setup,tests:-:optional" "$(grp "$out")"   # the order is the order to do them in; the test command is optional
case "$(field "$out" "[c for c in d['checks'] if c['id']=='origin'][0]['detail']")" in *"run from the project root"*) fail "a check with no command to paste says where to run it" ;; esac
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='tests'][0]['detail']")" "make it executable (chmod +x)"
nochain "$out"
# a folder name GitHub cannot take as a repo name, or unsafe in a command, never reaches a pasted command: the placeholder stays
for odd in "my project" 'dollar$name' 'bad`id`' 'bad"q' 'bad\slash' 'bad!x' $'bad\nline'; do
  od="$W/$odd"; mkdir -p "$od"; git -C "$od" init -q
  oo="$(cd "$od" && PATH="$W/bin:$PATH" "$TKT" github-doctor --json)"
  assert_eq "bad|No git remote named origin|nofix" "$(check "$oo" origin)"   # a placeholder is not a command (<repo> is a redirection in bash)
  assert_eq "bad|This folder's name cannot be a GitHub repository name|nofix" "$(check "$oo" repo)"
  assert_contains "$(field "$oo" "[c for c in d['checks'] if c['id']=='repo'][0]['detail']")" "rename the folder"
  nochain "$oo"
  case "$(field "$oo" "'\n'.join(c['fix']['cmd'] for c in d['checks'] if c.get('fix',{}).get('cmd'))")" in *'<'*|*'>'*) fail "a placeholder reached a pasted command: $od" ;; esac
done
# an inherited GD_GROUP / GD_OPT must not mark checks (the board would count zero required checks)
lk="$(PATH="$W/bin:$PATH" GD_GROUP=x GD_OPT=1 doctor)"
assert_eq "gh:-,repo:repo-setup,origin:repo-setup,tests:-:optional" "$(grp "$lk")"
# Signed in, no origin at all: 2.1 creates the repo when GitHub has none (the repo only: no --source, no --push), 2.2 adds origin; an existing repo
# needs only 2.2; an existing EMPTY repo with origin set needs the first push (2.3).
no="$W/noorigin"; mkdir -p "$no"; git -C "$no" init -q
om="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=missing "$TKT" github-doctor --json)"
assert_eq "bad|No repository on GitHub yet|gh repo create \"noorigin\" --private|" "$(check "$om" repo)"
assert_eq "bad|No git remote named origin|git remote add origin https://github.com/octo/noorigin.git|" "$(check "$om" origin)"
assert_eq "gh:-,repo:repo-setup,origin:repo-setup,tests:-:optional" "$(grp "$om")"
nochain "$om"
oe="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=exists "$TKT" github-doctor --json)"
assert_eq "ok|Repository found on GitHub|nofix" "$(check "$oe" repo)"
assert_eq "bad|No git remote named origin|git remote add origin https://github.com/octo/noorigin.git|" "$(check "$oe" origin)"
# a check that hands over a command to paste says where it runs (user, 2026-11-06)
assert_contains "$(field "$oe" "[c for c in d['checks'] if c['id']=='origin'][0]['detail']")" "The command below needs to be run from the project root."
git -C "$no" remote add origin https://github.com/octo/noorigin.git
op="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=exists STUB_EMPTY=true "$TKT" github-doctor --json)"
assert_eq "ok|origin points at it|nofix" "$(check "$op" origin)"
assert_eq "bad|First push|git push -u origin HEAD|" "$(check "$op" push)"
assert_eq "gh:-,repo:repo-setup,origin:repo-setup,push:repo-setup,tests:-:optional" "$(grp "$op")"
nochain "$op"
on="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=exists STUB_EMPTY=false "$TKT" github-doctor --json)"
assert_eq "" "$(check "$on" push)"   # a populated repo has no push sub-step
git -C "$no" remote remove origin
oq="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=exists STUB_EMPTY=true "$TKT" github-doctor --json)"
assert_eq "" "$(check "$oq" push)"   # an empty repo with NO origin: pushing is 2.2's job first, never offered against nothing
git -C "$no" remote add origin https://gitlab.com/acme/app.git
oq="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=exists STUB_EMPTY=true "$TKT" github-doctor --json)"
assert_eq "" "$(check "$oq" push)"   # ...and with an origin that is not this repo: never push to the wrong remote
git -C "$no" remote set-url origin https://github.com/octo/noorigin.git
ou="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=error "$TKT" github-doctor --json)"
assert_eq "bad|Could not check GitHub for the repository|nofix" "$(check "$ou" repo)"
assert_eq "" "$(check "$ou" push)"
assert_contains "$(field "$ou" "[c for c in d['checks'] if c['id']=='repo'][0]['detail']")" "could not be asked just now"   # a network error says so; it is not "sign in"
# Signed in; a non-GitHub origin: set-url overwrites it (no remove step), pointing at the signed-in login and the folder's name.
git remote add origin https://gitlab.com/acme/app.git
out="$(PATH="$W/bin:$PATH" STUB_GH=out doctor)"
assert_eq "bad|gh is installed, but not signed in|gh auth login|" "$(check "$out" gh)"
assert_eq "bad|origin is not a GitHub repository|nofix" "$(check "$out" origin)"   # signed out: the owner is a placeholder, so no command
out="$(PATH="$W/bin:$PATH" doctor)"
assert_eq "bad|origin is not a GitHub repository|git remote set-url origin https://github.com/octo/$(basename "$project").git|" "$(check "$out" origin)"
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='origin'][0]['detail']")" "https://gitlab.com/acme/app.git"
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='origin'][0]['detail']")" "The command below needs to be run from the project root."
nochain "$out"
out="$(PATH="$W/bin:$PATH" STUB_REPO=missing doctor)"
assert_eq "bad|No repository on GitHub yet|gh repo create \"$(basename "$project")\" --private|" "$(check "$out" repo)"
assert_eq "bad|origin is not a GitHub repository|git remote set-url origin https://github.com/octo/$(basename "$project").git|" "$(check "$out" origin)"
out="$(PATH="$W/bin:$PATH" STUB_REPO=error doctor)"
assert_eq "bad|Could not check GitHub for the repository|nofix" "$(check "$out" repo)"
# t-11e6, Windows (a stubbed uname): the git commands say to use a terminal opened after Git was installed
mkdir -p "$W/win"; printf '#!/usr/bin/env bash\necho MINGW64_NT-10.0-22631\n' > "$W/win/uname"; chmod +x "$W/win/uname"
outw="$(PATH="$W/win:$W/bin:$PATH" doctor)"
assert_contains "$(field "$outw" "[c for c in d['checks'] if c['id']=='origin'][0]['detail']")" "terminal opened after Git was installed"
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='tests'][0]['detail']")" "make it executable (chmod +x)"
assert_contains "$(field "$outw" "[c for c in d['checks'] if c['id']=='tests'][0]['detail']")" "git update-index --chmod=+x scripts/test.sh; Git Bash runs it without the bit"
assert_eq "warn|No test command (optional)|nofix" "$(check "$out" tests)"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='tests'][0]['detail']")" "merges on the gates alone"
assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='tests'][0]['detail']")" 'run tkt merge-pr <id> --test "<your test command>"'   # t-9641: both ways to add one

# Signed in; origin names a GitHub repo that is not there yet (set-url done before the repo exists): 2.1 says so, 2.2 is satisfied.
git remote set-url origin git@github.com:acme/app.git
out="$(PATH="$W/bin:$PATH" STUB_REPO=missing doctor)"   # acme is not the signed-in login (octo): ask about octo/<folder> instead, and offer its create command
assert_eq "bad|No repository on GitHub yet|gh repo create \"$(basename "$project")\" --private|" "$(check "$out" repo)"
assert_eq "bad|origin points elsewhere|git remote set-url origin https://github.com/octo/$(basename "$project").git|" "$(check "$out" origin)"
git remote set-url origin git@github.com:octo/app.git
out="$(PATH="$W/bin:$PATH" STUB_REPO=missing doctor)"   # the signed-in login's own name: create exactly that repo, origin already points at it
assert_eq "bad|No repository on GitHub yet|gh repo create \"app\" --private|" "$(check "$out" repo)"
assert_eq "ok|origin points at it|nofix" "$(check "$out" origin)"
nochain "$out"
git remote set-url origin git@github.com:acme/app.git
mkdir -p scripts; printf '#!/bin/sh\n' > scripts/test.sh; chmod +x scripts/test.sh
git add scripts/test.sh; git -c user.name=t -c user.email=t@t commit -q -m tests
before="$(git status --porcelain; git for-each-ref)"; : > "$STUB_LOG"
out="$(PATH="$W/bin:$PATH" doctor)"
assert_eq "ok|Signed in to GitHub|nofix" "$(check "$out" gh)"; assert_eq "Signed in as octo." "$(field "$out" "d['checks'][0]['detail']")"
assert_eq "ok|Repository found, and private|nofix" "$(check "$out" repo)"; assert_eq "Issues go to acme/app (origin, private)." "$(field "$out" "[c for c in d['checks'] if c['id']=='repo'][0]['detail']")"
assert_eq "ok|origin points at it|nofix" "$(check "$out" origin)"
assert_eq "" "$(check "$out" push)"
assert_eq "ok|Check & merge test command: scripts/test.sh|nofix" "$(check "$out" tests)"
# Read-only: only these gh reads ran, and the repo is as it was.
assert_eq "auth status|api user --jq .login|repo view acme/app --json isEmpty --jq .isEmpty|api repos/acme/app --jq .visibility" "$(paste -sd'|' "$STUB_LOG")"
assert_eq "$before" "$(git status --porcelain; git for-each-ref)"
# The plain form: one line per check, no fix line for a check without one, and no JSON after it.
plain="$(PATH="$W/bin:$PATH" "$TKT" github-doctor)"
assert_eq "ok    2.1 Repository found, and private — Issues go to acme/app (origin, private)." "$(sed -n 2p <<< "$plain")"
[[ "$plain" != *"fix:"* && "$plain" != *'{"checks"'* ]] || fail "plain output of an all-ok doctor: $plain"
# A gh that cannot name the account, and one that cannot read the repo (curl gives no answer either): still exit 0.
out="$(PATH="$W/bin:$PATH" STUB_GH=nouser STUB_VIS=none doctor)"
assert_eq "ok|Signed in to GitHub|nofix" "$(check "$out" gh)"; assert_eq "" "$(field "$out" "d['checks'][0]['detail']")"
assert_eq "warn|Repository found; visibility unknown|nofix" "$(check "$out" repo)"

# Public origin: a warning naming --public. A scripts/test.sh that is not executable is no test command.
chmod -x scripts/test.sh; git -c user.name=t -c user.email=t@t commit -q -am 'not executable'
out="$(PATH="$W/bin:$PATH" STUB_VIS=public doctor)"
assert_eq "warn|Repository found, and public|nofix" "$(check "$out" repo)"; assert_contains "$(field "$out" "[c for c in d['checks'] if c['id']=='repo'][0]['detail']")" "Send needs --public"
assert_eq "warn|No test command (optional)|nofix" "$(check "$out" tests)"

# t-9955: the cloud recipe is this project's `tkt cloud-env --json`, from tools/cloud-env.sh: no go.mod here, so the base only.
assert_eq "$("$TKT" cloud-env --json)" "$(field "$out" "json.dumps(d['cloud'], separators=(',', ':'))")"
assert_eq "False|4|False" "$(field "$out" "'|'.join(map(str, [d['cloud']['go'], len(d['cloud']['domains']), 'GOV=' in d['cloud']['setup_script']]))")"
# An install with no tools/cloud-env.sh gives empty values, never an error.
mkdir -p "$W/canon/tools"; cp "$CANON/tools/tkt" "$CANON/tools/ticket-root.sh" "$CANON/tools/frontmatter-lib.sh" "$CANON/tools/platform-lib.sh" "$W/canon/tools/"
out="$(PATH="$W/bin:$PATH" "$W/canon/tools/tkt" github-doctor --json 2>"$W/err")"
assert_eq "[]|" "$(field "$out" "str(d['cloud']['domains']) + '|' + d['cloud']['setup_script']")"
[[ ! -s "$W/err" ]] || fail "a tools/ copy without cloud-env.sh printed errors: $(cat "$W/err")"

# Exits 0 when checks fail, and the plain form shows each fix.
rc=0; plain="$(PATH="$NOGH_PATH" "$TKT" github-doctor)" || rc=$?
assert_eq 0 "$rc"; assert_contains "$plain" "fix: https://github.com/cli/cli"
assert_contains "$plain" "bad   1. GitHub CLI (gh) is not installed — Every GitHub step runs gh as you."
rc=0; "$TKT" github-doctor --jsn >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"
echo "tkt-github-doctor: ok"
