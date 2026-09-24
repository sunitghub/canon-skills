#!/usr/bin/env bash
# tests/windows-no-python.sh — t-55c1: canon on a Windows machine that has only Git for Windows.
# End users have no Python; python3 may be missing, a do-nothing Store placeholder, or the Python install
# manager's alias, which installs Python when run. canon must detect all three without ever running an alias.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
probe() { PATH="$1:$PATH" bash -c 'source "$1/tools/skills/lib.sh"; have_python' _ "$ROOT"; }

# A python3 that records every run and would "work" (prints 1) — the install manager after it has
# installed Python. Under WindowsApps it must never be executed.
recording_python3() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\necho 1\n' "$1" > "$1/python3"
  chmod +x "$1/python3"
}

# --- 0. never execute a WindowsApps python3 (live: running it installed Python 3.14.7) ------------
wa="$tmp/Users/x/AppData/Local/Microsoft/WindowsApps"
recording_python3 "$wa"
if probe "$wa"; then fail "have_python accepted a WindowsApps python3"; fi
[[ ! -e "$wa/ran" ]] || fail "have_python executed a WindowsApps python3 (it can install Python)"

# Case-insensitive, as Windows paths are.
wa2="$tmp/users/x/APPDATA/local/MICROSOFT/windowsapps"
recording_python3 "$wa2"
if probe "$wa2"; then fail "have_python accepted an upper/lower-case WindowsApps python3"; fi
[[ ! -e "$wa2/ran" ]] || fail "have_python executed a mixed-case WindowsApps python3"

# Control: the same recorder elsewhere IS run and accepted, so the checks above can fail.
ok="$tmp/opt/python/bin"
recording_python3 "$ok"
probe "$ok" || fail "have_python rejected a working python3 outside WindowsApps"
[[ -e "$ok/ran" ]] || fail "control: a normal python3 should have been executed"

# Do-nothing placeholder (exit 0, no output) outside WindowsApps: executed but rejected.
stub="$tmp/stub"; mkdir -p "$stub"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/python3"; chmod +x "$stub/python3"
if probe "$stub"; then fail "have_python accepted a do-nothing python3"; fi

# --- settings.json merges on Windows without Python go through powershell.exe ----------------------
# A fake powershell.exe: logs mode/key/rule count and the decoded -EncodedCommand, answers like real
# PowerShell (CRLF), with the status answer taken from $PS_STATUS.
fakeps="$tmp/fakeps"; mkdir -p "$fakeps"
cat > "$fakeps/powershell.exe" <<'PS'
#!/usr/bin/env bash
enc=""; while [ $# -gt 0 ]; do [ "$1" = "-EncodedCommand" ] && enc="$2"; shift; done
printf '%s\n' "$enc" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 > "$PS_LOG.script"
n="$(printf '%s' "$CANON_RULES" | grep -c .)"
echo "$CANON_MODE $CANON_KEY rules=$n settings=$CANON_SETTINGS" >> "$PS_LOG"
case "$CANON_MODE" in status) printf '%s\r\n' "${PS_STATUS:-absent}" ;; *) printf 'ok\r\n' ;; esac
PS
chmod +x "$fakeps/powershell.exe"
proj="$tmp/proj"; mkdir -p "$proj/.claude"
psrun() {  # <function> — Windows, no Python, fake powershell.exe first on PATH
  PS_LOG="$tmp/ps.log" SKILLS_SH_ASSUME_YES=1 PATH="$fakeps:$PATH" bash -c '
    source "$1/tools/skills/project.sh"; source "$1/tools/skills/prompts.sh"
    _is_windows() { return 0; }; have_python() { return 1; }
    "$2" "$3"' _ "$ROOT" "$1" "$proj"
}

