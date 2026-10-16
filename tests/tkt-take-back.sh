#!/usr/bin/env bash
# t-d271: tkt take-back brings a ticket sent to GitHub back: github: goes; --close-issue first closes the issue with a
# comment in one gh call, and a gh failure leaves ticket.md byte-identical; a ticket never sent, or merged, is refused.
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

# --close-issue: one gh call (close with its comment, so a retry never comments twice), outside any checkout.
link; : > "$STUB_LOG"
out="$("$TKT" take-back "$id" --close-issue)"; assert_contains "$out" "acme/app#57 closed"
assert_eq "issue close 57 --repo acme/app --comment Taken back to local by canon ($id). | cwd /" "$(cat "$STUB_LOG")"
grep -q '^github:' "$f" && fail "github: still there after --close-issue"

# gh fails: exit 1, ticket byte-identical.
link; before="$(sig)"; rc=0; out="$(STUB_FAIL="issue close" "$TKT" take-back "$id" --close-issue 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a failing gh should exit 1"; assert_contains "$out" "HTTP 502"
[[ "$(sig)" == "$before" ]] || fail "ticket changed although gh failed"
awk '!/^github: /' "$f" > "$stub/t" && mv "$stub/t" "$f"

# An unreadable github: line: refused before any gh call, unchanged.
awk '/^---$/ && ++n == 2 { print "github: not a repo" } { print }' "$f" > "$stub/t" && mv "$stub/t" "$f"
before="$(sig)"; : > "$STUB_LOG"; rc=0; out="$("$TKT" take-back "$id" --close-issue 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unreadable github: line should exit 1"; assert_contains "$out" "unreadable github: line"
[[ "$(sig)" == "$before" && ! -s "$STUB_LOG" ]] || fail "changed the ticket or called gh"
awk '!/^github: /' "$f" > "$stub/t" && mv "$stub/t" "$f"

# Merged: refused, unchanged.
link; awk '/^---$/ && ++n == 2 { print "merged: abc123" } { print }' "$f" > "$stub/t" && mv "$stub/t" "$f"
before="$(sig)"; rc=0; out="$("$TKT" take-back "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "take-back of a merged ticket should exit 1"; assert_contains "$out" "is merged"; [[ "$(sig)" == "$before" ]] || fail "changed"

echo "tkt-take-back: ok"
