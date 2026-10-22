#!/usr/bin/env bash
# check-vendored (t-93ff) — report on the third-party files the daemon vendors (tools/vendored.tsv): for each vendored
# package, the latest version on the npm registry and the OSV advisories that affect the VENDORED version.
# Report-only: it never edits a file, opens an issue or a PR, or commits. One implementation for a local run and the
# scheduled workflow (.github/workflows/vendored-updates.yml), so the two cannot disagree. See docs/ci-security.md.
#
# Usage: scripts/check-vendored.sh [--summary]   print the table; --summary also appends it to $GITHUB_STEP_SUMMARY
#        scripts/check-vendored.sh --sha <file>  print the SHA-256 for a manifest row (a path, or a name in web/vendor/)
#
# Exit: 0 when no advisory affects a vendored version (a newer version alone is information, not a failure);
#       1 when an advisory affects a vendored version; 2 when a lookup failed or answered something unreadable
#       (a failed lookup never reads as "no advisories"); 64 on bad usage.
#
# Needs bash and curl only (macOS, Linux, Git Bash). With jq on PATH it parses the answers with jq; without it, a
# grep/sed fallback: the registry's top-level "version" must be the one semver "version" value in the answer, and OSV's
# answer is split at each `"id":"` (OSV lists a vulnerability's id first), taking each chunk's first "severity" and
# "fixed" values. The fallback decides "affected or not" the same way (any id at all means affected); only the severity
# and fixed-in columns are best-effort. VENDORED_NO_JQ=1 forces the fallback.
# Test seams: VENDORED_CURL (a curl stand-in), VENDORED_MANIFEST (another manifest). Bash 3.2-safe.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${VENDORED_MANIFEST:-$ROOT/tools/vendored.tsv}"
VENDOR="$ROOT/tools/canon-go/internal/daemon/web/vendor"
CURL="${VENDORED_CURL:-curl}"
REGISTRY="https://registry.npmjs.org"
OSV="https://api.osv.dev/v1/query"
JQ=0; if [[ "${VENDORED_NO_JQ:-}" != 1 ]] && command -v jq >/dev/null 2>&1; then JQ=1; fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

usage() { sed -n 's/^# Usage: //p; s/^#        scripts/scripts/p' "$0" >&2; exit 64; }

