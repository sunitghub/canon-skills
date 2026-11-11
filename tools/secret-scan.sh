#!/usr/bin/env bash
# secret-scan.sh — refuse a commit or a push that adds a credential (t-5988). One owner of the rules, no dependency beyond git, grep and awk.
#   secret-scan.sh --staged                      the lines and paths the staged change adds (the pre-commit hook)
#   secret-scan.sh --range <rev-list args...>    every commit in the range (git log -p), so a secret added and removed again inside it is still found
#                                                (the pre-push hook: A..B, or `<sha> --not --remotes` for a new branch)
# Exit 0 clean, 1 findings, 2 usage or a git failure. Findings go to stderr as `[<sha>:]path:line: rule`: the value is never printed.
# Passes: a line carrying `canon:allow-secret`, and a match that is a placeholder (xxxx, example, your_..., <...>, ${...}, changeme, redacted).
# Overrides, on purpose: `git commit --no-verify` / `git push --no-verify`. There is no environment switch: an agent could set one.
# Rules are patterns for known shapes, not entropy: a secret of an unlisted shape passes. The table below is the one place to extend.
# Input is hostile: file names with spaces, quotes or a newline (git quotes them), a long line (read in overlapping 20 KB pieces), at most 200 real hits a rule (placeholders do not count), a binary file or a .gitattributes `-diff`
# (--text, --no-textconv, --no-ext-diff: an attribute cannot hide the lines or pick a program that rewrites them), paths in any letter case (.ENV, Server.PEM).
set -euo pipefail
export LC_ALL=C   # bytes, not characters: an invalid UTF-8 byte must neither stop awk nor make grep call the file binary

usage() { echo "usage: secret-scan.sh --staged | --range <rev-list args...>" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
mode="$1"; shift
case "$mode" in
  --staged) [[ $# -eq 0 ]] || usage ;;
  --range) [[ $# -ge 1 ]] || usage ;;
  *) usage ;;
esac

# name <TAB> grep -E pattern <TAB> flags (i = ignore case)
IFS= read -r -d '' RULES <<'TABLE' || true   # not $(cat <<...): bash 3.2 miscounts the quotes of a heredoc inside a command substitution
aws-access-key	(AKIA|ASIA)[0-9A-Z]{16}
github-token	gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}
slack-token	xox[baprs]-[A-Za-z0-9-]{10,}
anthropic-key	sk-ant-[A-Za-z0-9_-]{20,}
openai-key	(^|[^A-Za-z0-9_-])sk-(proj-)?[A-Za-z0-9_-]{32,}
google-api-key	AIza[0-9A-Za-z_-]{35}
private-key	-----BEGIN ([A-Z]+ )*PRIVATE KEY( BLOCK)?-----
url-credentials	[a-z][a-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]{3,}@	i
jwt	eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}
bearer-token	Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}	i
generic-secret	(password|passwd|secret|token|api[_-]?key|apikey)[A-Za-z0-9_-]*["']?[[:space:]]*[:=][[:space:]]*["'][^"'[:space:]]{12,}["']	i
TABLE
# A placeholder is judged on the VALUE, never the key name. Key-shaped secrets (AWS, GitHub, ...): xxxx, example or **** anywhere in the match.
# A password, token or Bearer value or a URL password (free text, so a real one may contain such a word): only when it STARTS or ENDS as a placeholder
# (xxxx, your_..., changeme, example, placeholder, dummy, redacted, ****, <...>) or is a whole environment-variable reference in capitals (${X}, $X), is only digits (a port, a count), a bare word like
# "password", or an npm integrity hash (sha512-...). A real secret that merely contains "example" in the middle is still refused.
PH_KEY='x{4,}|example|\*{4,}'
PH_FREE='^(x{4,}|your[_-]|changeme|example|placeholder|dummy|redacted|\*{4,}|<.*>$|sha(256|384|512)-)|(example|x{4,}|\*{4,})$|^[0-9]+$|^(password|passwd|pass|secret|token|user|username|apikey|api_key)$'
dq='"'; sq="'"
value_of() { # <rule> <match>: the part of a match that is the secret itself. Builtins only: this runs once per hit, and a file can have 100,000 of them
  local v="$2"
  case "$1" in
    generic-secret)
      v="${v#*[:=]}"; while [[ "$v" == [[:space:]]* ]]; do v="${v#?}"; done
      case "$v" in "$dq"*|"$sq"*) v="${v#?}" ;; esac
      case "$v" in *"$dq"|*"$sq") v="${v%?}" ;; esac ;;
    bearer-token) v="${v#[Bb][Ee][Aa][Rr][Ee][Rr]}"; while [[ "$v" == [[:space:]]* ]]; do v="${v#?}"; done ;;
    url-credentials) v="${v#*://}"; v="${v#*:}"; v="${v%@}" ;;
  esac
  VALUE="$v"
}
is_placeholder() { # <rule> <value>
  local re="$PH_KEY" r=1
  case "$1" in generic-secret|bearer-token|url-credentials) re="$PH_FREE"
    # a whole variable reference, in capitals as an environment variable is (${DB_PASS}, $DB_PASS); case-sensitive, so $uperSecret99 is a password
    [[ "$2" =~ ^\$([A-Z_][A-Z0-9_]*|\{[^}]*\})$ ]] && return 0 ;;
  esac
  shopt -s nocasematch; [[ "$2" =~ $re ]] && r=0; shopt -u nocasematch; return "$r"
}

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "secret-scan: not inside a git repository" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXX")"; trap 'rm -rf "$work"' EXIT
US=$'\x1f'

