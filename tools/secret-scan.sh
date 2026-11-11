#!/usr/bin/env bash
# secret-scan.sh — refuse a commit or a push that adds a credential (t-5988). One owner of the rules, no dependency beyond git, grep and awk.
#   secret-scan.sh --staged                      the lines and paths the staged change adds (the pre-commit hook)
#   secret-scan.sh --range <rev-list args...>    every commit in the range (git log -p), so a secret added and removed again inside it is still found
#                                                (the pre-push hook: A..B, or `<sha> --not --remotes` for a new branch)
# Exit 0 clean, 1 findings, 2 usage or a git failure. Findings go to stderr as `[<sha>:]path:line: rule`: the value is never printed.
# Passes: a line carrying `canon:allow-secret`, and a match that is a placeholder (xxxx, example, your_..., <...>, ${...}, changeme, redacted).
# Overrides, on purpose: `git commit --no-verify` / `git push --no-verify`. There is no environment switch: an agent could set one.
# Rules are patterns for known shapes, not entropy: a secret of an unlisted shape passes. The table below is the one place to extend.
# Input is hostile: file names with spaces, quotes or a newline (git quotes them), a long line (read in overlapping 20 KB pieces), at most 200 hits a rule, a binary file or a .gitattributes `-diff`
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
url-credentials	[a-z][a-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]{3,}@
jwt	eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}
bearer-token	Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}	i
generic-secret	(password|passwd|secret|token|api[_-]?key|apikey)[A-Za-z0-9_-]*["']?[[:space:]]*[:=][[:space:]]*["'][^"'[:space:]]{12,}["']	i
TABLE
# A placeholder is judged on the VALUE (not the key name or the whole match): xxxx, example, your_..., placeholder, dummy, changeme, redacted, ****,
# <...>, or a variable reference at its start (${X}, $X). A real password that merely contains a $ is not one.
PLACEHOLDER='x{4,}|example|your[_-]|placeholder|dummy|changeme|redacted|\*{4,}|^<.*>$|^\$[{A-Za-z_]'
value_of() { # <rule> <match>: the part of a match that is the secret itself (sed: bash 3.2 mishandles quotes inside ${...})
  case "$1" in
    generic-secret) printf '%s' "$2" | sed -e 's/^[^:=]*[:=][[:space:]]*//' -e "s/^[\"']//" -e "s/[\"']\$//" ;;
    bearer-token) printf '%s' "$2" | sed -e 's/^[Bb]earer[[:space:]]*//' ;;
    url-credentials) printf '%s' "$2" | sed -e 's|^[^:]*://||' -e 's|^[^:]*:||' -e 's|@$||' ;;
    *) printf '%s' "$2" ;;
  esac
}

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "secret-scan: not inside a git repository" >&2; exit 2; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
US=$'\x1f'

case "$mode" in
  --staged) git -C "$repo" -c core.quotepath=false diff --cached --no-color --text --no-textconv --no-ext-diff -U0 --diff-filter=d > "$work/diff" || exit 2 ;;
  --range)  git -C "$repo" -c core.quotepath=false log -p -m --no-color --text --no-textconv --no-ext-diff -U0 --diff-filter=d --format='@@COMMIT %H' "$@" > "$work/diff" || exit 2 ;;
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
  case "$base" in *.pem|id_rsa|id_ed25519) say "$c" "$p" "" "key-file" ;; esac
done < "$work/P"

# content rules, over the added lines
while IFS="$(printf '\t')" read -r name re flags; do
  [[ -n "$name" ]] || continue
  opts="-noE"; [[ "$flags" != *i* ]] || opts="-noiE"
  grc=0; grep -a -m 200 $opts -e "$re" "$work/T" > "$work/hits" || grc=$?
  [[ "$grc" -le 1 ]] || { echo "secret-scan: grep failed (exit $grc) on rule $name; nothing was scanned for it" >&2; exit 2; }   # never read a failed scan as clean
  while IFS= read -r hit; do
    idx="${hit%%:*}"; m="${hit#*:}"
    v="$(value_of "$name" "$m")"
    if grep -qiE -e "$PLACEHOLDER" <<<"$v"; then continue; fi
    rec="$(sed -n "${idx}p" "$work/R")"
    IFS="$US" read -r c p l _ <<<"$rec"
    say "$c" "$p" "$l" "$name"
  done < "$work/hits"
done <<<"$RULES"

n="$(awk '!seen[$0]++' "$findings" | wc -l | tr -d ' ')"
if [[ "$n" -eq 0 ]]; then exit 0; fi
awk '!seen[$0]++' "$findings" | head -50 >&2
[[ "$n" -le 50 ]] || echo "... and $((n - 50)) more" >&2
echo "secret-scan: $n finding(s). Remove the secret and rotate it; put canon:allow-secret on a line that is not one; or --no-verify to override on purpose." >&2
exit 1
