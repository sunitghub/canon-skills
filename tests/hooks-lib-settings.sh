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

# 4. End to end: a real skills refresh must leave a settings.json holding canon's own rules untouched.
proj="$tmp/proj"; mkdir -p "$proj"; git -C "$proj" init -q; printf '# Agents\n' > "$proj/AGENTS.md"
HOME="$tmp/h" "$SKILLS" add sprint "$proj" >/dev/null 2>&1
mkdir -p "$proj/.claude"; cp "$tmp/py.orig" "$proj/.claude/settings.json"
HOME="$tmp/h" "$SKILLS" refresh "$proj" >/dev/null 2>&1 </dev/null
cmp -s "$proj/.claude/settings.json" "$tmp/py.orig" || fail "skills refresh changed settings.json: $(head -c 200 "$proj/.claude/settings.json")"

printf 'hooks-lib-settings: ok\n'