# Flags that make the diff the same whatever the repo's or the user's git config says: prefixes (diff.dstPrefix, noprefix, mnemonicPrefix), the
# root commit (log.showRoot), replace refs (git replace), quoting (core.quotepath), the lines themselves (--text, no textconv, no external driver).
GITF=(--no-replace-objects -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c log.showRoot=true)
DIFFF=(--no-color --text --no-textconv --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -U0 --diff-filter=d)
case "$mode" in
  --staged) git -C "$repo" "${GITF[@]}" diff --cached "${DIFFF[@]}" > "$work/diff" || exit 2 ;;
  --range)  git -C "$repo" "${GITF[@]}" log -p -m --root "${DIFFF[@]}" --format='@@COMMIT %H' "$@" > "$work/diff" || exit 2 ;;
esac

tr -d '\000' < "$work/diff" > "$work/diff.clean"   # a NUL would end a line early in some awks and make grep call the whole file binary
mv "$work/diff.clean" "$work/diff"
# One pass over the diff: R holds `sha US path US line US text` for every added line, T just the text (same order), P `sha US path` for every
# added or renamed-to path. `+++ ` is a header only before the first hunk of a file (an added line "++ x" looks the same), a line over 20 KB is cut.
awk -v R="$work/R" -v T="$work/T" -v P="$work/P" -v US="$US" '
  /^@@COMMIT / { commit = substr($2, 1, 7); file = ""; inhdr = 0; next }
  /^diff --git / { inhdr = 1; file = ""; next }
  inhdr && /^rename to / { p = substr($0, 11); gsub(/^"|"$/, "", p); print commit US p > P; next }
  inhdr && /^\+\+\+ / {
    p = substr($0, 5); sub(/\t.*$/, "", p)
    if (p == "/dev/null") { file = ""; next }
    gsub(/^"|"$/, "", p); sub(/^b\//, "", p); file = p
    print commit US file > P; next
  }
  /^@@ / {
    inhdr = 0; n = $3; sub(/^\+/, "", n); sub(/,.*/, "", n); ln = n + 0; next
  }
  !inhdr && /^ / { ln++; next }   # a context line (GIT_DIFF_OPTS can ask for some): it has a line number too
  !inhdr && /^\+/ {
    if (file != "") {
      line = substr($0, 2)
      if (index(line, "canon:allow-secret") == 0) {
        # a long line (minified JS, one-line JSON) is read in 20 KB pieces that overlap by 200 bytes, so a secret anywhere in it, or across a cut, is seen
        len = length(line); i = 1
        do {
          piece = (len > 20000) ? substr(line, i, 20000) : line
          print commit US file US ln US piece > R
          print piece > T
          i += 19800
        } while (i <= len)
      }
    }
    ln++
  }
' "$work/diff"
: >> "$work/R"; : >> "$work/T"; : >> "$work/P"

findings="$work/findings"; : > "$findings"
say() { # <commit> <path> <line-or-empty> <rule>: one finding; the path is cut and made printable, the value never appears
  local c="$1" p="$2" l="$3" r="$4" at
  p="$(printf '%s' "${p:0:200}" | tr -c '[:print:]' '?')"
  at="${c:+$c:}$p"; [[ -z "$l" ]] || at="$at:$l"
  printf '%s: %s\n' "$at" "$r" >> "$findings"
}

# path rules, from the added paths
while IFS="$US" read -r c p; do
  [[ -n "$p" ]] || continue
  lp="$(printf '%s' "$p" | tr 'A-Z' 'a-z')"   # macOS and Windows: .ENV and Server.PEM are the same files
  base="${lp##*/}"
  case "$base" in .env.example|.env.sample|.env.template|.env.dist) ;; .env|.env.*) say "$c" "$p" "" "env-file" ;; esac
  case "$lp" in .claude/settings.local.json|*/.claude/settings.local.json) say "$c" "$p" "" "claude-local-settings (saved approvals can hold a password)" ;; esac
  case "$base" in *.pem|*.p12|*.pfx|id_rsa|id_ecdsa|id_dsa|id_ed25519|.netrc) say "$c" "$p" "" "key-file" ;; esac