SUMMARY=0
case "${1:-}" in
  "") ;;
  --summary) SUMMARY=1 ;;
  --sha)
    [[ $# -eq 2 ]] || usage
    f="$2"; [[ -f "$f" ]] || f="$VENDOR/$2"
    [[ -f "$f" ]] || { echo "check-vendored: no such file: $2" >&2; exit 64; }
    sha256 "$f"; exit 0 ;;
  *) usage ;;
esac
[[ -f "$MANIFEST" ]] || { echo "check-vendored: no manifest at $MANIFEST" >&2; exit 2; }

ERR="$(mktemp "${TMPDIR:-/tmp}/check-vendored.XXXXXX")" || exit 2; trap 'rm -f "$ERR"' EXIT
SEMVER='[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]*)?'

latest_of() {   # latest_of <npm package>: print its latest version; non-zero with a reason on stderr
  local url="$REGISTRY/$1/latest" body v
  body="$("$CURL" -fsS --max-time 30 "$url" 2>&1)" || { echo "npm registry lookup failed for $1 ($url): ${body:-no answer}" >&2; return 1; }
  if (( JQ )); then
    v="$(printf '%s' "$body" | jq -r 'if type == "object" and (.version | type) == "string" then .version else empty end' 2>/dev/null)"
  else
    v="$(printf '%s' "$body" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | sort -u)"
  fi
  if ! grep -qxE "$SEMVER" <<< "$v" || [[ "$(wc -l <<< "$v" | tr -d ' ')" != 1 ]]; then   # here-strings: grep -q in a pipe can SIGPIPE its writer
    echo "npm registry lookup for $1 ($url) answered no readable version" >&2; return 1
  fi
  printf '%s\n' "$v"
}

advisories_of() {   # advisories_of <npm package> <version>: one "id<TAB>severity<TAB>fixed" line per advisory; non-zero on failure
  local q body
  q="{\"package\":{\"name\":\"$1\",\"ecosystem\":\"npm\"},\"version\":\"$2\"}"
  body="$("$CURL" -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d "$q" "$OSV" 2>&1)" \
    || { echo "OSV lookup failed for $1 $2 ($OSV): ${body:-no answer}" >&2; return 1; }
  if (( JQ )); then
    printf '%s' "$body" | jq -e 'type == "object" and ((.vulns // []) | type) == "array" and all((.vulns // [])[]; type == "object" and (.id | type) == "string")' >/dev/null 2>&1 \
      || { echo "OSV lookup for $1 $2 answered something unreadable" >&2; return 1; }
    printf '%s' "$body" | jq -r '(.vulns // [])[] | [.id,
        (.database_specific.severity // ([.severity[]?.score] | first) // "severity n/a"),
        ([.affected[]?.ranges[]?.events[]?.fixed // empty] | unique | join(" or ") | if . == "" then "no fix" else . end)] | @tsv' \
      || { echo "OSV lookup for $1 $2 answered something unreadable" >&2; return 1; }
  else
    local flat; flat="$(printf '%s' "$body" | tr -d '\n\r')"
    if grep -qE '^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$' <<< "$flat"; then return 0; fi
    grep -qE '^[[:space:]]*\{.*"vulns"[[:space:]]*:[[:space:]]*\[.*\}[[:space:]]*$' <<< "$flat" \
      || { echo "OSV lookup for $1 $2 answered something unreadable" >&2; return 1; }
    if grep -qE '"vulns"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]' <<< "$flat" \
      && ! grep -qE '"id"[[:space:]]*:[[:space:]]*"[^"]' <<< "$flat"; then
      echo "OSV lookup for $1 $2 answered something unreadable" >&2; return 1
    fi
    printf '%s' "$flat" | sed 's/"id"[[:space:]]*:[[:space:]]*"/\
@@ID@@/g' | sed -n 's/^@@ID@@//p' | while IFS= read -r chunk || [[ -n "$chunk" ]]; do
      local id sev fix
      id="${chunk%%\"*}"
      sev="$(printf '%s' "$chunk" | grep -oE '"severity"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -nE '1s/.*"([^"]*)"$/\1/p')"
      fix="$(printf '%s' "$chunk" | grep -oE '"fixed"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | sort -u | paste -sd' ' - | sed 's/ / or /g')"
      printf '%s\t%s\t%s\n' "$id" "${sev:-severity n/a}" "${fix:-no fix}"
    done
  fi
}

behind() {   # behind <vendored> <latest>: "up to date", "N major", "N minor" or "N patch"
  local a b; a="${1%%[-+]*}"; b="${2%%[-+]*}"
  local am an ap bm bn bp
  IFS=. read -r am an ap <<< "$a"; IFS=. read -r bm bn bp <<< "$b"
  if (( bm > am )); then echo "$((bm - am)) major"
  elif (( bm == am && bn > an )); then echo "$((bn - an)) minor"
  elif (( bm == am && bn == an && bp > ap )); then echo "$((bp - ap)) patch"
  elif [[ "$a" == "$b" ]]; then echo "up to date"
  else echo "ahead of latest"
  fi
}

TABLE="| package | vendored | latest | behind | advisories on the vendored version | release notes |
|---|---|---|---|---|---|"
NOTES=(); FAILED=0; AFFECTED=0; NEWER=0
seen=" "
while IFS=$'\t' read -r file pkg track ver up lic sum why; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  [[ "$seen" == *" $pkg@$ver "* ]] && continue
  seen="$seen$pkg@$ver "
  if [[ -z "$why" ]]; then NOTES+=("manifest row $file has fewer than 8 columns"); FAILED=1; continue; fi
  name="$pkg"; [[ "$track" == "$pkg" ]] || name="$pkg (now $track)"
  if latest="$(latest_of "$track" 2>"$ERR")"; then
    gap="$(behind "$ver" "$latest")"
    [[ "$gap" == "up to date" ]] || { NEWER=1; NOTES+=("newer version: $track $latest (vendored $pkg $ver, $gap behind)"); }
  else
    latest="lookup failed"; gap="?"; FAILED=1; NOTES+=("$(cat "$ERR")")
  fi
  if adv="$(advisories_of "$pkg" "$ver" 2>"$ERR")"; then
    if [[ -n "$adv" ]]; then
      AFFECTED=1
      cell="$(printf '%s\n' "$adv" | awk -F'\t' '{printf "%s%s (%s, fixed in %s)", (NR>1?"; ":""), $1, $2, $3}')"
      NOTES+=("ADVISORY: $pkg $ver is affected by $cell")
    else
      cell="none"
    fi
  else
    cell="lookup failed"; FAILED=1; NOTES+=("$(cat "$ERR")")
  fi
  TABLE="$TABLE
| $name | $ver | $latest | $gap | $cell | ${up%/}/releases |"
done < "$MANIFEST"

if (( FAILED )); then verdict="FAIL: a lookup failed; advisories are unknown, not absent"
elif (( AFFECTED )); then verdict="FAIL: an advisory affects a vendored version (a P0 ticket the same day: docs/ci-security.md)"
elif (( NEWER )); then verdict="ok: no advisory affects a vendored version; a newer version exists (information, not a failure)"
else verdict="ok: no advisory affects a vendored version; every package is up to date"
fi

report="## Vendored third-party code

$TABLE
"
for n in ${NOTES[@]+"${NOTES[@]}"}; do report="$report
- $n"; done
report="$report

**$verdict**"
printf '%s\n' "$report"
if (( SUMMARY )) && [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"; fi

if (( FAILED )); then exit 2; elif (( AFFECTED )); then exit 1; fi
exit 0
