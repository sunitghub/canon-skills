#!/usr/bin/env bash
# tools/skills/prompts.sh — shared /dev/tty prompt helpers used across commands

# _prompt_or_auto_yes <question> — decides whether to apply a recommended,
# opt-out setup action (append an import line, add a permission rule, ...).
#
# TTY *availability* is not evidence the right human is present to answer:
# a long-lived server (canon-cockpit/sprint-check) keeps its launch terminal
# as its controlling tty for its whole run, so a subprocess it shells out to
# in response to an unrelated HTTP request can still open /dev/tty even
# though nobody there is watching for this specific prompt (t-b47a). A
# caller acting on behalf of an API/browser-driven request must say so
# explicitly via SKILLS_SH_ASSUME_YES, which applies the recommended
# default immediately with no I/O at all — never inferred from the
# environment. Absent that, behavior is unchanged: a real human running
# `skills.sh add` directly still gets the interactive prompt.
_prompt_or_auto_yes() {
  local question="$1"
  if [ -n "${SKILLS_SH_ASSUME_YES:-}" ]; then
    return 0
  fi
  if ! { : <> /dev/tty; } 2>/dev/null; then
    return 1
  fi
  printf "%s [y/N] (auto-skips in 15s) " "$question" > /dev/tty
  local answer
  read -r -t 15 answer </dev/tty || { echo "" > /dev/tty; return 1; }
  [[ "$answer" =~ ^[Yy]$ ]]
}

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
    sync_model_tiers_block "$target" "$source_agents"
    return 0
  fi
  if _prompt_or_auto_yes "Update AGENTS.md with model-per-task note?"; then
    {
      echo ""
      awk '/<!-- MODEL-TIERS:BEGIN -->/{flag=1} flag; /<!-- MODEL-TIERS:END -->/{flag=0}' "$source_agents"
    } >> "$target"
    echo "AGENTS.md updated with model-per-task note."
  fi
}

