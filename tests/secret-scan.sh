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

WIN=0; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; esac   # NTFS cannot hold a name with a quote, a tab or a newline, and Git Bash has no symlinks
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
if [[ "$WIN" == 0 ]]; then r="$(newrepo)"; put "$r" 'q"uote.txt' "k=$AWS";          expect_hit "$r" quote-name aws-access-key; else echo "secret-scan: skipped on Windows: a name with a quote, tab or newline"; fi
if [[ "$WIN" == 0 ]]; then r="$(newrepo)"; put "$r" "$(printf 'tab\tname.txt')" "k=$AWS"; expect_hit "$r" tab-name aws-access-key; else echo "secret-scan: skipped on Windows: a name with a quote, tab or newline"; fi
if [[ "$WIN" == 0 ]]; then r="$(newrepo)"; put "$r" "$(printf 'new\nline.txt')" "k=$AWS"; expect_hit "$r" newline-name aws-access-key; else echo "secret-scan: skipped on Windows: a name with a quote, tab or newline"; fi
[[ "$WIN" == 1 || "$OUT" != *$'\n'line.txt* || "$OUT" == *"?"* ]] || fail "secret-scan: a newline in a path reached the output raw: $OUT"
r="$(newrepo)"; printf 'hidden.txt -diff\n' > "$r/.gitattributes"; put "$r" hidden.txt "k=$AWS"; git -C "$r" add .gitattributes
expect_hit "$r" gitattributes-diff aws-access-key hidden.txt:1                       # a -diff attribute cannot hide the lines
r="$(newrepo)"; { printf 'k=%s\0binary tail\n' "$AWS"; } > "$r/blob.dat"; git -C "$r" add blob.dat
expect_hit "$r" binary aws-access-key blob.dat:1                                     # a NUL does not make the file unreadable
r="$(newrepo)"; put "$r" plus.txt "++$AWS";              expect_hit "$r" plus-lines aws-access-key plus.txt:1
r="$(newrepo)"; put "$r" plus3.txt "++ $AWS";            expect_hit "$r" plus-plus-space aws-access-key plus3.txt:1
r="$(newrepo)"; { printf 'k=%s ' "$AWS"; head -c 200000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$r/long.txt"; git -C "$r" add long.txt
t0=$SECONDS; expect_hit "$r" long-line aws-access-key long.txt:1; (( SECONDS - t0 < 20 )) || fail "secret-scan: a 200 KB line took $((SECONDS - t0)) s"
r="$(newrepo)"; { awk 'BEGIN { for (i = 1; i <= 100000; i++) print "line " i }'; printf 'k=%s\n' "$AWS"; } > "$r/big.txt"; git -C "$r" add big.txt
t0=$SECONDS; expect_hit "$r" big-diff aws-access-key big.txt:100001; (( SECONDS - t0 < 20 )) || fail "secret-scan: a 100,000-line diff took $((SECONDS - t0)) s"
# (break-it) bytes that are not UTF-8 must neither stop the scan nor hide a later line; a NUL in an earlier line must not turn the rest into "binary"
r="$(newrepo)"; printf 'caf\xe9 \xff\xfe latin-1 text\n' > "$r/l1.txt"; git -C "$r" add l1.txt; expect_clean "$r" "a Latin-1 file with no secret blocks nothing"
r="$(newrepo)"; printf 'caf\xe9 \xff\xfe\nk=%s\n' "$AWS" > "$r/l1.txt"; git -C "$r" add l1.txt; expect_hit "$r" invalid-utf8 aws-access-key l1.txt:2
r="$(newrepo)"; printf 'a\0b\nk=%s\n' "$AWS" > "$r/nul.dat"; git -C "$r" add nul.dat; expect_hit "$r" nul-earlier-line aws-access-key nul.dat:2
# (break-it) a symlink that becomes a regular file is a type change: its new lines are additions
if [[ "$WIN" == 0 ]]; then
r="$(newrepo)"; ln -s /etc/hostname "$r/lnk"; git -C "$r" add lnk; git -C "$r" commit -qm lnk; rm "$r/lnk"; printf 'k=%s\n' "$AWS" > "$r/lnk"; git -C "$r" add lnk
expect_hit "$r" typechange aws-access-key lnk:1
else echo "secret-scan: skipped on Windows: a symlink type change"; fi
# (break-it) quoted keys (JSON, YAML), a secret deep in a long line or across a piece boundary, UTF-16 files (PowerShell redirection)
r="$(newrepo)"; put "$r" a.json '{"pass''word": "Zq8vN2mK9xLp4Rt7"}';             expect_hit "$r" json-key generic-secret a.json:1
r="$(newrepo)"; put "$r" b.yml 'db:
  "api_key": "Zq8vN2mK9xLp4Rt7"';                                                    expect_hit "$r" yaml-quoted-key generic-secret b.yml:2
r="$(newrepo)"; put "$r" c.toml '"pass''word" = "Zq8vN2mK9xLp4Rt7"';                expect_hit "$r" toml-quoted-key generic-secret c.toml:1
r="$(newrepo)"; { head -c 25000 /dev/zero | tr '\0' 'a'; printf ' k=%s\n' "$AWS"; } > "$r/min.js"; git -C "$r" add min.js; expect_hit "$r" deep-in-long-line aws-access-key min.js:1
r="$(newrepo)"; { head -c 19990 /dev/zero | tr '\0' 'a'; printf ' k=%s\n' "$AWS"; } > "$r/cut.js"; git -C "$r" add cut.js; expect_hit "$r" across-a-piece-boundary aws-access-key cut.js:1
r="$(newrepo)"; printf 'k=%s\n' "$AWS" | iconv -f UTF-8 -t UTF-16LE > "$r/u16le.txt"; git -C "$r" add u16le.txt; expect_hit "$r" utf16le aws-access-key u16le.txt:1
r="$(newrepo)"; printf 'k=%s\n' "$AWS" | iconv -f UTF-8 -t UTF-16BE > "$r/u16be.txt"; git -C "$r" add u16be.txt; expect_hit "$r" utf16be aws-access-key u16be.txt:1
# (break-it) a placeholder is judged on the VALUE: a key NAME or a $ inside a real value does not exempt it; a variable reference or <...> still does
r="$(newrepo)"; put "$r" a.cfg 'password_example = "Zq8vN2mK9xLp4Rt7"';             expect_hit "$r" key-name-example generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'api_key_dummy: "Zq8vN2mK9xLp4Rt7"';                 expect_hit "$r" key-name-dummy generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "Zq8vN2mK$9xLp4Rt7"';                  expect_hit "$r" dollar-in-value generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'u=postgres://u:Zq8vN2$mK9@h/db';                    expect_hit "$r" dollar-in-url-password url-credentials a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "$DB_PASSWORD_FROM_ENV"';              expect_clean "$r" "a variable reference"
r="$(newrepo)"; put "$r" a.cfg 'u=postgres://app:${DB_PASS_FROM_ENV}@h/db';         expect_clean "$r" "a variable reference in a URL"
# (break-it) many hits stay bounded: 4,000 lines that each hold a key
r="$(newrepo)"; awk -v k="$AWS" 'BEGIN { for (i = 1; i <= 4000; i++) print "k" i "=" k }' > "$r/many.txt"; git -C "$r" add many.txt
t0=$SECONDS; expect_hit "$r" many-hits aws-access-key many.txt:1; (( SECONDS - t0 < 15 )) || fail "secret-scan: 4,000 hits took $((SECONDS - t0)) s"
# (security review) 300 placeholder hits before a real secret must not hide it: the cap counts real hits only
r="$(newrepo)"; awk -v ph="AKIA$(rep X 16)" -v k="$AWS" 'BEGIN { for (i = 1; i <= 300; i++) print "p" i "=" ph; print "real=" k; for (i = 1; i <= 300; i++) print "q" i "=" ph }' > "$r/ph.txt"; git -C "$r" add ph.txt
t0=$SECONDS; expect_hit "$r" real-after-300-placeholders aws-access-key ph.txt:301; (( SECONDS - t0 < 15 )) || fail "secret-scan: 600 placeholder hits took $((SECONDS - t0)) s"
r="$(newrepo)"; awk -v ph="ghp_$(rep x 36)" -v k="$AWS" 'BEGIN { for (i = 1; i <= 30000; i++) print "k=" ph; print "real=" k }' > "$r/ph30k.txt"; git -C "$r" add ph30k.txt
t0=$SECONDS; expect_hit "$r" real-after-30k-placeholders aws-access-key ph30k.txt:30001; (( SECONDS - t0 < 30 )) || fail "secret-scan: 30,000 placeholder hits took $((SECONDS - t0)) s"
# (break-it 2) a placeholder is judged on the value: a word in the MIDDLE of a real secret does not exempt it; a placeholder start or end does
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "Tr0ub4dor-example-9Zq"';                    expect_hit "$r" example-in-the-middle generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "Pa55word-xxx-Realvalue"';                   expect_hit "$r" xxx-in-the-middle generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "your-database-password-1"';                  expect_clean "$r" "a value that starts your-"
r="$(newrepo)"; put "$r" a.cfg 'token = "abcdefghijklmnop-example"';                      expect_clean "$r" "a value that ends example"
r="$(newrepo)"; put "$r" a.cfg 'max_tokens: "1000000000000"';                             expect_clean "$r" "a number"
r="$(newrepo)"; put "$r" a.json '"integrity": "sha512-abcdefghijklmnopqrstuvwx", "token": "sha512-abcdefghijklmnopqrstuvwx"'; expect_clean "$r" "an npm integrity hash"
r="$(newrepo)"; put "$r" a.sh 'curl https://user:password@example.org/x';                  expect_clean "$r" "the literal word password in a URL"
r="$(newrepo)"; put "$r" a.sh 'http://host:8080@v2/x';                                     expect_clean "$r" "a port in a URL"
# (break-it 2) the diff does not depend on the repo's git config: dstPrefix, showRoot, replace refs, an uppercase scheme, context lines
r="$(newrepo)"; mkdir -p "$r/.claude"; put "$r" .claude/settings.local.json '{}'; git -C "$r" config diff.dstPrefix w-
expect_hit "$r" dstPrefix-config claude-local-settings .claude/settings.local.json
r="$(newrepo)"; git -C "$r" config diff.mnemonicPrefix true; put "$r" server.pem x; expect_hit "$r" mnemonicPrefix key-file server.pem
r="$(newrepo)"; put "$r" a.cfg 'u=HTTPS://admin:hunter22xx@host.com/x';                     expect_hit "$r" uppercase-scheme url-credentials a.cfg:1
r="$(newrepo)"; printf 'one\ntwo\n' > "$r/f.txt"; git -C "$r" add f.txt; git -C "$r" commit -qm f; printf 'one\nk=%s\n' "$AWS" > "$r/f.txt"; git -C "$r" add f.txt
rc=0; out="$(cd "$r" && GIT_DIFF_OPTS=-u9 bash "$SCAN" --staged 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "f.txt:2: aws-access-key"
r="$(mktemp -d "$W/r.XXXXXX")"; git init -q "$r"; printf 'k=%s\n' "$AWS" > "$r/root.txt"; git -C "$r" add root.txt; git -C "$r" commit -qm root; put "$r" b.txt b; git -C "$r" commit -qm second
git -C "$r" config log.showRoot false; rc=0; out="$(cd "$r" && bash "$SCAN" --range HEAD 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "root.txt:1: aws-access-key"   # the root commit of a first push
r="$(newrepo)"; b0="$(git -C "$r" rev-parse HEAD)"; put "$r" sec.txt "k=$AWS"; git -C "$r" commit -qm sec; sec="$(git -C "$r" rev-parse HEAD)"
clean="$(git -C "$r" commit-tree -p "$b0" -m clean "$b0^{tree}")"; git -C "$r" replace "$sec" "$clean"
rc=0; out="$(cd "$r" && bash "$SCAN" --range "$b0..$sec" 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "sec.txt:1: aws-access-key"   # a replace ref cannot hide the real commit
# (review) an external diff driver or a textconv filter cannot make the diff print nothing: the scan passes --no-ext-diff and --no-textconv
printf '#!/bin/sh\nexit 0\n' > "$W/quiet-diff"; chmod +x "$W/quiet-diff"
r="$(newrepo)"; put "$r" a.cfg "k=$AWS"; rc=0; out="$(cd "$r" && GIT_EXTERNAL_DIFF="$W/quiet-diff" bash "$SCAN" --staged 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "a.cfg:1: aws-access-key"
r="$(newrepo)"; printf '*.cfg diff=clean\n' > "$r/.gitattributes"; git -C "$r" add .gitattributes; git -C "$r" config diff.clean.textconv "echo clean"; put "$r" a.cfg "k=$AWS"
rc=0; out="$(cd "$r" && bash "$SCAN" --staged 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "a.cfg:1: aws-access-key"
# (review) a large findings list ends with its summary, not a SIGPIPE (rc 141) that the hook would call "could not run"
r="$(newrepo)"; awk -v a="$AWS" -v g="ghp_$(rep a 36)" -v o="sk-$(rep r 40)" -v k="AIza$(rep Q 35)" 'BEGIN { for (i = 1; i <= 400; i++) { print "a" i "=" a; print "b" i "=" g; print "c" i "=" o; print "d" i "=" k } }' > "$r/many4.txt"; git -C "$r" add many4.txt
for _ in 1 2 3; do staged "$r"; [[ "$RC" == 1 ]] || fail "secret-scan: a large findings list ended with rc $RC, not 1"; assert_contains "$OUT" "secret-scan: "; assert_contains "$OUT" "... and "; done
# (review) a value that starts with $ and a lowercase letter is a password, a capitalised variable reference is not; Bearer in capitals; more key files
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "$uperSecret99Zq"';                          expect_hit "$r" dollar-lowercase generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "${DB_PASSWORD_FROM_ENV}"';                  expect_clean "$r" "a braced variable reference"
r="$(newrepo)"; put "$r" a.sh "curl -H 'Authorization: BEARER $(rep Z 30)' https://x.test"; expect_hit "$r" bearer-capitals bearer-token a.sh:1
r="$(newrepo)"; put "$r" a.sh "curl -H 'Authorization: BEARER YOUR_TOKEN_GOES_HERE_1234' https://x.test"; expect_clean "$r" "a capitalised BEARER with a placeholder"
for p in id_ecdsa id_dsa keystore.p12 cert.pfx .netrc; do r="$(newrepo)"; put "$r" "$p" "x"; staged "$r"; [[ "$RC" == 1 ]] || fail "secret-scan: the path $p was not refused: $OUT"; done
# (sweep) git failing is exit 2 with nothing on stdout, never a clean pass
rc=0; out="$(cd "$(newrepo)" && bash "$SCAN" --range no-such-ref-anywhere 2>/dev/null)" || rc=$?; assert_eq 2 "$rc"; assert_eq "" "$out"
r="$(newrepo)"; put "$r" a.cfg "x"; head -c 64 /dev/urandom > "$W/bad-index"
rc=0; out="$(cd "$r" && GIT_INDEX_FILE="$W/bad-index" bash "$SCAN" --staged 2>/dev/null)" || rc=$?; assert_eq 2 "$rc"; assert_eq "" "$out"
# (sweep) the key rules are case-sensitive (lowercase look-alikes pass); the free-text placeholder words are anchored; a variable reference is a WHOLE one
r="$(newrepo)"; put "$r" a.cfg "k = akia""abcdefghijklmnop"; expect_clean "$r" "a lowercase look-alike of an AWS key"
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "password-Hunter22xyz9"';          expect_hit "$r" starts-with-the-word-password generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "Real-Secret-$DB_PASS"';          expect_hit "$r" ends-with-a-var-ref generic-secret a.cfg:1
r="$(newrepo)"; put "$r" a.cfg 'pass''word = "$DB_PASS-realsecret9"';          expect_hit "$r" starts-with-a-var-ref generic-secret a.cfg:1
# (sweep) at most 50 findings are listed: exactly 50 has no "more" line, 51 has one
r="$(newrepo)"; awk -v a="$AWS" 'BEGIN { for (i = 1; i <= 50; i++) print "k" i "=" a }' > "$r/f50.txt"; git -C "$r" add f50.txt; staged "$r"; [[ "$RC" == 1 && "$OUT" != *"... and"* ]] || fail "secret-scan: 50 findings must list all 50: $OUT"
r="$(newrepo)"; awk -v a="$AWS" 'BEGIN { for (i = 1; i <= 51; i++) print "k" i "=" a }' > "$r/f51.txt"; git -C "$r" add f51.txt; staged "$r"; assert_contains "$OUT" "... and 1 more"
# (sweep) nothing is left behind in the temp dir
mkdir -p "$W/tmpchk"; r="$(newrepo)"; put "$r" a.cfg "k = $AWS"; (cd "$r" && TMPDIR="$W/tmpchk" bash "$SCAN" --staged >/dev/null 2>&1) || true
[[ -z "$(ls -A "$W/tmpchk")" ]] || fail "secret-scan: the scan left a temp dir behind: $(ls "$W/tmpchk")"
# (sweep) usage text
out="$(bash "$SCAN" 2>&1 || true)"; assert_contains "$out" "usage: secret-scan.sh --staged | --range"
# a rename of a clean file into a secret path is refused; a plain rename of a clean file passes
r="$(newrepo)"; put "$r" plain.txt "hello"; git -C "$r" commit -qm p; git -C "$r" mv plain.txt .env; staged "$r"; [[ "$RC" == 1 ]] || fail "secret-scan: a rename to .env passed: $OUT"
r="$(newrepo)"; put "$r" plain.txt "hello"; git -C "$r" commit -qm p; git -C "$r" mv plain.txt other.txt; expect_clean "$r" "a plain rename"
# (break-it) a grep that fails must never read as a clean scan: exit 2, naming the rule
mkdir -p "$W/shim"; printf '#!/bin/sh\nexit 2\n' > "$W/shim/grep"; chmod +x "$W/shim/grep"
r="$(newrepo)"; put "$r" a.cfg "k = $AWS"; rc=0; out="$(cd "$r" && PATH="$W/shim:$PATH" bash "$SCAN" --staged 2>&1)" || rc=$?
assert_eq 2 "$rc"; assert_contains "$out" "secret-scan: grep failed (exit 2) on rule"
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
# (break-it) a secret that only an evil merge adds (in neither parent) is in the pushed range
r="$(newrepo)"; git -C "$r" checkout -q -b side; put "$r" m.txt x; git -C "$r" commit -qm side; git -C "$r" checkout -q main; put "$r" n.txt y; git -C "$r" commit -qm mainc
base="$(git -C "$r" rev-parse HEAD)"; git -C "$r" merge --no-commit --no-ff side >/dev/null 2>&1; put "$r" evil.cfg "k=$AWS"; git -C "$r" commit -qm merge
rc=0; out="$(cd "$r" && bash "$SCAN" --range "$base..HEAD" 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "evil.cfg:1: aws-access-key"
r="$(newrepo)"; base="$(git -C "$r" rev-parse HEAD)"; put "$r" .env "x=1"; git -C "$r" commit -qm env
rc=0; out="$(cd "$r" && bash "$SCAN" --range "$base..HEAD" 2>&1)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" ".env: env-file"

# ── the pre-commit hook: refuses the commit, --no-verify goes through ──
# shellcheck source=tools/hooks-lib.sh
source "$ROOT/tools/hooks-lib.sh"
r="$(newrepo)"; mkdir -p "$r/tools" "$r/scripts"; cp "$SCAN" "$r/tools/secret-scan.sh"; cp "$ROOT/scripts/pre-commit-hook-template.sh" "$r/scripts/"   # the repo is its own canon root
# shellcheck disable=SC2034  # SKILLS_ROOT is read by _init_git_precommit
( SKILLS_ROOT="$r"; _init_git_precommit "$r" >/dev/null )
[[ -x "$r/.git/hooks/pre-commit" ]] || fail "secret-scan: the canon pre-commit hook was not installed"
put "$r" a.cfg "k = $AWS"
rc=0; out="$(cd "$r" && git commit -qm bad 2>&1)" || rc=$?
[[ "$rc" != 0 ]] || fail "secret-scan: the pre-commit hook let a commit with a secret through"
assert_contains "$out" "a.cfg:1: aws-access-key"; assert_contains "$out" "BLOCKED"; assert_contains "$out" "--no-verify"
[[ -z "$(git -C "$r" log --format=%s | grep '^bad$' || true)" ]] || fail "secret-scan: the refused commit exists"
rc=0; out="$(cd "$r" && git commit -qm forced --no-verify 2>&1)" || rc=$?; assert_eq 0 "$rc"            # the deliberate override
put "$r" b.txt "clean"; rc=0; out="$(cd "$r" && git commit -qm ok 2>&1)" || rc=$?; assert_eq 0 "$rc"      # a clean commit is not slowed or refused
mv "$r/tools/secret-scan.sh" "$r/tools/secret-scan.off"; put "$r" d.txt "clean three"; rc=0; out="$(cd "$r" && git commit -qm noscan 2>&1)" || rc=$?
[[ "$rc" != 0 ]] || fail "secret-scan: the pre-commit hook let a commit through with the scanner missing"; assert_contains "$out" "the secret scan is missing"; assert_contains "$out" "--no-verify"
mv "$r/tools/secret-scan.off" "$r/tools/secret-scan.sh"; git -C "$r" reset -q; git -C "$r" checkout -q -- . 2>/dev/null || true
put "$r" c.txt "clean again"; rc=0; out="$(cd "$r" && PATH="$W/shim:$PATH" git commit -qm broken-scan 2>&1)" || rc=$?   # a scan that cannot run blocks, and says so
[[ "$rc" != 0 ]] || fail "secret-scan: the pre-commit hook let a commit through when the scan could not run"
assert_contains "$out" "the secret scan could not run"; git -C "$r" reset -q; git -C "$r" checkout -q -- . 2>/dev/null || true

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
printf 'k = %s\n' "$AWS" > leak.cfg; git add leak.cfg; git commit -qm leak
printf 'clean\n' > leak.cfg; git commit -qam "remove it"                                               # gone from the tip, still in the pushed history
for remote in origin public; do
  rc=0; out="$(git push "$remote" main 2>&1)" || rc=$?
  [[ "$rc" != 0 ]] || fail "secret-scan: a push of a secret reached $remote"
  assert_contains "$out" "leak.cfg:1: aws-access-key"; assert_contains "$out" "refused the push to $remote (t-5988)"
  assert_eq "$(git rev-parse origin/main)" "$(at "$remote" main)"
done
# (break-it) a commit another remote already holds is still new to THIS remote: a new branch to the second remote is scanned too
git remote add other "$W/other.git" 2>/dev/null || true; git init -q --bare "$W/other.git"
rc=0; out="$(git push --no-verify other main:refs/heads/viaother 2>&1)" || rc=$?; assert_eq 0 "$rc"; git fetch -q other
rc=0; out="$(git push public main:refs/heads/viaother 2>&1)" || rc=$?; [[ "$rc" != 0 ]] || fail "secret-scan: a secret already on remote 'other' reached 'public' on a new branch"
assert_contains "$out" "leak.cfg:1: aws-access-key"
rc=0; out="$(git push "$W/public.git" main:refs/heads/viaurl 2>&1)" || rc=$?; [[ "$rc" != 0 ]] || fail "secret-scan: a new branch pushed by URL skipped a commit another remote holds"   # the URL of 'public'
git push -q --no-verify other :refs/heads/viaother 2>/dev/null || true
mv tools/secret-scan.sh tools/secret-scan.off; rc=0; out="$(git push origin main:refs/heads/noscan 2>&1)" || rc=$?; mv tools/secret-scan.off tools/secret-scan.sh
[[ "$rc" != 0 ]] || fail "secret-scan: the pre-push hook let a push through with the scanner missing"; assert_contains "$out" "tools/secret-scan.sh is missing"
rc=0; out="$(git push origin main:refs/heads/side 2>&1)" || rc=$?; [[ "$rc" != 0 ]] || fail "secret-scan: a new branch with a secret reached origin"
assert_eq none "$(at origin side)"
rc=0; out="$(git push --no-verify origin main 2>&1)" || rc=$?; assert_eq 0 "$rc"                               # the deliberate override
git reset -q --hard HEAD~2; printf 'fine\n' > ok.txt; git add ok.txt; git commit -qm fine
rc=0; out="$(git push public main 2>&1)" || rc=$?; assert_eq 0 "$rc"
rc=0; out="$(git push origin main:refs/heads/fresh 2>&1)" || rc=$?; assert_eq 0 "$rc"; [[ "$(at origin fresh)" != none ]] || fail "secret-scan: a clean new branch did not arrive"   # a new branch scans the commits no remote has
rc=0; out="$(git push origin :refs/heads/fresh 2>&1)" || rc=$?; assert_eq 0 "$rc"; assert_eq none "$(at origin fresh)"   # a deletion pushes nothing and goes through

echo "secret-scan: ok (every rule rejects and names file:line without the value, path rules in any case, placeholders and the marker pass, hostile names and sizes, -diff and binary files, --range history, the pre-commit hook, the pre-push hook for any remote)"
