#!/usr/bin/env bash
# tools/skills/prompts.sh — shared /dev/tty prompt helpers used across commands

offer_tkt_path() {
  local tools_dir="$SKILLS_ROOT/tools"
  local rc_file="$HOME/.zshrc"
  [[ "${SHELL:-}" == */bash ]] && rc_file="$HOME/.bashrc"
  if grep -qF "$tools_dir" "$rc_file" 2>/dev/null; then return 0; fi
  if echo "$PATH" | tr ':' '\n' | grep -qxF "$tools_dir"; then return 0; fi
  if ! { : <> /dev/tty; } 2>/dev/null; then
    echo ""
    echo "canon/tools (sprint, tkt, sprint-check) is not on your PATH."
    printf "  Add it with: echo 'export PATH=\"\$PATH:%s\"' >> %s\n" "$tools_dir" "$rc_file"
    printf "  Then run: source %s\n" "$rc_file"
    return 0
  fi
  echo "" > /dev/tty
  printf "canon/tools (sprint, tkt, sprint-check) is not on your PATH.\n" > /dev/tty
  printf "Add %s to PATH in %s? [y/N] (auto-skips in 15s) " "$tools_dir" "$rc_file" > /dev/tty
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 0; }
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    printf '\n# canon tools\nexport PATH="$PATH:%s"\n' "$tools_dir" >> "$rc_file"
    echo "  Added. Run: source $rc_file" > /dev/tty
  fi
}

offer_model_tiers_note() {
  local project_dir="$1"
  local target="$project_dir/AGENTS.md"
  local source_agents="$SKILLS_ROOT/AGENTS.md"
  if grep -qF "<!-- MODEL-TIERS:BEGIN -->" "$target" 2>/dev/null; then
    return 0
  fi
  if ! { : <> /dev/tty; } 2>/dev/null; then
    return 0
  fi
  printf "Update AGENTS.md with model-per-task note? [y/N] (auto-skips in 15s) " > /dev/tty
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 0; }
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    {
      echo ""
      awk '/<!-- MODEL-TIERS:BEGIN -->/{flag=1} flag; /<!-- MODEL-TIERS:END -->/{flag=0}' "$source_agents"
    } >> "$target"
    echo "AGENTS.md updated with model-per-task note." > /dev/tty
  fi
}

offer_remove_model_tiers_note() {
  local project_dir="$1"
  local target="$project_dir/AGENTS.md"
  if ! grep -qF "<!-- MODEL-TIERS:BEGIN -->" "$target" 2>/dev/null; then
    return 0
  fi
  if ! { : <> /dev/tty; } 2>/dev/null; then
    return 0
  fi
  printf "Remove model-per-task note from AGENTS.md? [y/N] (auto-skips in 15s) " > /dev/tty
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 0; }
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    # offer_model_tiers_note always inserts its separator blank line BEFORE
    # BEGIN (never after END) — removal must undo exactly that, via one line
    # of lookback, and must never touch whatever follows END (that blank or
    # content belongs to the next block, not this one).
    awk '
      {
        if (/<!-- MODEL-TIERS:BEGIN -->/) {
          if (have) { if (held != "") print held; have = 0 }
          flag = 1
          next
        }
        if (flag == 1 && /<!-- MODEL-TIERS:END -->/) { flag = 0; next }
        if (flag == 1) { next }
        if (have) print held
        have = 1
        held = $0
      }
      END { if (have) print held }
    ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
    echo "AGENTS.md model-per-task note removed." > /dev/tty
  fi
}

# Shared by offer_subagent_log_permission/offer_remove_subagent_log_permission — echoes
# "present", "absent", or "invalid" (malformed JSON) for the given rule in
# permissions.allow. Caller is responsible for checking `command -v python3` first.
_subagent_log_rule_status() {
  local settings="$1" rule="$2"
  [ -f "$settings" ] || { echo "absent"; return 0; }
  python3 - "$settings" "$rule" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    print("invalid")
    sys.exit(0)
allow = data.get("permissions", {}).get("allow", [])
print("present" if sys.argv[2] in allow else "absent")
PYEOF
}

