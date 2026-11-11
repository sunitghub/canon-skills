#!/usr/bin/env bash
# t-5988: tools/secret-scan.sh refuses a commit or a push that adds a credential. Protects the pre-commit hook every canon project installs
# (scripts/pre-commit-hook-template.sh), canon's pre-push hook for any remote (scripts/install-hooks.sh) and so `git commit` / `git push` / `tkt push-main`.
# Every fake secret below is built from two pieces so this file does not trip the scan it tests when canon pushes it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

SCAN="$ROOT/tools/secret-scan.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main

rep() { local i s=""; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }
AWS="AKIA""ABCDEFGHIJKLMNOP"
GH="ghp_""$(rep a 36)"
GHPAT="github_pat_""$(rep q 30)"
SLACK="xox""b-1234567890-abcdefghij"
ANT="sk-""ant-api03-abcdefghijklmnopqrstuv"
OAI="sk-""$(rep r 40)"
GOOG="AIza""$(rep Q 35)"
PK="-----BEGIN ""RSA PRIVATE KEY-----"
URL="postgres://app:s3cretPassw0rd""@db.internal/x"
JWT="eyJ""hbGciOiJIUzI1NiJ9.eyJ""zdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk"
BEARER="Authorization: Bearer ""$(rep Z 30)"
GEN="pass""word = \"hunter2hunter2hunter2\""

newrepo() { local d; d="$(mktemp -d "$W/r.XXXXXX")"; git init -q "$d"; git -C "$d" commit -q --allow-empty -m init; printf '%s' "$d"; }   # a fresh dir each call: this runs in a subshell, so no counter
put() { # put <repo> <path> <content>: write and stage (-f: a global ignore must not hide the file)
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; git -C "$1" add -f -- "$2"
}
staged() { local rc=0; OUT="$(cd "$1" && bash "$SCAN" --staged 2>&1)" || rc=$?; RC=$rc; }
expect_clean() { staged "$1"; [[ "$RC" == 0 && -z "$OUT" ]] || fail "secret-scan: $2: expected a clean pass, got rc=$RC: $OUT"; }
expect_hit() { # expect_hit <repo> <label> <rule> [file:line]
  staged "$1"; [[ "$RC" == 1 ]] || fail "secret-scan: $2: expected rc 1, got $RC: $OUT"
  assert_contains "$OUT" ": $3"; [[ -z "${4:-}" ]] || assert_contains "$OUT" "$4: $3"
  [[ "$OUT" != *"hunter2hunter2"* && "$OUT" != *"$AWS"* && "$OUT" != *"$GH"* && "$OUT" != *"s3cretPassw0rd"* ]] || fail "secret-scan: $2: the secret value was printed: $OUT"
}

# ── one reject per content rule, naming file:line and never the value ──
r="$(newrepo)"; put "$r" a.cfg "k = $AWS";      expect_hit "$r" aws aws-access-key a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "t: $GH";        expect_hit "$r" github github-token a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "t=$GHPAT";      expect_hit "$r" github-pat github-token a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "s=$SLACK";      expect_hit "$r" slack slack-token a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "k=$ANT";        expect_hit "$r" anthropic anthropic-key a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "k=$OAI";        expect_hit "$r" openai openai-key a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "k=$GOOG";       expect_hit "$r" google google-api-key a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "$PK";           expect_hit "$r" private-key private-key a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "u=$URL";        expect_hit "$r" url url-credentials a.cfg:1
r="$(newrepo)"; put "$r" a.cfg "j=$JWT";        expect_hit "$r" jwt jwt a.cfg:1
r="$(newrepo)"; put "$r" a.sh "curl -H '$BEARER' https://x.test"; expect_hit "$r" bearer bearer-token a.sh:1
r="$(newrepo)"; put "$r" a.cfg "$GEN";          expect_hit "$r" generic generic-secret a.cfg:1
# the line number is the added line's own, not the file's first
r="$(newrepo)"; printf 'a\nb\nc\n' > "$r/f.txt"; git -C "$r" add f.txt; git -C "$r" commit -qm f; printf 'a\nb\nc\nk=%s\n' "$AWS" > "$r/f.txt"; git -C "$r" add f.txt
expect_hit "$r" lineno aws-access-key f.txt:4