# Awk prelude shared by the MODEL-TIERS helpers: a marker counts only as a whole line (optional \r)
# outside a ``` fence, so a doc example that quotes the markers is never mistaken for the block.
_MT_AWK='
  { line=$0; sub(/\r$/, "", line) }
  line ~ /^[ \t]*```/ { fence=!fence }
  { isb = !fence && line == "<!-- MODEL-TIERS:BEGIN -->"; ise = !fence && line == "<!-- MODEL-TIERS:END -->" }'

_model_tiers_block() {
  awk "$_MT_AWK"'
    isb && !done { f=1 }
    f { print line }
    f && ise { f=0; done=1 }' "$1"
}

# The block between the markers is canon-managed: a consumer's copy is replaced when canon's changes,
# so a retired rule never lingers in its AGENTS.md (t-bd3e). Content outside the markers is untouched.
sync_model_tiers_block() {
  local target="$1" source_agents="$2" desired current blk shape
  desired=$(_model_tiers_block "$source_agents")
  [ -n "$desired" ] || return 0
  # Exactly one BEGIN followed by its END; anything else (unclosed, duplicated) is left for a human.
  shape=$(awk "$_MT_AWK"'
    isb { nb++; if (open) bad=1; open=1 }
    ise { ne++; if (!open) bad=1; open=0 }
    END { print ((nb==1 && ne==1 && !bad) ? "ok" : "bad") }' "$target")
  if [ "$shape" != "ok" ]; then
    echo "  [AGENTS.md]  MODEL-TIERS markers are not a single BEGIN/END pair — left unchanged" >&2
    return 0
  fi
  current=$(_model_tiers_block "$target")
  [ "$current" = "$desired" ] && return 0
  blk=$(mktemp)
  printf '%s\n' "$desired" > "$blk"
  # Keep the target's line endings: a CRLF BEGIN line means the inserted block is written CRLF too.
  awk -v blk="$blk" "$_MT_AWK"'
    isb { eol = ($0 ~ /\r$/) ? "\r" : ""; while ((getline l < blk) > 0) print l eol; skip=1; next }
    skip { if (ise) skip=0; next }
    { print }' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
  rm -f "$blk"
  echo "  [AGENTS.md]  updated MODEL-TIERS block"
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
# permissions.allow. Caller is responsible for checking `have_python` first.
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
# t-c774: close gates keep Bash (git, tests, report write), so a tool list can't stop a gate installing
# software (a t-bd3e evaluator ran `brew install gawk` on the host). Deny system-wide installers only —
# project-level npm/pip stays allowed. Session-wide (settings has no per-subagent scope); asked first.
CANON_INSTALL_DENY_RULES=(
  "Bash(brew install:*)" "Bash(apt install:*)" "Bash(apt-get install:*)"
  "Bash(sudo apt install:*)" "Bash(sudo apt-get install:*)"
  "Bash(choco install:*)" "Bash(winget install:*)"
)

# prints: present | missing | invalid  (invalid = not JSON, or permissions/deny of the wrong type)
_deny_rules_status() {
  python3 - "$1" "${CANON_INSTALL_DENY_RULES[@]}" <<'PYEOF'
import json, sys
path, rules = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    print("missing"); sys.exit()
except Exception:
    print("invalid"); sys.exit()
perms = data.get("permissions", {}) if isinstance(data, dict) else None
deny = perms.get("deny", []) if isinstance(perms, dict) else None
if not isinstance(deny, list):
    print("invalid"); sys.exit()
print("present" if all(r in deny for r in rules) else "missing")
PYEOF
}

offer_install_deny_rules() {
  local project_dir="$1" settings="$1/.claude/settings.json" status
  have_python || { echo "  [skip]  install deny rules need Python, which isn't available here — left as is"; return 0; }
  # A crash while reading the file counts as invalid; under set -e a bare failing $(...) would abort add/refresh.
  # tr -d '\r': native Windows Python prints "present\r\n", and $(...) strips only the \n (t-c774).
  status="$(_deny_rules_status "$settings" | tr -d '\r')" || status=invalid
  if [ "$status" = "invalid" ]; then
    echo "  [fail]  $settings is not valid JSON (or permissions/deny has the wrong type) — install deny rules not added"
    return 0
  fi
  [ "$status" = "present" ] && return 0
  if ! _prompt_or_auto_yes "Add deny rules to $settings so agents (incl. close gates) can't run system installers (brew/apt/choco/winget install)?"; then
    echo "  [skip]  install deny rules not added (see CANON_INSTALL_DENY_RULES in tools/skills/prompts.sh)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  if python3 - "$settings" "${CANON_INSTALL_DENY_RULES[@]}" <<'PYEOF'
import json, sys
path, rules = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
if not isinstance(data, dict):
    sys.exit(1)
perms = data.setdefault("permissions", {})
if not isinstance(perms, dict):
    sys.exit(1)
deny = perms.setdefault("deny", [])
if not isinstance(deny, list):
    sys.exit(1)
for r in rules:
    if r not in deny:
        deny.append(r)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  then
    echo "  [ok]     $settings — added install deny rules"
  else
    echo "  [fail]   could not update $settings — left untouched"
  fi
  return 0
}

offer_subagent_log_permission() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local rule="Bash(subagent-log.sh:*)"

  if ! have_python; then
    echo "  [skip]  the subagent-log.sh permission rule needs Python, which isn't available here — left as is"
    return 0
  fi

  local status
  status="$(_subagent_log_rule_status "$settings" "$rule" | tr -d '\r')"   # Windows Python: "present\r"
  if [ "$status" = "invalid" ]; then
    echo "  [fail]  $settings is not valid JSON — skipping subagent-log.sh permission check"
    return 0
  fi
  [ "$status" = "present" ] && return 0

  if ! _prompt_or_auto_yes "Add a Bash permission rule for subagent-log.sh to $settings, so sprint close stops prompting for it?"; then
    echo "  [skip]  add \"$rule\" to permissions.allow in $settings to stop repeated subagent-log.sh prompts at sprint close"
    return 0
  fi

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
    echo "  [ok]     $settings — added $rule"
  else
    echo "  [fail]   could not update $settings — left untouched"
  fi
}

offer_remove_subagent_log_permission() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local rule="Bash(subagent-log.sh:*)"

  [ -f "$settings" ] || return 0
  have_python || return 0

  local status
  status="$(_subagent_log_rule_status "$settings" "$rule" | tr -d '\r')"   # Windows Python: "present\r"
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

# Consumer projects promote learnings into their own PROMOTED.md (never into canon's tree via the
# skills symlink), @-imported from AGENTS.md. canon itself keeps critique/ + standards/ (t-f65c).
ensure_promoted_learnings() {
  local project_dir="$1"
  [ "$(cd "$project_dir" && pwd -P)" = "$(cd "$SKILLS_ROOT" && pwd -P)" ] && return 0
  local promoted="$project_dir/PROMOTED.md" agents="$project_dir/AGENTS.md"
  if [ ! -e "$promoted" ] && [ ! -L "$promoted" ]; then
    cat > "$promoted" <<'EOF'
# Promoted Learnings

Durable lessons promoted from `LEARNINGS.md` by `promote-learnings` after human confirmation.
Loaded on every session via `@PROMOTED.md` in `AGENTS.md` — keep each entry to one or two lines.

<!-- canon:promoted:BEGIN -->

<!-- canon:promoted:END -->
EOF
    echo "  [sprint]  created PROMOTED.md"
  fi
  if ! has_line "@PROMOTED.md" "$agents"; then
    [ -s "$agents" ] && [ -n "$(tail -c1 "$agents")" ] && echo >> "$agents"
    echo "@PROMOTED.md" >> "$agents"
    echo "  [AGENTS.md]  added @PROMOTED.md import"
  fi
  return 0
}

# Git for Windows defaults to core.autocrlf=true, which checks scripts out CRLF — and bash can't run
# them. A committed eol=lf rule keeps every Windows clone and worktree runnable; inert on macOS (t-e681).
ensure_gitattributes() {
  local project_dir="$1"
  [ "$(cd "$project_dir" && pwd -P)" = "$(cd "$SKILLS_ROOT" && pwd -P)" ] && return 0
  local ga="$project_dir/.gitattributes"
  has_line "# canon:gitattributes:BEGIN" "$ga" && return 0
  if [ -f "$ga" ] && awk '{ sub(/\r$/, "") } $1 == "*.sh" { f=1; exit } END { exit !f }' "$ga"; then
    echo "  [sprint]  .gitattributes already has a *.sh rule — left as is"
    return 0
  fi
  if [ -L "$ga" ]; then
    echo "  [sprint]  .gitattributes is a symlink — left as is"
    return 0
  fi
  local verb=created eol=""
  if [ -f "$ga" ]; then
    verb=updated
    # Match an existing CRLF file's line endings rather than leaving it mixed.
    if awk '/\r$/ { f=1; exit } END { exit !f }' "$ga"; then eol=$'\r'; fi
    [ -s "$ga" ] && [ -n "$(tail -c1 "$ga")" ] && printf '%s\n' "$eol" >> "$ga"
  fi
  printf '%s\n' "# canon:gitattributes:BEGIN$eol" \
    "# Shell scripts stay LF: bash can't run CRLF, and Git for Windows checks out CRLF by default.$eol" \
    "*.sh text eol=lf$eol" "# canon:gitattributes:END$eol" >> "$ga"
  echo "  [sprint]  $verb .gitattributes (*.sh eol=lf) — run 'git add --renormalize .' once to fix scripts already checked out"
  return 0
}

_post_register_prompts() {
  local name="$1" project_dir="$2"
  [[ "$name" == "ticket" || "$name" == "sprint-check" || "$name" == "sprint" ]] || return 0
  if [[ "$name" == "sprint" ]]; then
    ensure_sprint_project_marker "$project_dir"
    ensure_promoted_learnings "$project_dir"
    ensure_gitattributes "$project_dir"
    upsert_gate_agents "$project_dir"
    offer_subagent_log_permission "$project_dir"
    offer_install_deny_rules "$project_dir"
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
