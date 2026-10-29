#!/usr/bin/env bash
# tools/skills/prompts.sh — shared /dev/tty prompt helpers used across commands

# _prompt_or_auto_yes <question> — decides whether to apply a recommended,
# opt-out setup action (append an import line, add a permission rule, ...).
#
# TTY *availability* is not evidence the right human is present to answer:
# a long-lived server (canon/sprint-check) keeps its launch terminal
# as its controlling tty for its whole run, so a subprocess it shells out to
# in response to an unrelated HTTP request can still open /dev/tty even
# though nobody there is watching for this specific prompt (t-b47a). A
# caller acting on behalf of an API/browser-driven request must say so
# explicitly via SKILLS_SH_ASSUME_YES, which applies the recommended
# default immediately with no I/O at all — never inferred from the
# environment. Absent that, behavior is unchanged: a real human running
# `skills.sh add` directly still gets the interactive prompt.
# _has_tty — can a prompt reach a human? SKILLS_SH_NO_TTY says no explicitly (scripts/test.sh
# sets it, so a test run from a real terminal never stops for a prompt — t-2d74); otherwise a
# /dev/tty that opens.
_has_tty() {
  [ -z "${SKILLS_SH_NO_TTY:-}" ] && { : <> /dev/tty; } 2>/dev/null
}

# Read one answer from the terminal into the caller's `answer`. A Windows terminal ends the line with \r, so
# "y" arrives as "y\r" and never matched ^[Yy]$ — every prompt silently answered "no".
_read_tty_answer() {
  read -r -t 15 answer </dev/tty || return 1
  answer="${answer%$'\r'}"
}

_prompt_or_auto_yes() {
  local question="$1"
  if [ -n "${SKILLS_SH_ASSUME_YES:-}" ]; then
    return 0
  fi
  if ! _has_tty; then
    return 1
  fi
  printf "%s [y/N] (auto-skips in 15s) " "$question" > /dev/tty
  local answer
  _read_tty_answer || { echo "" > /dev/tty; return 1; }
  [[ "$answer" =~ ^[Yy]$ ]]
}

# _prompt_move_hook <hook> <local> — consent to move a user's own pre-commit hook aside (t-2194).
# Deliberately ignores SKILLS_SH_ASSUME_YES: that flag auto-applies *recommended* setup actions; relocating a
# user's own file needs a human's explicit yes. No terminal, a timeout or anything but y means no.
_prompt_move_hook() {
  _has_tty || return 1
  printf "%s is not canon-managed. Move it to %s so canon's hook chains it? [y/N] (auto-skips in 15s) " \
    "$1" "$(basename "$2")" > /dev/tty
  local answer
  _read_tty_answer || { echo "" > /dev/tty; return 1; }
  [[ "$answer" =~ ^[Yy]$ ]]
}

# t-50f7: install paths stored outside any project, re-pointed at <home>/current once the install is in the versioned layout:
# ~/.config/canon/install_path and the PATH line canon's own prompt writes to ~/.zshrc / ~/.bashrc (that exact line only; every other line
# of the file is left byte for byte). A no-op for a single-tree install or paths that already name current.
retarget_install_paths() {
  local ip="$HOME/.config/canon/install_path" cur new f tmp
  case "$SKILLS_ROOT" in */current) ;; *) return 0 ;; esac
  if [ -f "$ip" ]; then
    cur="$(cat "$ip")"
    if new="$(canon_current_path "$cur")" && [ "$new" = "$SKILLS_ROOT" ]; then
      printf '%s\n' "$new" > "$ip"; echo "  [updated]  ~/.config/canon/install_path -> $new"
    fi
  fi
  for f in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    tmp="$(mktemp)"
    if SR="$SKILLS_ROOT" H="${SKILLS_ROOT%/current}" awk '
      BEGIN { h = ENVIRON["H"]; sr = ENVIRON["SR"]; pre = "export PATH=\"$PATH:"; suf = "/tools\""; n = 0 }
      { l = $0; cr = ""; if (sub(/\r$/, "", l)) cr = "\r"
        if (index(l, pre) == 1 && length(l) > length(pre) + length(suf) && substr(l, length(l) - length(suf) + 1) == suf) {
          root = substr(l, length(pre) + 1, length(l) - length(pre) - length(suf)); rest = substr(root, length(h) + 11)
          if (root == h || (index(root, h "/packages/") == 1 && rest != "" && index(rest, "/") == 0)) { print pre sr suf cr; n++; next }
        }
        print }
      END { exit (n ? 0 : 1) }' "$f" > "$tmp"; then
      cat "$tmp" > "$f"; echo "  [updated]  $f: the canon PATH line now names $SKILLS_ROOT/tools"
    fi
    rm -f "$tmp"
  done
  return 0
}