rm -f "$tmp/ps.log"; out="$(psrun offer_install_deny_rules)"
assert_contains "$out" "[ok]"
assert_contains "$out" "added install deny rules"
assert_eq "status deny rules=7 settings=$proj/.claude/settings.json" "$(sed -n 1p "$tmp/ps.log")"
assert_eq "add deny rules=7 settings=$proj/.claude/settings.json" "$(sed -n 2p "$tmp/ps.log")"
cmp -s "$tmp/ps.log.script" "$ROOT/tools/skills/settings-merge.ps1" || fail "EncodedCommand is not settings-merge.ps1"

rm -f "$tmp/ps.log"; out="$(psrun offer_subagent_log_permission)"
assert_contains "$out" "added Bash(subagent-log.sh:*)"
assert_eq "add allow rules=1 settings=$proj/.claude/settings.json" "$(sed -n 2p "$tmp/ps.log")"

# Already present (PowerShell's CRLF "present\r\n"): silent, no add.
rm -f "$tmp/ps.log"; out="$(PS_STATUS=present psrun offer_install_deny_rules)"
assert_eq "" "$out"
[ "$(grep -c '^add' "$tmp/ps.log")" -eq 0 ] || fail "added rules that were already present"

# invalid file, or powershell failing with no output: refused, nothing written.
for st in invalid ""; do
  rm -f "$tmp/ps.log"; out="$(PS_STATUS="$st" psrun offer_install_deny_rules)"
  [ -n "$st" ] || { printf '#!/usr/bin/env bash\nexit 1\n' > "$fakeps/powershell.exe"; out="$(psrun offer_install_deny_rules)"; }
  assert_contains "$out" "not valid JSON"
done

# Neither Python nor PowerShell (e.g. Linux without Python): honest skip.
out="$(SKILLS_SH_ASSUME_YES=1 PATH="/usr/bin:/bin" bash -c 'source "$1/tools/skills/project.sh"; source "$1/tools/skills/prompts.sh"
  _is_windows() { return 1; }; have_python() { return 1; }; offer_install_deny_rules "$2"' _ "$ROOT" "$proj")"
assert_contains "$out" "which isn't available here"

# --- end-to-end with a do-nothing python3 first on PATH (the placeholder case) ----------------------
flow="$tmp/flow"; mkdir -p "$flow"; git -C "$flow" init -q; printf '# Agents\n' > "$flow/AGENTS.md"
nop="$tmp/nop"; mkdir -p "$nop"; printf '#!/usr/bin/env bash\nexit 0\n' > "$nop/python3"; chmod +x "$nop/python3"
fp() { HOME="$tmp/fhome" PATH="$nop:$ROOT/tools:$PATH" "$@"; }
mkdir -p "$tmp/fhome"
out="$(fp "$SKILLS" add sprint "$flow" 2>&1)" || fail "skills add sprint failed with a placeholder python3: $out"
[[ "$out" != *"[ok]"*"settings.json"* ]] || fail "false [ok] on settings.json with a placeholder python3: $out"
assert_contains "$out" "which isn't available here"
out="$(fp "$SKILLS" refresh "$flow" 2>&1)" || fail "skills refresh failed with a placeholder python3: $out"
[[ ! -e "$flow/.claude/settings.json" ]] || ! grep -q "subagent-log" "$flow/.claude/settings.json" \
  || fail "settings.json written without a working python"
( cd "$flow" && id="$(fp tkt create "flow check" 2>/dev/null | tail -1)" && [ -n "$id" ] && fp tkt start "$id" >/dev/null 2>&1 ) \
  || fail "tkt create/start failed with a placeholder python3"
flow2="$tmp/flow2"; mkdir -p "$flow2"; git -C "$flow2" init -q     # sprint start refuses while another ticket is active
( cd "$flow2" && fp sprint start "flow sprint" >/dev/null 2>&1 ) || fail "sprint start failed with a placeholder python3"
[ "$(ls "$flow/.tickets" | grep -c '^t-')" -ge 1 ] && [ "$(ls "$flow2/.tickets" | grep -c '^t-')" -ge 1 ] \
  || fail "tickets not created in the flow"

printf 'windows-no-python: ok\n'
