#!/usr/bin/env bash
# dead-code-scan — t-271a: the deterministic half of skills/dead-code-cleanup (steps 1-3). A model following
# the skill's prose sampled candidates instead of checking each one and missed most of them, so the scan is code.
# Bash + git + POSIX awk only, so it runs in Git Bash on Windows (no Python: tests/no-python-windows-paths.sh).
#
# Usage: dead-code-scan.sh [<pathspec>...]   (default: the whole repo)
# Output, tab-separated, one row per candidate, grouped DEAD, TESTONLY, OVEREXP:
#   <class>  <file>:<line>  <symbol>  <lang>  <entry|->  <refs>
# then "# scanned: <langs>", "# skipped: <.ext>=<files> ..." (or "none") and "# checked: <n> declarations".
# Exit 2 outside a git repo. The judgment calls (dynamic dispatch, entry points a package.json or build file
# names) stay with the skill.

set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "dead-code-scan: not a git repository — refusing to scan" >&2; exit 2; }
cd "$root"

list="$(mktemp "${TMPDIR:-/tmp}/dead-code-scan.XXXXXX")"
trap 'rm -f "$list"' EXIT

# Tracked text files (git grep -I skips binaries) minus vendored/built dirs and docs. Docs are never read:
# a mention in prose, a ticket, a changelog or an earlier report keeps no code alive.
# core.quotePath=false: a quoted non-ASCII path cannot be opened, and its calls would go unseen.
git -c core.quotePath=false grep -I -l -e '' -- "$@" 2>/dev/null \
  | grep -vE '(^|/)(node_modules|\.git|dist|build|__pycache__|vendor)/' \
  | grep -vE '\.(md|txt)$|(^|/)CHANGELOG[^/]*$|^\.tickets/|^\.reports/' > "$list" || true

