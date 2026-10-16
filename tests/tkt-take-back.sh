#!/usr/bin/env bash
# t-d271: tkt take-back brings a ticket sent to GitHub back: github: goes; --close-issue comments then closes the issue
# first, and a gh failure leaves ticket.md byte-identical; a ticket never sent, or merged, is refused.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"; stub="$(mktemp -d "${TMPDIR:-/tmp}/tkt-take-back.XXXXXX")"
trap 'rm -rf "$project" "$stub"' EXIT
cd "$project"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
printf '%s | cwd %s\n' "$*" "$PWD" >> "$STUB_LOG"
[[ "${STUB_FAIL:-}" == "$1 $2" ]] && { echo "HTTP 502" >&2; exit 1; }
exit 0
SH
chmod +x "$stub/gh"; export PATH="$stub:$PATH" STUB_LOG="$stub/log"

id="$("$TKT" create "Sent one")"; f=".tickets/$id/ticket.md"
link() { awk -v g="github: acme/app#57" '/^---$/ && ++n == 2 { print g } { print }' "$f" > "$stub/t" && mv "$stub/t" "$f"; }
sig() { cksum < "$f"; }

# Never sent: refused, unchanged.
before="$(sig)"; rc=0; out="$("$TKT" take-back "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "take-back of an unsent ticket should exit 1"; assert_contains "$out" "was not sent to GitHub"; [[ "$(sig)" == "$before" ]] || fail "changed"

# Plain take-back: github: goes, no gh call.
link; : > "$STUB_LOG"
out="$("$TKT" take-back "$id")"; assert_contains "$out" "is back on this machine (acme/app#57 left open)"
grep -q '^github:' "$f" && fail "github: still there"; [[ ! -s "$STUB_LOG" ]] || fail "plain take-back called gh: $(cat "$STUB_LOG")"

# --close-issue: comment, then close, both from outside any checkout.
link; : > "$STUB_LOG"
out="$("$TKT" take-back "$id" --close-issue)"; assert_contains "$out" "acme/app#57 closed"
assert_eq "issue comment 57 --repo acme/app --body Taken back to local by canon ($id). | cwd /" "$(sed -n 1p "$STUB_LOG")"
assert_eq "issue close 57 --repo acme/app | cwd /" "$(sed -n 2p "$STUB_LOG")"
grep -q '^github:' "$f" && fail "github: still there after --close-issue"

# gh fails on either call: exit 1, ticket byte-identical.
for step in "issue comment" "issue close"; do
  link; before="$(sig)"; rc=0; out="$(STUB_FAIL="$step" "$TKT" take-back "$id" --close-issue 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "a failing gh $step should exit 1"; assert_contains "$out" "HTTP 502"
  [[ "$(sig)" == "$before" ]] || fail "ticket changed although gh $step failed"
  awk '!/^github: /' "$f" > "$stub/t" && mv "$stub/t" "$f"
done

# Merged: refused, unchanged.
link; awk '/^---$/ && ++n == 2 { print "merged: abc123" } { print }' "$f" > "$stub/t" && mv "$stub/t" "$f"
before="$(sig)"; rc=0; out="$("$TKT" take-back "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "take-back of a merged ticket should exit 1"; assert_contains "$out" "is merged"; [[ "$(sig)" == "$before" ]] || fail "changed"

echo "tkt-take-back: ok"
