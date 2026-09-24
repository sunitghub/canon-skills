#!/usr/bin/env bash
# tests/hooks-lib-settings.sh — t-55c1: _uninstall_claude (run by every skills add/refresh) removes only
# LEGACY canon hook entries from .claude/settings.json. It used to count any mention of a canon script, so
# canon's own permission rule "Bash(subagent-log.sh:*)" triggered it, and its collapse-to-{} wiped the whole
# file on every refresh (live on the Windows VM, 2026-09-24).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run() { bash -c 'source "$1/tools/hooks-lib.sh"; _uninstall_claude "$2"' _ "$ROOT" "$1" >/dev/null; }
valid_json() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

# 1. Permissions only (canon's own rules), in python's layout and in PowerShell 5.1's: untouched.
cat > "$tmp/py.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(subagent-log.sh:*)"
    ],
    "deny": [
      "Bash(brew install:*)"
    ]
  },
  "env": {
    "X": "1"
  }
}
EOF
printf '{\r\n    "permissions":  {\r\n                        "allow":  [\r\n                                      "Bash(subagent-log.sh:*)"\r\n                                  ],\r\n                        "deny":  [\r\n                                     "Bash(brew install:*)"\r\n                                 ]\r\n                    }\r\n}\r\n' > "$tmp/ps.json"
for f in py ps; do
  cp "$tmp/$f.json" "$tmp/$f.orig"
  run "$tmp/$f.json"
  cmp -s "$tmp/$f.json" "$tmp/$f.orig" || fail "$f layout: permissions-only settings.json was modified: $(head -c 200 "$tmp/$f.json")"
done

# 2. A legacy canon hook next to permissions: the hook goes, the permissions stay, still valid JSON.
cat > "$tmp/mixed.json" <<'EOF'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash /old/canon/tools/subagent-log.sh" }
        ]
      }
    ]
  },
  "permissions": {
    "allow": [
      "Bash(subagent-log.sh:*)"
    ]
  }
}
EOF
run "$tmp/mixed.json"
if grep -q '/old/canon/tools/subagent-log.sh' "$tmp/mixed.json"; then fail "legacy hook not removed"; fi
assert_count 1 'Bash(subagent-log.sh:*)' "$tmp/mixed.json"
if command -v python3 >/dev/null 2>&1; then valid_json "$tmp/mixed.json" || fail "mixed file no longer valid JSON: $(cat "$tmp/mixed.json")"; fi

# 3. Only a legacy canon hook (nothing else): still collapses to {}, as before.
printf '{\n  "hooks": {\n    "Stop": [\n      {\n        "matcher": "",\n        "hooks": [\n          { "type": "command", "command": "bash /old/canon/tools/auto-handoff.sh" }\n        ]\n      }\n    ]\n  }\n}\n' > "$tmp/hooksonly.json"
run "$tmp/hooksonly.json"
assert_eq "{}" "$(cat "$tmp/hooksonly.json")"

# 3b. A legacy hook next to a capitalized user key (not a hook event): the key must survive (reviewer
#     finding: a [A-Z][A-Za-z]* whitelist treated "ApiKey" as hook structure and still collapsed to {}).
printf '{\n  "hooks": {\n    "Stop": [\n      {\n        "matcher": "",\n        "hooks": [\n          { "type": "command", "command": "bash /old/canon/tools/auto-handoff.sh" }\n        ]\n      }\n    ]\n  },\n  "ApiKey": "keep-me"\n}\n' > "$tmp/capkey.json"
run "$tmp/capkey.json"
assert_count 1 '"ApiKey": "keep-me"' "$tmp/capkey.json"
if grep -q 'auto-handoff.sh' "$tmp/capkey.json"; then fail "legacy hook not removed next to a capitalized key"; fi
if command -v python3 >/dev/null 2>&1; then valid_json "$tmp/capkey.json" || fail "capkey file no longer valid JSON: $(cat "$tmp/capkey.json")"; fi

# 3c. A legacy hook whose command holds escaped quotes (a quoted Windows path): still counted and removed
#     (reviewer finding: [^"]* stopped at the first \" so the hook was left behind).
printf '{\n  "hooks": {\n    "SubagentStop": [\n      {\n        "matcher": "",\n        "hooks": [\n          { "type": "command", "command": "\\"C:\\\\Program Files\\\\canon\\\\tools\\\\subagent-log.sh\\"" }\n        ]\n      }\n    ]\n  },\n  "permissions": {\n    "allow": [\n      "Bash(ls:*)"\n    ]\n  }\n}\n' > "$tmp/quoted.json"
grep -q 'Program Files' "$tmp/quoted.json" || fail "fixture: quoted hook missing"
run "$tmp/quoted.json"
if grep -q 'subagent-log.sh' "$tmp/quoted.json"; then fail "legacy hook with an escaped-quote path was left behind"; fi
assert_count 1 'Bash(ls:*)' "$tmp/quoted.json"
if command -v python3 >/dev/null 2>&1; then valid_json "$tmp/quoted.json" || fail "quoted file no longer valid JSON: $(cat "$tmp/quoted.json")"; fi