# ── paths: a file that is a secret by its name, in any letter case ──
for p in .env .env.local .ENV config/.env.production .claude/settings.local.json x/.claude/settings.local.json cert.pem Server.PEM id_rsa keys/id_ed25519; do
  r="$(newrepo)"; put "$r" "$p" "x=1"; staged "$r"; [[ "$RC" == 1 ]] || fail "secret-scan: the path $p was not refused: $OUT"
  assert_contains "$OUT" "$p: "
done
for p in .env.example .env.sample .env.template config/.env.dist notes.txt envfile; do
  r="$(newrepo)"; put "$r" "$p" "x=1"; expect_clean "$r" "path $p"
done

# ── what must pass ──
r="$(newrepo)"; put "$r" a.cfg "t: ghp_""$(rep x 36)";                                  expect_clean "$r" "placeholder xxxx"
r="$(newrepo)"; put "$r" a.cfg "token = \"<your-api-token-here>\"";                       expect_clean "$r" "placeholder <...>"
r="$(newrepo)"; put "$r" a.cfg "pass""word = \"\${DB_PASSWORD_VALUE}\"";                  expect_clean "$r" "placeholder \${...}"
r="$(newrepo)"; put "$r" a.cfg "api_key = \"YOUR_API_KEY_GOES_HERE\"";                    expect_clean "$r" "placeholder YOUR_"
r="$(newrepo)"; put "$r" a.cfg "k = AKIA""IOSFODNN7EXAMPLE";                             expect_clean "$r" "the AWS documentation key"
r="$(newrepo)"; put "$r" a.cfg "k = $AWS # canon:allow-secret";                           expect_clean "$r" "the allow marker"
r="$(newrepo)"; put "$r" a.cfg "just text, a task-force-assessment-with-a-long-hyphenated-name-here"; expect_clean "$r" "sk- inside a word"
# removed and unchanged lines are not additions
r="$(newrepo)"; printf 'k=%s\n' "$AWS" > "$r/old.cfg"; git -C "$r" add -f old.cfg; git -C "$r" commit -qm old
printf 'other\n' > "$r/old.cfg"; git -C "$r" add old.cfg; expect_clean "$r" "a removed secret"
printf 'k=%s\nmore\n' "$AWS" > "$r/old.cfg"; git -C "$r" checkout -q -- old.cfg; printf 'k=%s\nadded plain line\n' "$AWS" > "$r/old.cfg"; git -C "$r" add old.cfg
expect_clean "$r" "an unchanged secret next to an added plain line"
r="$(newrepo)"; staged "$r"; [[ "$RC" == 0 && -z "$OUT" ]] || fail "secret-scan: an empty staged change must pass: $OUT"