offer_tkt_path() {
  local tools_dir="$SKILLS_ROOT/tools"
  local rc_file="$HOME/.zshrc"
  [[ "${SHELL:-}" == */bash ]] && rc_file="$HOME/.bashrc"
  if grep -qF "$tools_dir" "$rc_file" 2>/dev/null; then return 0; fi
  if echo "$PATH" | tr ':' '\n' | grep -qxF "$tools_dir"; then return 0; fi
  if ! _has_tty; then
    echo ""
    echo "canon/tools (canon, sprint, tkt, sprint-check) is not on your PATH."
    printf "  Add it with: echo 'export PATH=\"\$PATH:%s\"' >> %s\n" "$tools_dir" "$rc_file"
    printf "  Then run: source %s\n" "$rc_file"
    return 0
  fi
  echo "" > /dev/tty
  printf "canon/tools (canon, sprint, tkt, sprint-check) is not on your PATH.\n" > /dev/tty
  printf "Add %s to PATH in %s? [y/N] (auto-skips in 15s) " "$tools_dir" "$rc_file" > /dev/tty
  _read_tty_answer || { echo "" > /dev/tty; return 0; }
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
  if ! _has_tty; then
    return 0
  fi
  printf "Remove model-per-task note from AGENTS.md? [y/N] (auto-skips in 15s) " > /dev/tty
  _read_tty_answer || { echo "" > /dev/tty; return 0; }
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

# _settings <status|add|remove> <settings.json> <allow|deny> <rule>... — one word: present | absent (status), ok (add/remove) or
# invalid, from the board binary's `settings` helper (t-b62a: it replaced five python3 snippets and Windows' settings-merge.ps1, so
# every OS edits the same way). It keeps every other key, their order and their text, and never writes an invalid or symlinked
# file (t-f01d: _init_claude once overwrote a user's settings.json). No output (a crash, an unwritable file) reads as invalid.
# stdin is /dev/null: skills refresh runs this inside `while read … done <<< "$skills"`.
_settings() {
  local w; w="$("$CANON_BOARD" settings "$@" </dev/null 2>/dev/null)" || w=""
  printf '%s\n' "${w:-invalid}"
}

# _settings_ready <what> — sets CANON_BOARD for _settings, or prints a visible skip (returns 1) when the board binary isn't fetched.
_settings_ready() {
  CANON_BOARD="$(board_helper_bin 2>/dev/null)" && return 0
  echo "  [skip]  $1: canon's board binary isn't here yet — run canon update, then run this again"
  return 1
}

# t-c774: close gates keep Bash (git, tests, report write), so a tool list can't stop a gate installing
# software (a t-bd3e evaluator ran `brew install gawk` on the host). Deny system-wide installers only —
# project-level npm/pip stays allowed. Session-wide (settings has no per-subagent scope); asked first.
CANON_INSTALL_DENY_RULES=(
  "Bash(brew install:*)" "Bash(apt install:*)" "Bash(apt-get install:*)"
  "Bash(sudo apt install:*)" "Bash(sudo apt-get install:*)"
  "Bash(choco install:*)" "Bash(winget install:*)"
)

offer_install_deny_rules() {
  local project_dir="$1" settings="$1/.claude/settings.json" status
  _settings_ready "install deny rules" || return 0
  status="$(_settings status "$settings" deny "${CANON_INSTALL_DENY_RULES[@]}")"
  if [ "$status" = "invalid" ]; then
    echo "  [fail]  $settings is not valid JSON (or permissions/deny has the wrong type, or it is a symlink) — install deny rules not added"
    return 0
  fi
  [ "$status" = "present" ] && return 0
  if ! _prompt_or_auto_yes "Add deny rules to $settings so agents (incl. close gates) can't run system installers (brew/apt/choco/winget install)?"; then
    echo "  [skip]  install deny rules not added (see CANON_INSTALL_DENY_RULES in tools/skills/prompts.sh)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  if [ "$(_settings add "$settings" deny "${CANON_INSTALL_DENY_RULES[@]}")" = ok ]; then
    echo "  [ok]     $settings — added install deny rules"
  else
    echo "  [fail]   could not update $settings — left untouched"
  fi
  return 0
}

# Adds a Bash permission rule for tools/subagent-log.sh (invoked bare via PATH, per skills/sprint/reference/complete.md) so sprint
# close stops repeatedly prompting for it — reported on Windows but not actually OS-specific.
offer_subagent_log_permission() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local rule="Bash(subagent-log.sh:*)"
  local status

  _settings_ready "the subagent-log.sh permission rule" || return 0
  status="$(_settings status "$settings" allow "$rule")"
  if [ "$status" = "invalid" ]; then
    echo "  [fail]  $settings is not valid JSON (or a symlink) — skipping subagent-log.sh permission check"
    return 0
  fi
  [ "$status" = "present" ] && return 0

  if ! _prompt_or_auto_yes "Add a Bash permission rule for subagent-log.sh to $settings, so sprint close stops prompting for it?"; then
    echo "  [skip]  add \"$rule\" to permissions.allow in $settings to stop repeated subagent-log.sh prompts at sprint close"
    return 0
  fi

  mkdir -p "$(dirname "$settings")"
  if [ "$(_settings add "$settings" allow "$rule")" = ok ]; then
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
  CANON_BOARD="$(board_helper_bin 2>/dev/null)" || return 0
  [ "$(_settings status "$settings" allow "$rule")" = "present" ] || return 0

  if ! _has_tty; then
    return 0
  fi

  printf "Remove the subagent-log.sh permission rule from %s? [y/N] (auto-skips in 15s) " "$settings" > /dev/tty
  _read_tty_answer || { echo "" > /dev/tty; return 0; }
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  if [ "$(_settings remove "$settings" allow "$rule")" = ok ]; then
    echo "  $settings — removed subagent-log.sh permission rule." > /dev/tty
  else
    echo "  $settings — could not remove the subagent-log.sh permission rule; left as is." > /dev/tty
  fi
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
  # t-5a4b: a folder without git (or a machine without it) has no use for a git rule — and a stray file there is noise.
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
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
