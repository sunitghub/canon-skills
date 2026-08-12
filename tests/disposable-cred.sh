#!/usr/bin/env bash
# tests/disposable-cred.sh — proves the invariants of tools/disposable-cred using mock provision/revoke/
# command (deterministic, no network, no real secrets). Portable: no GNU-only constructs (Git Bash safe).
# Invariants:
#   (a) the issued credential is revoked after a normal run;
#   (b) it is revoked even when the wrapped command exits non-zero (trap teardown), and that status propagates;
#   (c) it is revoked exactly once;
#   (d) the command env has $CRED_VAR (the handle) but NOT the provisioning secret, the hooks, or an
#       UNLISTED decoy var (allowlist, not denylist);
#   (e) the provisioning secret is never printed;
#   (f) missing hook / missing command / empty handle / revoke-failure produce the documented exits;
#   (g) CRED_VAR overrides the injected name;
#   (h) the tool uses no GNU-only %3N date format (Windows/Git Bash safety).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/tools/disposable-cred"

fails=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
assert() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SECRET="provisioning-secret-DO-NOT-LEAK-42"

# Mock provisioner: prints ONLY a handle; records issuance; can see the host provisioning secret (proves
# the provisioner has access) — the wrapped command must not.
cat > "$tmp/prov.sh" <<'EOS'
#!/usr/bin/env bash
h="disp-${RANDOM}-$$"
echo "$h" >> "$ISSUED_LOG"
[ -n "${PROV_SECRET:-}" ] && echo "prov-saw-secret" >> "$ISSUED_LOG.saw"
printf '%s\n' "$h"
EOS
# Mock revoker: reads the handle on stdin; records it.
cat > "$tmp/revoke.sh" <<'EOS'
#!/usr/bin/env bash
read -r h || true
printf '%s\n' "$h" >> "$REVOKED_LOG"
EOS
# Mock command: dump its env to a BAKED path (env -i strips test vars, so we can't rely on an env var
# to tell it where to write) + optionally exit non-zero.
cat > "$tmp/cmd.sh" <<EOS
#!/usr/bin/env bash
env > "$tmp/cmd-env.txt"
echo "cmd ran"
exit \${CMD_RC:-0}
EOS
# Failing command (exit 7) — for the trap-on-failure invariant.
cat > "$tmp/cmd-fail.sh" <<EOS
#!/usr/bin/env bash
env > "$tmp/cmd-env.txt"
echo "cmd failing" >&2
exit 7
EOS

export ISSUED_LOG="$tmp/issued.log"
export REVOKED_LOG="$tmp/revoked.log"

run() {  # $1 = command script ; extra env from caller
  CRED_PROVISION_CMD="bash $tmp/prov.sh" \
  CRED_REVOKE_CMD="bash $tmp/revoke.sh" \
  PROV_SECRET="$SECRET" \
  LEAKME="canary-should-not-reach-command" \
  bash "$TOOL" -- bash "$1"
}

echo "--- normal run: issue + revoke + allowlist boundary ---"
: > "$ISSUED_LOG"; : > "$REVOKED_LOG"
set +e; out1="$(run "$tmp/cmd.sh" 2>&1)"; rc1=$?; set -e
issued1="$(tail -n 1 "$ISSUED_LOG" 2>/dev/null)"
assert '[ "$rc1" -eq 0 ]'                                              "(a) normal run exits 0"
assert 'grep -qxF "$issued1" "$REVOKED_LOG"'                          "(a) issued credential was revoked"
assert '[ "$(wc -l < "$REVOKED_LOG" | tr -d " ")" -eq 1 ]'           "(c) revoked exactly once"
assert 'grep -q "^CRED=$issued1$" "$tmp/cmd-env.txt"'                 "(d) command env has CRED = the disposable handle"
assert '! grep -q "^PROV_SECRET=" "$tmp/cmd-env.txt"'                "(d) provisioning secret var absent from command env"
assert '! grep -qF "$SECRET" "$tmp/cmd-env.txt"'                     "(d) provisioning secret value absent from command env"
assert '! grep -q "^CRED_PROVISION_CMD=" "$tmp/cmd-env.txt"'         "(d) command cannot mint (no CRED_PROVISION_CMD)"
assert '! grep -q "^CRED_REVOKE_CMD=" "$tmp/cmd-env.txt"'            "(d) command cannot revoke (no CRED_REVOKE_CMD)"
assert '! grep -q "^LEAKME=" "$tmp/cmd-env.txt"'                     "(d) an UNLISTED decoy var is dropped (allowlist, not denylist)"
assert '! printf "%s" "$out1" | grep -qF "$SECRET"'                  "(e) provisioning secret never printed"
assert '! printf "%s" "$out1" | grep -qF "$issued1"'                 "(e) handle value not printed"
assert '[ -f "$ISSUED_LOG.saw" ]'                                    "boundary is at the command, not the provisioner (provisioner saw the secret)"