done < "$work/P"

# content rules, over the added lines
while IFS="$(printf '\t')" read -r name re flags; do
  [[ -n "$name" ]] || continue
  opts="-noE"; [[ "$flags" != *i* ]] || opts="-noiE"
  grc=0; grep -a $opts -e "$re" "$work/T" > "$work/hits" || grc=$?
  [[ "$grc" -le 1 ]] || { echo "secret-scan: grep failed (exit $grc) on rule $name; nothing was scanned for it" >&2; exit 2; }   # never read a failed scan as clean
  # every hit is judged (a cap applied before the placeholder filter would let 200 placeholders hide a real secret); the work is bounded after it:
  # a hit that is a placeholder costs builtins only, and a rule stops at 200 real hits (only the first 50 are ever printed)
  real=0
  while IFS= read -r hit; do
    idx="${hit%%:*}"; m="${hit#*:}"
    value_of "$name" "$m"
    if is_placeholder "$name" "$VALUE"; then continue; fi
    rec="$(sed -n "${idx}p" "$work/R")"
    IFS="$US" read -r c p l _ <<<"$rec"
    say "$c" "$p" "$l" "$name"
    real=$((real + 1)); [[ "$real" -lt 200 ]] || break
  done < "$work/hits"
done <<<"$RULES"

awk '!seen[$0]++' "$findings" > "$findings.u"   # a file, not a pipe into head: under pipefail a closed pipe would kill the script (141) before its summary
n="$(wc -l < "$findings.u" | tr -d ' ')"
if [[ "$n" -eq 0 ]]; then exit 0; fi
head -50 "$findings.u" >&2
[[ "$n" -le 50 ]] || echo "... and $((n - 50)) more" >&2
echo "secret-scan: $n finding(s). Remove the secret and rotate it; put canon:allow-secret on a line that is not one; or --no-verify to override on purpose." >&2
exit 1
