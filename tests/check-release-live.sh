#!/usr/bin/env bash
# check-release-live (t-ea3a) — scripts/check-release-live.sh says a release is live only when getcanon.dev's releases.txt and
# integrity.txt carry its lines and updated.js names it. Protects the last step of a release (docs/releasing.md step 5, the command
# scripts/release.sh prints last). No network: CANON_SITE_URL points at a folder through file://.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
SCRIPT="$ROOT/scripts/check-release-live.sh"
command -v curl >/dev/null 2>&1 || fail "check-release-live: curl is missing, this test cannot run"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
SITE="$W/site"; mkdir -p "$SITE"
furl() { if command -v cygpath >/dev/null 2>&1; then printf 'file:///%s' "$(cygpath -m "$1")"; else printf 'file://%s' "$1"; fi; }
ML="v0.9.1 $(printf 'a%.0s' {1..64}) $(printf 'b%.0s' {1..40})"
IL="v0.9.1 $(printf 'c%.0s' {1..64})"
publish() {   # the three files as the site serves them; each argument leaves one out or changes it
  printf '# canon release manifest\n%s\nv0.9.0 %s %s\n' "$ML" "$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..40})" > "$SITE/releases.txt"
  printf '# canon integrity list pins\n%s\n' "$IL" > "$SITE/integrity.txt"
  printf 'window.CANON_UPDATED = "2026-10-28T23:47:18Z";\nwindow.CANON_VERSION = "0.9.1";\n' > "$SITE/updated.js"
}
run() { rc=0; out="$(CANON_SITE_URL="$(furl "$SITE")" CANON_LIVE_POLL=1 "$SCRIPT" "$@" 2>&1)" || rc=$?; }

# All three published: exact lines, and tag-only.
publish; run v0.9.1 --manifest-line "$ML" --integrity-line "$IL"
assert_eq 0 "$rc"; assert_contains "$out" "check-release-live: v0.9.1 is live"
for f in releases.txt integrity.txt updated.js; do grep -q "^  ok       $f" <<< "$out" || fail "no ok line for $f: $out"; done
run v0.9.1; assert_eq 0 "$rc"; assert_contains "$out" "  ok       releases.txt: a line for v0.9.1"
run v0.9.1 --manifest-line "$ML"; assert_eq 0 "$rc"   # a flag with its value as the last arguments

# Each file missing in turn: exit 1, that file named missing, the others ok.
publish; grep -v '^v0.9.1 ' "$SITE/releases.txt" > "$W/x" && mv "$W/x" "$SITE/releases.txt"
run v0.9.1 --manifest-line "$ML" --integrity-line "$IL"; assert_eq 1 "$rc"; assert_contains "$out" "  missing  releases.txt: $ML"
assert_contains "$out" "  ok       integrity.txt"; assert_contains "$out" "publish the canon-site lines and badge: docs/releasing.md step 5"
publish; printf '# pins\n' > "$SITE/integrity.txt"
run v0.9.1 --manifest-line "$ML" --integrity-line "$IL"; assert_eq 1 "$rc"; assert_contains "$out" "  missing  integrity.txt: $IL"
publish; sed -i.bak 's/"0.9.1"/"0.9.0"/' "$SITE/updated.js" && rm -f "$SITE/updated.js.bak"
run v0.9.1; assert_eq 1 "$rc"; assert_contains "$out" "  missing  updated.js: the badge does not name v0.9.1"
publish; printf 'window.CANON_VERSION = "0.9.10";\n' > "$SITE/updated.js"   # a longer version is not this one
run v0.9.1; assert_eq 1 "$rc"; assert_contains "$out" "  missing  updated.js"
publish; printf 'v0x9x1 %s\n' "$(printf 'a%.0s' {1..64})" > "$SITE/releases.txt"   # a look-alike tag (dots are not wildcards)
run v0.9.1; assert_eq 1 "$rc"; assert_contains "$out" "  missing  releases.txt: a line for v0.9.1"

# A wrong hash is missing, not ok, even though the tag is there.
publish; run v0.9.1 --manifest-line "v0.9.1 $(printf 'f%.0s' {1..64}) $(printf 'b%.0s' {1..40})" --integrity-line "$IL"
assert_eq 1 "$rc"; assert_contains "$out" "  missing  releases.txt"

publish; printf '# x v0.9.1 %s\n' "$(printf 'a%.0s' {1..64})" > "$SITE/releases.txt"   # the tag mid-line is not a line for it
run v0.9.1; assert_eq 1 "$rc"; assert_contains "$out" "  missing  releases.txt: a line for v0.9.1"

# A file that cannot be read says so, never "missing".
publish; rm "$SITE/integrity.txt"; run v0.9.1
assert_eq 1 "$rc"; assert_contains "$out" "  could not read $(furl "$SITE")/integrity.txt"; [[ "$out" != *"missing  integrity.txt"* ]] || fail "an unreadable file read as missing: $out"
publish; rm "$SITE/updated.js"; run v0.9.1
assert_eq 1 "$rc"; assert_contains "$out" "  could not read $(furl "$SITE")/updated.js"

# Usage: a bad tag, a line for another tag, a bad --wait or flag: exit 2 (a usage error, not 1 for a missing release).
publish
for args in "0.9.1" "v0.9" "xv0.9.1" "v0.9.1x" "v0.9.1 --manifest-line v0.9.0_x" "v0.9.1 --wait soon" "v0.9.1 --wait 5s" "v0.9.1 --wait x5" "v0.9.1 --wait" \
            "v0.9.1 --manifest-line" "v0.9.1 --integrity-line" "v0.9.1 --bogus"; do
  # shellcheck disable=SC2086  # the args are split on purpose
  run $args; assert_eq 2 "$rc"
done

# --wait: a badge that appears mid-wait passes; one that never does fails after the wait.
publish; sed -i.bak 's/"0.9.1"/"0.9.0"/' "$SITE/updated.js" && rm -f "$SITE/updated.js.bak"
( sleep 2; publish ) & bg=$!
run v0.9.1 --wait 8; wait "$bg"
assert_eq 0 "$rc"; assert_contains "$out" "is live"
publish; printf 'window.CANON_VERSION = "0.9.0";\n' > "$SITE/updated.js"
start=$SECONDS; run v0.9.1 --wait 2
assert_eq 1 "$rc"; assert_contains "$out" "is not fully published on $(furl "$SITE") after 2s"; (( SECONDS - start < 10 )) || fail "--wait 2 took $((SECONDS - start))s"

# The docs that tell a maintainer, a contributor and the sprint close how a release ends name this check: renaming the script or
# dropping the step from one of them fails here, so they cannot drift apart unnoticed (release.sh's printed command: tests/release.sh).
for doc in docs/releasing.md CONTRIBUTING.md skills/sprint/reference/complete.md; do
  grep -qF 'scripts/check-release-live.sh' "$ROOT/$doc" || fail "$doc does not name scripts/check-release-live.sh as the last release step"
done
[[ -x "$SCRIPT" ]] || fail "the docs name $SCRIPT, which is missing or not executable"

echo "check-release-live: ok"
