#!/usr/bin/env bash
# release-manifest.sh — look up a release in the published manifest (t-34f1).
#   release-manifest.sh <vX.Y.Z>     prints `<zip sha256> <tag commit sha>` and exits 0, or says why not and exits 1.
# The manifest is https://getcanon.dev/releases.txt (the canon-site repo, a different write path from the canon-skills repo that holds the
# tag and the zip), one line per release: `<tag> <zip sha256> <tag commit sha>`; `#` comments and blank lines are skipped. A release is
# trusted only when the manifest has exactly one distinct, well-formed line for it. Unreachable, no line, a malformed line for the tag, two
# lines that disagree, a file with a NUL byte or over 1 MB: all refuse. Lines for other tags that do not parse are ignored (a newer format
# for them must not lock an older canon out of the releases it understands). There is no way to skip this check: CANON_MANIFEST_URL only
# says where to read the manifest (tests use file://). Called by `canon update --to`; install.ps1 does the same check in PowerShell.
set -euo pipefail

die() { echo "release-manifest: $*" >&2; exit 1; }

tag="${1-}"
re='^v[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$tag" =~ $re ]] || die "tag must look like v0.3.0 (got '$tag')"
url="${CANON_MANIFEST_URL:-https://getcanon.dev/releases.txt}"
command -v curl >/dev/null 2>&1 || die "curl is required to read $url"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsSL --max-time 30 --max-filesize 1048576 --proto '=https,file' --proto-redir '=https' "$url" -o "$tmp" 2>/dev/null \
  || die "cannot read the release manifest at $url; refusing to install $tag unverified (canon update --to main needs no manifest)"
[ "$(tr -d '\0' < "$tmp" | wc -c)" = "$(wc -c < "$tmp")" ] || die "the release manifest at $url contains a NUL byte; refusing"

# One awk pass: every line whose first field is the tag must be exactly `<tag> <64 hex> <40 hex>`; collect the distinct values.
result="$(LC_ALL=C tr -d '\r' < "$tmp" | LC_ALL=C awk -v tag="$tag" '
  /^#/ || NF == 0 { next }
  $1 != tag { next }
  {
    if ($0 !~ /^v[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]+ [0-9a-f]+$/ || length($2) != 64 || length($3) != 40) { bad = 1; next }
    v = $2 " " $3
    if (!(v in seen)) { seen[v] = 1; n++; val = v }
  }
  END { if (bad) print "MALFORMED"; else if (n == 0) print "MISSING"; else if (n > 1) print "CONFLICT"; else print "OK " val }
')" || die "could not read the release manifest"

case "$result" in
  "OK "*) printf '%s\n' "${result#OK }" ;;
  MALFORMED) die "the manifest line for $tag is malformed; refusing to install it" ;;
  CONFLICT) die "the manifest lists $tag twice with different values; refusing to install it" ;;
  *) die "$tag is not in the release manifest at $url; refusing to install it unverified" ;;
esac