awk -v list="$list" '
function lang_of(f, first,   b) {
  b = f; sub(/.*\//, "", b)
  if (b ~ /\.(js|ts|jsx|tsx)$/) return "js"
  if (b ~ /\.py$/) return "py"
  if (b ~ /\.go$/) return "go"
  if (b ~ /\.(sh|bash)$/) return "sh"
  if (b !~ /\./ && first ~ /^#!.*[\/ ](ba)?sh([ \t]|$)/) return "sh"
  return ""
}
function is_test(f,   b) {
  if (f ~ /(^|\/)(tests|test|__tests__)\//) return 1
  b = f; sub(/.*\//, "", b)
  return (b ~ /\.(test|spec)\./ || b ~ /_test\.go$/ || b ~ /^test_.*\.py$/ || b ~ /_test\.py$/)
}
function is_entry(f, lang, first, isexp,   b) {
  # Only callable from outside: a Bash function (own script or a `source`r) and an unexported Go func (own
  # package) have every caller within reach of grep, so neither takes the entry-point downgrade.
  if (lang == "sh" || (lang == "go" && !isexp)) return 0
  b = f; sub(/.*\//, "", b)
  if (b ~ /^index\./ || b == "__init__.py" || b == "main.go" || b ~ /^cli\./) return 1
  return (first ~ /^#!/)
}
# Name declared on this line, or "" — the skill step 1 patterns, top level only.
function decl(lang, s,   t) {
  if (lang == "js") {
    if (!match(s, /^export[ \t]+(async[ \t]+)?(function\*?|const|class)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) return ""
    t = substr(s, 1, RLENGTH); sub(/.*[ \t*]/, "", t); return t
  }
  if (lang == "py") {
    if (!match(s, /^(async[ \t]+)?(def|class)[ \t]+[A-Za-z][A-Za-z0-9_]*/)) return ""
    t = substr(s, 1, RLENGTH); sub(/.*[ \t]/, "", t); return t
  }
  if (lang == "go") {
    if (!match(s, /^func[ \t]+[A-Za-z][A-Za-z0-9_]*[ \t]*[[(]/)) return ""
    t = substr(s, 1, RLENGTH); sub(/^func[ \t]+/, "", t); sub(/[ \t]*[[(]$/, "", t)
    if (t == "main" || t == "init" || t ~ /^(Test|Benchmark|Example)([A-Z_]|$)/) return ""
    return t
  }
  if (lang == "sh") {
    if (match(s, /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = substr(s, 1, RLENGTH); sub(/^function[ \t]+/, "", t); return t }
    if (match(s, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) { t = substr(s, 1, RLENGTH); sub(/[ \t]*\(\)$/, "", t); return t }
  }
  return ""
}
BEGIN {
  nf = 0
  while ((getline f < list) > 0) files[++nf] = f
  close(list)
  nskip = split(".cs .rs .java .kt .rb .php .swift .c .h .cpp .scala .lua .ps1", skipext, " ")

  # Pass 1: declarations.
  nc = 0
  for (i = 1; i <= nf; i++) {
    f = files[i]; first = ""; ln = 0; lang = ""
    lower = tolower(f)
    for (k = 1; k <= nskip; k++) if (substr(lower, length(lower) - length(skipext[k]) + 1) == skipext[k]) skipped[skipext[k]]++
    while ((getline s < f) > 0) {
      sub(/\r$/, "", s)   # CRLF checkouts (Git for Windows autocrlf) would hide the shebang
      if (++ln == 1) { first = s; lang = lang_of(f, first); if (lang == "") break; scanned[lang] = 1 }
      n = decl(lang, s)
      if (n == "") continue
      nc++; cname[nc] = n; cfile[nc] = f; cline[nc] = ln; clang[nc] = lang
      cexp[nc] = (lang == "js" || (lang == "go" && n ~ /^[A-Z]/))
      centry[nc] = is_entry(f, lang, first, cexp[nc])
      byname[n] = byname[n] " " nc
    }
    close(f)
  }

  # Pass 2: code references — every identifier on a non-comment line, minus the declaration line itself.
  for (i = 1; i <= nf; i++) {
    f = files[i]; ln = 0; t = is_test(f)
    while ((getline s < f) > 0) {
      ln++; sub(/\r$/, "", s)
      if (s ~ /^[ \t]*(#|\/\/|\/\*|\*)/) continue
      gsub(/[^A-Za-z0-9_$]+/, " ", s)
      m = split(s, tok, " ")
      for (j = 1; j <= m; j++) {
        if (!(tok[j] in byname)) continue
        nids = split(byname[tok[j]], ids, " ")
        for (q = 1; q <= nids; q++) {
          c = ids[q]
          if (f == cfile[c] && ln == cline[c]) continue
          if (t) { tref[c]++; if (!index(" " tfiles[c] " ", " " f " ")) tfiles[c] = tfiles[c] (tfiles[c] == "" ? "" : " ") f }
          else if (f == cfile[c]) own[c]++
          else other[c]++
        }
      }
    }
    close(f)
  }

  for (c = 1; c <= nc; c++) {
    cls = ""; refs = "-"
    if (!tref[c] && !own[c] && !other[c]) cls = "DEAD"
    else if (is_test(cfile[c])) continue          # a test helper used by tests is live
    else if (!own[c] && !other[c]) { cls = "TESTONLY"; refs = tfiles[c] }
    else if (cexp[c] && !other[c] && !tref[c]) { cls = "OVEREXP"; refs = cfile[c] }
    else continue
    row[cls] = row[cls] cls "\t" cfile[c] ":" cline[c] "\t" cname[c] "\t" clang[c] "\t" (centry[c] ? "entry" : "-") "\t" refs "\n"
  }
  printf "%s%s%s", row["DEAD"], row["TESTONLY"], row["OVEREXP"]

  out = ""; split("js py go sh", order, " ")
  for (k = 1; k <= 4; k++) if (order[k] in scanned) out = out (out == "" ? "" : ",") order[k]
  print "# scanned: " (out == "" ? "none" : out)
  out = ""
  for (k = 1; k <= nskip; k++) if (skipped[skipext[k]]) out = out (out == "" ? "" : " ") skipext[k] "=" skipped[skipext[k]]
  print "# skipped: " (out == "" ? "none" : out)
  print "# checked: " nc " declarations"
}'