echo "--- failing command: revoke via trap + status propagates ---"
: > "$ISSUED_LOG"; : > "$REVOKED_LOG"
set +e; out2="$(run "$tmp/cmd-fail.sh" 2>&1)"; rc2=$?; set -e
issued2="$(tail -n 1 "$ISSUED_LOG" 2>/dev/null)"
assert '[ "$rc2" -eq 7 ]'                                            "(b) command failure status propagates"
assert 'grep -qxF "$issued2" "$REVOKED_LOG"'                         "(b) credential revoked even when the command failed"

echo "--- CRED_VAR override ---"
: > "$ISSUED_LOG"; : > "$REVOKED_LOG"
CRED_PROVISION_CMD="bash $tmp/prov.sh" CRED_REVOKE_CMD="bash $tmp/revoke.sh" PROV_SECRET="$SECRET" \
  CRED_VAR="MYTOKEN" bash "$TOOL" -- bash "$tmp/cmd.sh" >/dev/null 2>&1
issued3="$(tail -n 1 "$ISSUED_LOG" 2>/dev/null)"
assert 'grep -q "^MYTOKEN=$issued3$" "$tmp/cmd-env.txt"'             "(g) CRED_VAR overrides the injected handle name"
assert '! grep -q "^CRED=" "$tmp/cmd-env.txt"'                      "(g) default CRED is not injected when overridden"

echo "--- guards: missing hook / missing command / empty handle / revoke failure ---"
set +e
CRED_REVOKE_CMD="bash $tmp/revoke.sh" bash "$TOOL" -- bash "$tmp/cmd.sh" >/dev/null 2>&1; rc_noprov=$?
CRED_PROVISION_CMD="bash $tmp/prov.sh" CRED_REVOKE_CMD="bash $tmp/revoke.sh" bash "$TOOL" >/dev/null 2>&1; rc_nocmd=$?
CRED_PROVISION_CMD="true" CRED_REVOKE_CMD="bash $tmp/revoke.sh" bash "$TOOL" -- bash "$tmp/cmd.sh" >/dev/null 2>&1; rc_empty=$?
: > "$REVOKED_LOG"
out_rf="$(CRED_PROVISION_CMD="bash $tmp/prov.sh" CRED_REVOKE_CMD="false" PROV_SECRET="$SECRET" bash "$TOOL" -- bash "$tmp/cmd.sh" 2>&1)"; rc_rf=$?
set -e
assert '[ "$rc_noprov" -eq 2 ]'                                      "(f) missing CRED_PROVISION_CMD => exit 2"
assert '[ "$rc_nocmd" -eq 2 ]'                                       "(f) missing command => exit 2"
assert '[ "$rc_empty" -eq 1 ]'                                       "(f) empty handle => exit 1"
assert '[ "$rc_rf" -eq 3 ]'                                          "(f) revoke failure => exit 3"
assert 'printf "%s" "$out_rf" | grep -q "orphaned credential"'       "(f) revoke failure is surfaced loudly"

echo "--- portability: no GNU-only %3N ---"
assert '[ "$(awk "/%3N/ && \$0 !~ /^[[:space:]]*#/ {n++} END{print n+0}" "$TOOL")" -eq 0 ]' "(h) no GNU-only %3N in the tool"
assert '! grep -qE "canon-factory|TIERB_|run-arm" "$TOOL"'           "self-contained: no canon-factory/TIERB_/run-arm reference"

if [ "$fails" -eq 0 ]; then
  echo "disposable-cred: ok"
  exit 0
else
  echo "$fails FAILURE(S)"
  exit 1
fi
