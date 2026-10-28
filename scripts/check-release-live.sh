#!/usr/bin/env bash
# check-release-live.sh — the last step of a release (t-ea3a): is it published on getcanon.dev?
#   check-release-live.sh vX.Y.Z [--manifest-line "<line>"] [--integrity-line "<line>"] [--wait <seconds>]
# Reads releases.txt and integrity.txt (each must carry the exact line scripts/release.sh printed, or, without one, a line for the
# tag) and updated.js (the header badge, window.CANON_VERSION, must be X.Y.Z), under CANON_SITE_URL (default https://getcanon.dev; tests use file://).
# Read-only. Prints ok / missing / could not read per file; exit 0 when all three are ok, 1 otherwise, 2 on a usage error.
# --wait retries every CANON_LIVE_POLL seconds (default 15) until all pass or the time is up: the site deploys a minute or so after
# its push. docs/releasing.md step 5.
set -euo pipefail

usage() { echo "Usage: check-release-live.sh vX.Y.Z [--manifest-line \"<line>\"] [--integrity-line \"<line>\"] [--wait <seconds>]" >&2; exit 2; }

tag="${1-}"; [[ $# -gt 0 ]] && shift
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "check-release-live: the tag must look like v0.28.1 (got '$tag')" >&2; exit 2; }
mline="" iline="" wait=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-line)  [[ $# -ge 2 ]] || usage; mline="$2"; shift 2 ;;
    --integrity-line) [[ $# -ge 2 ]] || usage; iline="$2"; shift 2 ;;
    --wait)           [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; wait="$2"; shift 2 ;;
    *) usage ;;
  esac
done
for l in "$mline" "$iline"; do
  [[ -z "$l" || "$l" == "$tag "* ]] || { echo "check-release-live: a given line must start with '$tag ' (got '$l')" >&2; exit 2; }
done
base="${CANON_SITE_URL:-https://getcanon.dev}"; base="${base%/}"
ver="${tag#v}"
poll="${CANON_LIVE_POLL:-15}"
command -v curl >/dev/null 2>&1 || { echo "check-release-live: curl is required" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch() {   # fetch <file>: the published file into $tmp, or exit status 1
  curl -fsSL --max-time 30 --max-filesize 1048576 --proto '=https,file' --proto-redir '=https' "$base/$1" -o "$tmp/$1" 2>/dev/null
}
# check: one line per file; returns 0 when all three are ok
check() {
  local f bad=0 want
  for f in releases.txt integrity.txt; do
    want="$mline"; [[ "$f" == integrity.txt ]] && want="$iline"
    if ! fetch "$f"; then echo "  could not read $base/$f"; bad=1
    elif [[ -n "$want" ]] && grep -qxF -- "$want" "$tmp/$f"; then echo "  ok       $f: $want"
    elif [[ -z "$want" ]] && grep -q "^${tag//./\\.} " "$tmp/$f"; then echo "  ok       $f: a line for $tag"
    else echo "  missing  $f: ${want:-a line for $tag}"; bad=1; fi
  done
  if ! fetch updated.js; then echo "  could not read $base/updated.js"; bad=1
  elif grep -qE "CANON_VERSION *= *\"${ver//./\\.}\"" "$tmp/updated.js"; then echo "  ok       updated.js: the badge names $tag"   # window.CANON_VERSION = "0.28.1";
  else echo "  missing  updated.js: the badge does not name $tag (npm run stamp in canon-site)"; bad=1; fi
  return "$bad"
}

start=$SECONDS
while :; do
  if out="$(check)"; then echo "check-release-live: $tag is live on $base"; printf '%s\n' "$out"; exit 0; fi
  (( SECONDS - start + poll <= wait )) || break
  sleep "$poll"
done
echo "check-release-live: $tag is not fully published on $base$( ((wait > 0)) && echo " after ${wait}s" ):"
printf '%s\n' "$out"
echo "  publish the canon-site lines and badge: docs/releasing.md step 5"
exit 1
