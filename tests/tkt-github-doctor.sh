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
                   exists) echo '{"name":"x"}' ;;
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
check() { field "$1" "'|'.join([c['status'], c['title']] + ([c['fix'].get('cmd',''), c['fix'].get('url','')] if 'fix' in c else ['nofix'])) if (c := next(c for c in d['checks'] if c['id'] == '$2')) else ''"; }
before="$(git status --porcelain; git for-each-ref)"

# Not installed; no origin; no commit yet, so no scripts/test.sh.
out="$(PATH="$NOGH_PATH" "$TKT" github-doctor --json)"
assert_eq "bad|GitHub CLI (gh) is not installed||https://github.com/cli/cli" "$(check "$out" gh)"
# t-9955: no origin at all offers to create the repo, private, named after the folder; the detail keeps the remote-add way.
# t-11e6: --source names the project's absolute folder, quoted, so the copied command works from any terminal (not just from inside the project)
proot="$project"   # as the project is spelled (macOS /var, not /private/var)
assert_eq "bad|No GitHub repository for this project|gh repo create \"$(basename "$project")\" --private --source=\"$proot\" --remote=origin --push|" "$(check "$out" origin)"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "publishing the folder $proot."
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "no git remote named origin"
# ...a folder with a space in its name works, and macOS/Linux keep chmod +x in the no-test-command text
sp="$W/my project"; mkdir -p "$sp"; git -C "$sp" init -q; sproot="$(cd "$sp" && pwd)"
out2="$(cd "$sp" && PATH="$NOGH_PATH" "$TKT" github-doctor --json)"
assert_eq "bad|No GitHub repository for this project|gh repo create \"my project\" --private --source=\"$sproot\" --remote=origin --push|" "$(check "$out2" origin)"
assert_contains "$(field "$out" "d['checks'][2]['detail']")" "make it executable (chmod +x)"
# t-10ac: gh says whether octo/<folder> exists. Missing: replace the old origin with a new private repo in one pasted command. Unknown (a network
# error): the safe set-url, said as could not be checked. Exists: set-url. With no origin at all: an existing repo is connected, a missing one created.
no="$W/noorigin"; mkdir -p "$no"; git -C "$no" init -q; noroot="$(cd "$no" && pwd)"
oe="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=exists "$TKT" github-doctor --json)"
assert_eq "bad|No GitHub repository for this project|git remote add origin https://github.com/octo/noorigin.git|" "$(check "$oe" origin)"
assert_contains "$(field "$oe" "d['checks'][1]['detail']")" "already exists on GitHub"
om="$(cd "$no" && PATH="$W/bin:$PATH" STUB_REPO=missing "$TKT" github-doctor --json)"
assert_eq "bad|No GitHub repository for this project|gh repo create \"noorigin\" --private --source=\"$noroot\" --remote=origin --push|" "$(check "$om" origin)"
# t-10ac: with a non-GitHub origin the pasted set-url never carries a folder name GitHub cannot take as a repo name (a space, a quote, a
# dollar sign): the repo part stays the <repo> placeholder, the signed-in login still fills the owner
for odd in "my project" 'dollar$name'; do
  od="$W/$odd"; mkdir -p "$od"; git -C "$od" init -q; git -C "$od" remote add origin https://gitlab.com/acme/app.git
  oo="$(cd "$od" && PATH="$W/bin:$PATH" "$TKT" github-doctor --json)"
  assert_eq "bad|No GitHub repository for this project|git remote set-url origin https://github.com/octo/<repo>.git|" "$(check "$oo" origin)"
done
# a folder name with a character that is unsafe in a pasted command gets no command at all, and says why
for unsafe in 'bad$name' 'bad`id`' 'bad"q' 'bad\slash' 'bad!x' $'bad\nline'; do
  bad="$W/$unsafe"; mkdir -p "$bad"; git -C "$bad" init -q
  outb="$(cd "$bad" && PATH="$NOGH_PATH" "$TKT" github-doctor --json)"
  assert_eq "bad|No GitHub repository for this project|nofix" "$(check "$outb" origin)"
  assert_contains "$(field "$outb" "d['checks'][1]['detail']")" "not safe in a command you paste"
done
# t-11e6, Windows (a stubbed uname and cygpath): the folder in Windows form, the new-terminal hint, and the git index way to make it executable
mkdir -p "$W/win"
printf '#!/usr/bin/env bash\necho MINGW64_NT-10.0-22631\n' > "$W/win/uname"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "C:\\Users\\me\\My Project"\n' > "$W/win/cygpath"; chmod +x "$W/win/uname" "$W/win/cygpath"
outw="$(PATH="$W/win:$NOGH_PATH" "$TKT" github-doctor --json)"
assert_eq "bad|No GitHub repository for this project|gh repo create \"$(basename "$project")\" --private --source=\"C:\\Users\\me\\My Project\" --remote=origin --push|" "$(check "$outw" origin)"
assert_contains "$(field "$outw" "d['checks'][1]['detail']")" "terminal opened after Git was installed"
assert_contains "$(field "$outw" "d['checks'][2]['detail']")" "git update-index --chmod=+x scripts/test.sh; Git Bash runs it without the bit"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "Already have a repo on GitHub? Run git remote add origin https://github.com/<owner>/$(basename "$project").git"
assert_eq "warn|No test command (optional)|nofix" "$(check "$out" tests)"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
assert_contains "$(field "$out" "d['checks'][2]['detail']")" "merges on the gates alone"
assert_contains "$(field "$out" "d['checks'][2]['detail']")" 'run tkt merge-pr <id> --test "<your test command>"'   # t-9641: both ways to add one

# Installed but signed out; a non-GitHub origin.
git remote add origin https://gitlab.com/acme/app.git
out="$(PATH="$W/bin:$PATH" STUB_GH=out doctor)"
assert_eq "bad|gh is installed, but not signed in|gh auth login|" "$(check "$out" gh)"
assert_eq "bad|No GitHub repository for this project|git remote set-url origin https://github.com/<owner>/$(basename "$project").git|" "$(check "$out" origin)"   # signed out: the owner is a placeholder
# t-10ac: signed in, origin not on GitHub: the command is set-url (add would fail) with the signed-in login and the folder's name filled in
out="$(PATH="$W/bin:$PATH" doctor)"
assert_eq "bad|No GitHub repository for this project|git remote set-url origin https://github.com/octo/$(basename "$project").git|" "$(check "$out" origin)"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "git remote remove origin"
out="$(PATH="$W/bin:$PATH" STUB_REPO=missing doctor)"
assert_eq "bad|No GitHub repository for this project|git remote remove origin && gh repo create \"$(basename "$project")\" --private --source=\"$project\" --remote=origin --push|" "$(check "$out" origin)"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "octo/$(basename "$project") is not on GitHub yet"
out="$(PATH="$W/bin:$PATH" STUB_REPO=error doctor)"
assert_eq "bad|No GitHub repository for this project|git remote set-url origin https://github.com/octo/$(basename "$project").git|" "$(check "$out" origin)"
assert_contains "$(field "$out" "d['checks'][1]['detail']")" "could not be checked"
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
assert_contains "$plain" "bad   GitHub CLI (gh) is not installed — Every GitHub step runs gh as you."
rc=0; "$TKT" github-doctor --jsn >/dev/null 2>&1 || rc=$?; assert_eq 1 "$rc"
echo "tkt-github-doctor: ok"