# 3d. The evaluator's reproductions (t-55c1 eval run 1): the prune step's line-based awk emptied compact
#     single-line JSON, and its second collapse ignored user keys. Whatever the surgery does, no non-hook
#     key may be lost; the wrapper restores the original instead ("left as is").
keeps() {  # <label> <json> <key-that-must-survive> [removed|left] — also asserts what happened to the hook
  printf '%s\n' "$2" > "$tmp/$1.json"; cp "$tmp/$1.json" "$tmp/$1.orig"
  out="$(bash -c 'source "$1/tools/hooks-lib.sh"; _uninstall_claude "$2"' _ "$ROOT" "$tmp/$1.json")"
  grep -qF "$3" "$tmp/$1.json" || fail "$1: lost $3 — now: $(cat "$tmp/$1.json") — said: $out"
  if command -v python3 >/dev/null 2>&1; then valid_json "$tmp/$1.json" || fail "$1: invalid JSON: $(cat "$tmp/$1.json")"; fi
  case "${4:-}" in
    removed) if grep -qE 'auto-handoff\.sh|subagent-log\.sh"' "$tmp/$1.json"; then fail "$1: legacy hook not removed: $(cat "$tmp/$1.json")"; fi ;;
    left)    cmp -s "$tmp/$1.json" "$tmp/$1.orig" || fail "$1: expected the file left byte-identical: $(cat "$tmp/$1.json")"
             assert_contains "$out" "left as is" ;;
  esac
}
keeps compact-apikey '{"hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "bash /old/canon/tools/auto-handoff.sh"}]}]}, "ApiKey": "user-secret-value"}' '"ApiKey": "user-secret-value"' left
keeps empty-skeleton-apikey "$(printf '{\n  "hooks": {\n    "Stop": [\n      {\n        "matcher": "",\n        "hooks": []\n      }\n    ]\n  },\n  "ApiKey": "keep-me"\n}')" '"ApiKey": "keep-me"'
keeps compact-quoted-perms '{"hooks": {"SubagentStop": [{"matcher": "", "hooks": [{"type": "command", "command": "\"C:\\Program Files\\canon\\tools\\subagent-log.sh\""}]}]}, "permissions": {"allow": ["Bash(ls:*)"]}}' '"Bash(ls:*)"' left
keeps compact-perms-only '{"permissions": {"allow": ["Bash(subagent-log.sh:*)"], "deny": ["Bash(brew install:*)"]}, "model": "sonnet"}' '"model": "sonnet"'

# 3e. The evaluator's run-2 finding: user data named like hook vocabulary. The guard compares everything
#     outside the top-level "hooks" member, so key names can't blind it.
legacy='"hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "bash /old/canon/tools/auto-handoff.sh"}]}]}'
keeps toplevel-matcher "{$legacy, \"matcher\": \"user-value\"}" '"user-value"'
keeps toplevel-timeout "{$legacy, \"timeout\": 42}" '42'
keeps toplevel-event   "{$legacy, \"Stop\": \"user-stop\"}" '"user-stop"'
keeps nested-hooks     "{$legacy, \"plugin\": {\"hooks\": {\"mine\": true}}}" '"mine"'
keeps pretty-matcher   "$(printf '{\n  %s,\n  "matcher": "user-value"\n}' "$legacy")" '"user-value"'

# 3f. Validity: an invalid settings.json is left alone; an edit whose result is invalid JSON is rolled back
#     even when everything outside "hooks" survived (the signature can't see inside "hooks").
printf '{"permissions": {"allow": ["Bash(ls:*)"],}}\n' > "$tmp/invalid.json"; cp "$tmp/invalid.json" "$tmp/invalid.orig"
out="$(bash -c 'source "$1/tools/hooks-lib.sh"; _uninstall_claude "$2"' _ "$ROOT" "$tmp/invalid.json")"
cmp -s "$tmp/invalid.json" "$tmp/invalid.orig" || fail "invalid settings.json was modified"
assert_contains "$out" "not valid JSON"
printf '%s\n' "{$legacy, \"permissions\": {\"allow\": [\"Bash(ls:*)\"]}}" > "$tmp/broken.json"; cp "$tmp/broken.json" "$tmp/broken.orig"
out="$(bash -c 'source "$1/tools/hooks-lib.sh"
  _uninstall_claude_edit() { sed -i.bak "s/\"hooks\": {/\"hooks\": {,/" "$1"; rm -f "$1.bak"; echo "  [removed]  1"; }   # corrupts inside "hooks" only
  _uninstall_claude "$2"' _ "$ROOT" "$tmp/broken.json")"
cmp -s "$tmp/broken.json" "$tmp/broken.orig" || fail "an edit that produced invalid JSON was kept: $(cat "$tmp/broken.json")"
assert_contains "$out" "left as is"

# 4. End to end: a real skills refresh must leave a settings.json holding canon's own rules untouched.
proj="$tmp/proj"; mkdir -p "$proj"; git -C "$proj" init -q; printf '# Agents\n' > "$proj/AGENTS.md"
HOME="$tmp/h" "$SKILLS" add sprint "$proj" >/dev/null 2>&1
mkdir -p "$proj/.claude"; cp "$tmp/py.orig" "$proj/.claude/settings.json"
HOME="$tmp/h" "$SKILLS" refresh "$proj" >/dev/null 2>&1 </dev/null
cmp -s "$proj/.claude/settings.json" "$tmp/py.orig" || fail "skills refresh changed settings.json: $(head -c 200 "$proj/.claude/settings.json")"

printf 'hooks-lib-settings: ok\n'