# ── hostile input ──
r="$(newrepo)"; put "$r" "dé f.txt" "k=$AWS";            expect_hit "$r" nonascii-name aws-access-key
r="$(newrepo)"; put "$r" "a b.txt" "k=$AWS";             expect_hit "$r" space-name aws-access-key "a b.txt:1"
r="$(newrepo)"; put "$r" "-lead.txt" "k=$AWS";           expect_hit "$r" dash-name aws-access-key
r="$(newrepo)"; put "$r" 'q"uote.txt' "k=$AWS";          expect_hit "$r" quote-name aws-access-key
r="$(newrepo)"; put "$r" "$(printf 'tab\tname.txt')" "k=$AWS"; expect_hit "$r" tab-name aws-access-key
r="$(newrepo)"; put "$r" "$(printf 'new\nline.txt')" "k=$AWS"; expect_hit "$r" newline-name aws-access-key
[[ "$OUT" != *$'\n'line.txt* || "$OUT" == *"?"* ]] || fail "secret-scan: a newline in a path reached the output raw: $OUT"
r="$(newrepo)"; printf 'hidden.txt -diff\n' > "$r/.gitattributes"; put "$r" hidden.txt "k=$AWS"; git -C "$r" add .gitattributes
expect_hit "$r" gitattributes-diff aws-access-key hidden.txt:1                       # a -diff attribute cannot hide the lines
r="$(newrepo)"; { printf 'k=%s\0binary tail\n' "$AWS"; } > "$r/blob.dat"; git -C "$r" add blob.dat
expect_hit "$r" binary aws-access-key blob.dat:1                                     # a NUL does not make the file unreadable
r="$(newrepo)"; put "$r" plus.txt "++$AWS";              expect_hit "$r" plus-lines aws-access-key plus.txt:1
r="$(newrepo)"; put "$r" plus3.txt "++ $AWS";            expect_hit "$r" plus-plus-space aws-access-key plus3.txt:1
r="$(newrepo)"; { printf 'k=%s ' "$AWS"; head -c 200000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$r/long.txt"; git -C "$r" add long.txt
t0=$SECONDS; expect_hit "$r" long-line aws-access-key long.txt:1; (( SECONDS - t0 < 20 )) || fail "secret-scan: a 200 KB line took $((SECONDS - t0)) s"
r="$(newrepo)"; { for i in $(seq 1 100000); do echo "line $i"; done; printf 'k=%s\n' "$AWS"; } > "$r/big.txt"; git -C "$r" add big.txt
t0=$SECONDS; expect_hit "$r" big-diff aws-access-key big.txt:100001; (( SECONDS - t0 < 20 )) || fail "secret-scan: a 100,000-line diff took $((SECONDS - t0)) s"
# a rename of a clean file into a secret path is refused; a plain rename of a clean file passes
r="$(newrepo)"; put "$r" plain.txt "hello"; git -C "$r" commit -qm p; git -C "$r" mv plain.txt .env; staged "$r"; [[ "$RC" == 1 ]] || fail "secret-scan: a rename to .env passed: $OUT"
r="$(newrepo)"; put "$r" plain.txt "hello"; git -C "$r" commit -qm p; git -C "$r" mv plain.txt other.txt; expect_clean "$r" "a plain rename"
# usage, and not a repository
rc=0; out="$(bash "$SCAN" 2>&1)" || rc=$?; assert_eq 2 "$rc"
rc=0; out="$(bash "$SCAN" --bogus 2>&1)" || rc=$?; assert_eq 2 "$rc"
rc=0; out="$(bash "$SCAN" --staged extra 2>&1)" || rc=$?; assert_eq 2 "$rc"
rc=0; out="$(bash "$SCAN" --range 2>&1)" || rc=$?; assert_eq 2 "$rc"
rc=0; out="$(cd "$W" && bash "$SCAN" --staged 2>&1)" || rc=$?; assert_eq 2 "$rc"; assert_contains "$out" "not inside a git repository"

# ── --range: every commit in it, including a secret added and removed again inside the range ──
r="$(newrepo)"; base="$(git -C "$r" rev-parse HEAD)"
put "$r" a.cfg "k = $AWS"; git -C "$r" commit -qm add; bad="$(git -C "$r" rev-parse --short=7 HEAD)"
put "$r" a.cfg "k = removed"; git -C "$r" commit -qm remove
rc=0; out="$(cd "$r" && bash "$SCAN" --range "$base..HEAD" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "$bad:a.cfg:1: aws-access-key"                 # the net diff is clean; the history is not
rc=0; out="$(cd "$r" && bash "$SCAN" --range "HEAD..HEAD" 2>&1)" || rc=$?; assert_eq 0 "$rc"
rc=0; out="$(cd "$r" && bash "$SCAN" --range "HEAD" --not --remotes 2>&1)" || rc=$?; assert_eq 1 "$rc"   # a new branch: the commits no remote has
git -C "$r" remote add o "$W/none.git" 2>/dev/null; git -C "$r" update-ref refs/remotes/o/main HEAD
rc=0; out="$(cd "$r" && bash "$SCAN" --range "HEAD" --not --remotes 2>&1)" || rc=$?; assert_eq 0 "$rc"  # once a remote has them
r="$(newrepo)"; base="$(git -C "$r" rev-parse HEAD)"; put "$r" .env "x=1"; git -C "$r" commit -qm env
rc=0; out="$(cd "$r" && bash "$SCAN" --range "$base..HEAD" 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" ".env: env-file"

# ── the pre-commit hook: refuses the commit, --no-verify goes through ──
# shellcheck source=tools/hooks-lib.sh
source "$ROOT/tools/hooks-lib.sh"
r="$(newrepo)"; mkdir -p "$r/tools" "$r/scripts"; cp "$SCAN" "$r/tools/secret-scan.sh"; cp "$ROOT/scripts/pre-commit-hook-template.sh" "$r/scripts/"   # the repo is its own canon root
( SKILLS_ROOT="$r"; _init_git_precommit "$r" >/dev/null )
[[ -x "$r/.git/hooks/pre-commit" ]] || fail "secret-scan: the canon pre-commit hook was not installed"
put "$r" a.cfg "k = $AWS"
rc=0; out="$(cd "$r" && git commit -qm bad 2>&1)" || rc=$?
[[ "$rc" != 0 ]] || fail "secret-scan: the pre-commit hook let a commit with a secret through"
assert_contains "$out" "a.cfg:1: aws-access-key"; assert_contains "$out" "BLOCKED"
[[ -z "$(git -C "$r" log --format=%s | grep '^bad$' || true)" ]] || fail "secret-scan: the refused commit exists"
rc=0; out="$(cd "$r" && git commit -qm forced --no-verify 2>&1)" || rc=$?; assert_eq 0 "$rc"            # the deliberate override
put "$r" b.txt "clean"; rc=0; out="$(cd "$r" && git commit -qm ok 2>&1)" || rc=$?; assert_eq 0 "$rc"      # a clean commit is not slowed or refused

# ── canon's pre-push hook: any remote, a new branch, the release check still runs for a mirror ──
P="$W/p"; for x in origin public; do git init -q --bare "$W/$x.git"; done
git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
git remote add public "$W/public.git"; git config --add canon.mirror public
mkdir -p tools scripts .git/hooks
cp "$SCAN" tools/secret-scan.sh; cp "$ROOT/scripts/install-hooks.sh" scripts/install-hooks.sh
printf '#!/usr/bin/env bash\nexec bash "%s/tools/tkt" "$@"\n' "$ROOT" > tools/tkt
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/check-binaries-released.sh
printf '.tickets/\n' > .gitignore; echo OK > tools/cockpit-daemon.sha256
git add -A; git commit -qm base; git push -q origin main 2>/dev/null; git push -q public main 2>/dev/null
bash scripts/install-hooks.sh >/dev/null; rm -f .git/hooks/post-commit
at() { git --git-dir="$W/$1.git" rev-parse -q --verify "refs/heads/$2" || echo none; }
printf 'k = %s\n' "$AWS" > leak.cfg; git add leak.cfg; git commit -qm leak; LEAK="$(git rev-parse HEAD)"
printf 'clean\n' > leak.cfg; git commit -qam "remove it"                                               # gone from the tip, still in the pushed history
for remote in origin public; do
  rc=0; out="$(git push "$remote" main 2>&1)" || rc=$?
  [[ "$rc" != 0 ]] || fail "secret-scan: a push of a secret reached $remote"
  assert_contains "$out" "leak.cfg:1: aws-access-key"; assert_contains "$out" "refused the push to $remote (t-5988)"
  assert_eq "$(git rev-parse origin/main)" "$(at "$remote" main)"
done
rc=0; out="$(git push origin main:refs/heads/side 2>&1)" || rc=$?; [[ "$rc" != 0 ]] || fail "secret-scan: a new branch with a secret reached origin"
assert_eq none "$(at origin side)"
rc=0; out="$(git push --no-verify origin main 2>&1)" || rc=$?; assert_eq 0 "$rc"                               # the deliberate override
git reset -q --hard HEAD~2; printf 'fine\n' > ok.txt; git add ok.txt; git commit -qm fine
rc=0; out="$(git push public main 2>&1)" || rc=$?; assert_eq 0 "$rc"
rc=0; out="$(git push origin main:refs/heads/fresh 2>&1)" || rc=$?; assert_eq 0 "$rc"; [[ "$(at origin fresh)" != none ]] || fail "secret-scan: a clean new branch did not arrive"   # a new branch scans the commits no remote has
rc=0; out="$(git push origin :refs/heads/fresh 2>&1)" || rc=$?; assert_eq 0 "$rc"; assert_eq none "$(at origin fresh)"   # a deletion pushes nothing and goes through

echo "secret-scan: ok (every rule rejects and names file:line without the value, path rules in any case, placeholders and the marker pass, hostile names and sizes, -diff and binary files, --range history, the pre-commit hook, the pre-push hook for any remote)"