# Adds a Bash permission rule for tools/subagent-log.sh (invoked bare via PATH, per
# skills/sprint/reference/complete.md) so sprint close stops repeatedly prompting for it —
# reported on Windows but not actually OS-specific. JSON-aware (python3, already a hard
# dependency — see tools/sprint's eval-gate matching) read-modify-write, never sed/awk text
# surgery on this file: t-f01d's incident (_init_claude used to `cat > settings.json`
# unconditionally, destroying pre-existing permissions/model/hooks) means any write here
# must never touch unrelated keys.
offer_subagent_log_permission() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local rule="Bash(subagent-log.sh:*)"

  if ! command -v python3 &>/dev/null; then
    echo "  [fail]  python3 not found — cannot safely add the subagent-log.sh permission rule to $settings"
    return 0
  fi

  local status
  status="$(_subagent_log_rule_status "$settings" "$rule")"
  if [ "$status" = "invalid" ]; then
    echo "  [fail]  $settings is not valid JSON — skipping subagent-log.sh permission check"
    return 0
  fi
  [ "$status" = "present" ] && return 0

  if ! { : <> /dev/tty; } 2>/dev/null; then
    echo "  [skip]  add \"$rule\" to permissions.allow in $settings to stop repeated subagent-log.sh prompts at sprint close"
    return 0
  fi

  printf "Add a Bash permission rule for subagent-log.sh to %s, so sprint close stops prompting for it? [y/N] (auto-skips in 15s) " "$settings" > /dev/tty
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 0; }
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  mkdir -p "$(dirname "$settings")"
  if python3 - "$settings" "$rule" <<'PYEOF'
import json, sys
path, rule = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except Exception:
    sys.exit(1)
perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
if rule not in allow:
    allow.append(rule)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  then
    echo "  [ok]     $settings — added $rule" > /dev/tty
  else
    echo "  [fail]   could not update $settings — left untouched" > /dev/tty
  fi
}

offer_remove_subagent_log_permission() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local rule="Bash(subagent-log.sh:*)"

  [ -f "$settings" ] || return 0
  command -v python3 &>/dev/null || return 0

  local status
  status="$(_subagent_log_rule_status "$settings" "$rule")"
  [ "$status" = "present" ] || return 0

  if ! { : <> /dev/tty; } 2>/dev/null; then
    return 0
  fi

  printf "Remove the subagent-log.sh permission rule from %s? [y/N] (auto-skips in 15s) " "$settings" > /dev/tty
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 0; }
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  python3 - "$settings" "$rule" <<'PYEOF'
import json, sys
path, rule = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
perms = data.get("permissions")
if isinstance(perms, dict) and isinstance(perms.get("allow"), list) and rule in perms["allow"]:
    perms["allow"].remove(rule)
    if not perms["allow"]:
        del perms["allow"]
    if not perms:
        del data["permissions"]
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  echo "  $settings — removed subagent-log.sh permission rule." > /dev/tty
}

ensure_sprint_project_marker() {
  local project_dir="$1"
  mkdir -p "$project_dir/.tickets"
  echo "  [sprint]  ensured project-local .tickets/"
}

_post_register_prompts() {
  local name="$1" project_dir="$2"
  [[ "$name" == "ticket" || "$name" == "sprint-check" || "$name" == "sprint" ]] || return 0
  if [[ "$name" == "sprint" ]]; then
    ensure_sprint_project_marker "$project_dir"
    offer_subagent_log_permission "$project_dir"
  fi
  _init_git_precommit "$project_dir"
  offer_tkt_path
}

_prune_redundant_deps() {
  local skill_file="$1" project_dir="$2" name="$3"
  [ -z "$(fm_field "$skill_file" depends)" ] && return 0
  local agents_file="$project_dir/AGENTS.md"
  local redundant=()
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    grep -qF "| $dep |" "$agents_file" 2>/dev/null && redundant+=("$dep")
  done < <(resolve_deps "$skill_file")
  [ ${#redundant[@]} -eq 0 ] && return 0
  for dep in "${redundant[@]}"; do
    cmd_remove "$dep" "$project_dir" > /dev/null || true
  done
  local dep_list
  dep_list=$(printf '%s, ' "${redundant[@]}")
  echo ""
  echo "Removed: ${dep_list%, } — now included in ${name} transitively."
}
