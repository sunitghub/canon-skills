#!/usr/bin/env bash
# hooks-lib.sh — hook management helpers for skills.sh
# Sourced by skills.sh after SKILLS_ROOT is set. Not a standalone script.

_init_claude() {
  local settings="$1"
  # canon no longer installs any Claude Code hooks (Stop/UserPromptSubmit/PreToolUse/
  # SubagentStop) — those guardrails moved to a git-native pre-commit hook
  # (_init_git_precommit) and an explicit CLI step (tools/subagent-log.sh), so this
  # settings.json is never written destructively. This call is migration-only: it
  # removes any of the 5 legacy hook entries left by an older canon install, via
  # _uninstall_claude's existing surgical-removal logic, and touches nothing else
  # in the file.
  if [[ ! -f "$settings" ]]; then
    echo "  [ok]     no Claude Code hooks needed"
    return 0
  fi
  _uninstall_claude "$settings"
}

_init_git_precommit() {
  local project_dir="$1"
  local hooks_dir="$project_dir/.git/hooks"
  local hook="$hooks_dir/pre-commit"
  local marker="# canon-managed-pre-commit-hook"
  local template="$SKILLS_ROOT/scripts/pre-commit-hook-template.sh"

  if [[ ! -d "$hooks_dir" ]]; then
    echo "  [skip]  $hook not found (not a git repo?)"
    return 0
  fi

  if [[ ! -f "$template" ]]; then
    echo "  [fail]  template not found: $template"
    return 1
  fi

  if [[ -f "$hook" ]] && ! grep -qF "$marker" "$hook" 2>/dev/null; then
    echo "  [fail]  $hook already exists and is not canon-managed."
    echo "          Refusing to overwrite an existing pre-commit hook. To get canon's"
    echo "          checks (ticket-close guard, high-risk sign-off gate, test suite,"
    echo "          wrapup reminder), merge the contents of $template into your hook"
    echo "          by hand, or move your existing hook aside and re-run."
    return 1
  fi

  {
    echo "#!/usr/bin/env bash"
    echo "$marker"
    echo "# Installed by skills.sh add/init — re-run to update, do not hand-edit."
    echo "CANON_ROOT=\"$SKILLS_ROOT\""
    cat "$template"
  } > "$hook"
  chmod +x "$hook"
  echo "  [ok]     .git/hooks/pre-commit installed"
}

_uninstall_git_precommit() {
  local project_dir="$1"
  local hook="$project_dir/.git/hooks/pre-commit"
  local marker="# canon-managed-pre-commit-hook"

  if [[ ! -f "$hook" ]]; then
    echo "  [skip]  $hook not found"
    return 0
  fi
  if ! grep -qF "$marker" "$hook" 2>/dev/null; then
    echo "  [warn]  $hook did not look canon-managed; skipped"
    return 0
  fi
  rm -f "$hook"
  echo "  [removed]  .git/hooks/pre-commit"
}

_init_pi() {
  local ext_src="$SKILLS_ROOT/extensions/pi/handoff.ts"
  local ext_dst="$HOME/.pi/agent/extensions/handoff.ts"
  if [ ! -d "$HOME/.pi" ]; then
    echo "  [skip]  pi not installed"
    return 0
  fi
  if [ ! -f "$ext_src" ]; then
    echo "  [fail]  extension not found: $ext_src"
    return 1
  fi
  mkdir -p "$(dirname "$ext_dst")"
  if [ -f "$ext_dst" ] && cmp -s "$ext_src" "$ext_dst"; then
    echo "  [ok]     handoff extension already installed"
  else
    cp "$ext_src" "$ext_dst"
    echo "  [added]  handoff.ts → $ext_dst"
    echo "           Run /reload in Pi to activate"
  fi
}

# True if settings.json has any key besides Claude Code hook structure: hooks, matcher, type, command,
# timeout, and the named hook events. An unknown key counts as user data, so the file is kept (safe side).
# Count form, not `grep -q`, under pipefail.
_CLAUDE_HOOK_KEYS='hooks|matcher|type|command|timeout|PreToolUse|PostToolUse|PostToolUseFailure|Notification|UserPromptSubmit|Stop|SubagentStart|SubagentStop|PreCompact|SessionStart|SessionEnd'
_has_non_hook_keys() {
  [ "$(grep -oE '"[^"]+"[[:space:]]*:' "$1" 2>/dev/null | sed -E 's/[[:space:]]*:$//' \
      | grep -cvxE "\"($_CLAUDE_HOOK_KEYS)\"" || true)" -gt 0 ]
}

# Structural signature of a settings.json with its top-level "hooks" member removed: tokens outside that
# member, space-joined, whitespace and commas dropped, strings verbatim. Equal signatures before and after
# the cleanup mean nothing outside "hooks" changed. Independent of key names, so a user key that happens
# to be called matcher/timeout/an event name, or a "hooks" key nested in a user object, is protected.
_settings_outside_hooks() {
  awk '
    # JSON signature with the top-level "hooks" member dropped. Pass 1 tokenizes (strings kept verbatim,
    # whitespace and commas dropped); pass 2 skips `"hooks" : <value>` at depth 1. POSIX awk only.
    { doc = doc $0 "\n" }
    END {
      n = length(doc); nt = 0
      for (i = 1; i <= n; i++) {
        c = substr(doc, i, 1)
        if (c == "\"") {                       # string token, escapes honoured
          s = c; i++
          while (i <= n) {
            c = substr(doc, i, 1); s = s c
            if (c == "\\") { i++; s = s substr(doc, i, 1) }
            else if (c == "\"") break
            i++
          }
          tk[++nt] = s
        } else if (c ~ /[{}\[\]:]/) {
          tk[++nt] = c
        } else if (c !~ /[ \t\r\n,]/) {        # literal: number / true / false / null
          s = c
          while (i < n && substr(doc, i + 1, 1) !~ /[ \t\r\n,{}\[\]:"]/) { i++; s = s substr(doc, i, 1) }
          tk[++nt] = s
        }
      }
      out = ""; depth = 0
      for (k = 1; k <= nt; k++) {
        t = tk[k]
        if (depth == 1 && t == "\"hooks\"" && tk[k + 1] == ":") {
          k += 2
          if (tk[k] == "{" || tk[k] == "[") {  # skip the whole object/array value
            d = 0
            for (; k <= nt; k++) {
              if (tk[k] == "{" || tk[k] == "[") d++
              else if (tk[k] == "}" || tk[k] == "]") { d--; if (d == 0) break }
            }
          }                                    # a primitive value is the single token already skipped
          continue
        }
        if (t == "{" || t == "[") depth++
        else if (t == "}" || t == "]") depth--
        out = out t " "
      }
      print out
    }
  ' "$1" 2>/dev/null
}

# True if the file is valid JSON: an awk tokenizer + recursive-descent check (objects, arrays, strings with
# escapes, literals), no Python — Windows end users have only Git Bash.
_json_valid() {
  awk '
    function val(   t) {
      t = tk[p]
      if (t == "{") return obj()
      if (t == "[") return arr()
      if (t ~ /^"/ || t ~ /^(true|false|null|-?[0-9][0-9.eE+-]*)$/) { p++; return 1 }
      return 0
    }
    function obj() {
      p++; if (tk[p] == "}") { p++; return 1 }
      while (1) {
        if (tk[p] !~ /^"/) return 0
        p++; if (tk[p] != ":") return 0
        p++; if (!val()) return 0
        if (tk[p] == ",") { p++; continue }
        if (tk[p] == "}") { p++; return 1 }
        return 0
      }
    }
    function arr() {
      p++; if (tk[p] == "]") { p++; return 1 }
      while (1) {
        if (!val()) return 0
        if (tk[p] == ",") { p++; continue }
        if (tk[p] == "]") { p++; return 1 }
        return 0
      }
    }
    { doc = doc $0 "\n" }
    END {
      n = length(doc); nt = 0; bad = 0
      for (i = 1; i <= n; i++) {
        c = substr(doc, i, 1)
        if (c == "\"") {
          s = c; i++; closed = 0
          while (i <= n) {
            c = substr(doc, i, 1); s = s c
            if (c == "\\") { i++; s = s substr(doc, i, 1) }
            else if (c == "\"") { closed = 1; break }
            i++
          }
          if (!closed) bad = 1
          tk[++nt] = s
        } else if (c ~ /[{}\[\]:,]/) {
          tk[++nt] = c
        } else if (c !~ /[ \t\r\n]/) {
          s = c
          while (i < n && substr(doc, i + 1, 1) !~ /[ \t\r\n,{}\[\]:"]/) { i++; s = s substr(doc, i, 1) }
          tk[++nt] = s
        }
      }
      p = 1
      exit !(!bad && nt > 0 && val() && p == nt + 1)
    }
  ' "$1" 2>/dev/null
}

# Removes legacy canon hook entries from settings.json. _uninstall_claude_edit does the line-based
# sed/awk surgery (no Python on Windows); this wrapper guarantees it can never cost the user a setting:
# if anything outside the top-level "hooks" member changes, or the file comes out empty or invalid JSON,
# the original is restored and the step
# is reported as left as is. Every add/refresh runs this, and the line-based editing wiped settings.json
# to {} in several shapes (t-55c1: canon's own permission rule; compact single-line JSON; a second,
# ungated collapse in the prune step). A stranded legacy hook is harmless; lost user settings are not.
_uninstall_claude() {
  local settings="$1"
  [ -f "$settings" ] || { _uninstall_claude_edit "$settings"; return 0; }
  local orig="${settings}.canon-orig" before after out
  if ! _json_valid "$settings"; then
    echo "  [skip]   $settings is not valid JSON — legacy canon hook cleanup left as is"
    return 0
  fi
  cp "$settings" "$orig"
  before="$(_settings_outside_hooks "$settings")"
  out="$(_uninstall_claude_edit "$settings")"
  after="$(_settings_outside_hooks "$settings")"
  if [ "$before" != "$after" ] || [ ! -s "$settings" ] || ! _json_valid "$settings"; then
    cp "$orig" "$settings"
    out="  [skip]   legacy canon hooks in $settings could not be removed without touching other settings — left as is"
  fi
  rm -f "$orig"
  printf '%s\n' "$out"
  return 0
}

_uninstall_claude_edit() {
  local settings="$1"

  if [ ! -f "$settings" ]; then
    echo "  [skip]  $settings not found"
    return 0
  fi

  local _canon_scripts=(auto-handoff.sh handoff-inject.sh sprint-inject.sh pre-commit-check.sh subagent-log.sh auto-polish-trigger.sh guard-managed-files.sh)
  local removed=0
  # Count only hook entries that RUN a canon script ("command": "…<script>…"). A bare grep for the
  # name also matched permission rules like "Bash(subagent-log.sh:*)" — which canon itself adds — so
  # every add/refresh ran this cleanup and the collapse below wiped settings.json to {} (t-55c1).
  for _n in "${_canon_scripts[@]}"; do
    local c
    # ([^"\\]|\\.)*: step over escaped characters, e.g. a quoted "C:\\Program Files\\…" path.
    c=$(grep -cE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*'"${_n//./\\.}" "$settings" 2>/dev/null) || c=0
    removed=$(( removed + c ))
  done

  if [ "$removed" -gt 0 ]; then
    local compact_tmp="${settings}.canon-compact"
    cp "$settings" "$compact_tmp"
    for _n in "${_canon_scripts[@]}"; do
      sed -E "s/\\{[^{}]*\\\"type\\\"[[:space:]]*:[[:space:]]*\\\"command\\\"[^{}]*\\\"command\\\"[[:space:]]*:[[:space:]]*\\\"[^\\\"]*${_n}\\\"[^{}]*\\}[[:space:]]*,?//g" "$compact_tmp" > "${compact_tmp}.next"
      mv "${compact_tmp}.next" "$compact_tmp"
    done
    sed -E 's/,[[:space:]]*([]}])/\1/g; s/([[\{])[[:space:]]*,/\1/g' "$compact_tmp" > "${compact_tmp}.next"
    mv "${compact_tmp}.next" "$compact_tmp"

    local tmp="${settings}.canon-tmp"
    awk '
      function push(line) { out[++n] = line }
      function flush_buffer(   i) {
        if (!drop) {
          for (i = 1; i <= blen; i++) push(buf[i])
        }
        blen = 0
        drop = 0
        capture = 0
      }
      function canon_line(line) {
        return line ~ /(auto-handoff|handoff-inject|sprint-inject|pre-commit-check|subagent-log|auto-polish-trigger|guard-managed-files)\.sh/
      }
      {
        if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"command"/ && $0 ~ /"command"[[:space:]]*:/) {
          if (!canon_line($0)) push($0)
          next
        }
        if (capture) {
          buf[++blen] = $0
          if (canon_line($0)) drop = 1
          if ($0 ~ /^[[:space:]]*}[,]?[[:space:]]*$/) flush_buffer()
          next
        }
        if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"command"/ && n > 0) {
          capture = 1
          blen = 0
          buf[++blen] = out[n]
          n--
          buf[++blen] = $0
          next
        }
        push($0)
      }
      END {
        if (capture) flush_buffer()
        for (i = 1; i <= n; i++) {
          if (out[i] ~ /^[[:space:]]*[]}][][,]?[[:space:]]*$/ && i > 1) {
            sub(/,[[:space:]]*$/, "", out[i - 1])
          }
        }
        for (i = 1; i <= n; i++) print out[i]
      }
    ' "$compact_tmp" > "$tmp"
    sed -E 's/,[[:space:]]*([]}])/\1/g; s/([[\{])[[:space:]]*,/\1/g' "$tmp" > "${tmp}.next"
    mv "${tmp}.next" "$tmp"
    mv "$tmp" "$settings"
    rm -f "$compact_tmp"

    # After removal: if no "command" entries remain AND the file holds nothing but hook structure,
    # it's just empty matcher wrappers — collapse to {}. Any other key (permissions, env, model, …)
    # keeps the file: collapsing it destroyed user settings (t-55c1).
    if ! grep -q '"command"' "$settings" 2>/dev/null && ! _has_non_hook_keys "$settings"; then
      printf '{}' > "$settings"
    fi
  fi

  # Prune leftover empty structures (empty matcher["hooks"] arrays, empty
  # event-type arrays, an empty "hooks" object). No python3 dependency —
  # uses awk for Windows/Git Bash compatibility.
  # Runs every time: a file left with an empty skeleton from an *older*
  # canon version has nothing for the removal step to find, but still
  # needs cleanup.
  local pruned=0
  if grep -qE '"hooks"[[:space:]]*:[[:space:]]*\[\]' "$settings" 2>/dev/null; then
    pruned=1
  fi
  # Also check if the hooks object is now effectively empty (only empty arrays)
  if [ "$removed" -gt 0 ] || [ "$pruned" -eq 1 ]; then
    local prune_tmp="${settings}.canon-prune"
    awk '
      # Remove objects whose "hooks" array is empty: { "matcher": "...", "hooks": [] }
      # Handles both single-line and multi-line variants.
      BEGIN { n = 0; skip = 0; brace = 0; buf_n = 0 }
      {
        # Single-line object with empty hooks — drop it
        if ($0 ~ /\{[^}]*"hooks"[[:space:]]*:[[:space:]]*\[\][^}]*\}/) {
          next
        }
        if (skip) {
          buf[++buf_n] = $0
          for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") brace++
            if (c == "}") brace--
          }
          if (brace == 0) {
            # Check if this buffered object has "hooks": []
            has_empty = 0
            for (b = 1; b <= buf_n; b++) {
              if (buf[b] ~ /"hooks"[[:space:]]*:[[:space:]]*\[\]/) has_empty = 1
            }
            if (!has_empty) {
              for (b = 1; b <= buf_n; b++) out[++n] = buf[b]
            }
            skip = 0
            buf_n = 0
          }
          next
        }
        if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
          skip = 1
          brace = 1
          buf_n = 1
          buf[1] = $0
          next
        }
        out[++n] = $0
      }
      END {
        if (skip) { for (b = 1; b <= buf_n; b++) out[++n] = buf[b] }
        # Fix trailing commas before ] or }
        for (i = 1; i <= n; i++) {
          if (out[i] ~ /^[[:space:]]*[\]}]/ && i > 1) sub(/,[[:space:]]*$/, "", out[i-1])
        }
        # Remove empty event arrays: "EventName": [\n  ]
        for (i = 1; i <= n; i++) {
          if (i < n && out[i] ~ /"[^"]*"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/ && out[i+1] ~ /^[[:space:]]*\][,]?[[:space:]]*$/) {
            out[i] = ""
            out[i+1] = ""
          }
        }
        # Fix trailing commas again after removals
        m = 0
        for (i = 1; i <= n; i++) {
          if (out[i] != "") final[++m] = out[i]
        }
        for (i = 1; i <= m; i++) {
          if (final[i] ~ /^[[:space:]]*[\]}]/ && i > 1) sub(/,[[:space:]]*$/, "", final[i-1])
        }
        for (i = 1; i <= m; i++) print final[i]
      }
    ' "$settings" > "$prune_tmp"

    # If the file now has no real content, collapse to {}
    local content
    content="$(tr -d '[:space:]' < "$prune_tmp")"
    if [ "$content" = "{\"hooks\":{}}" ] || [ "$content" = "{}" ] || [ -z "$content" ]; then
      printf '{}' > "$prune_tmp"
      pruned=1
    elif ! grep -q '"command"' "$prune_tmp" 2>/dev/null && ! grep -q '"hooks"' "$prune_tmp" 2>/dev/null; then
      printf '{}' > "$prune_tmp"
      pruned=1
    fi

    mv "$prune_tmp" "$settings"
  fi

  if [ "$removed" -gt 0 ]; then
    echo "  [removed]  $removed Claude hook(s)"
  elif [ "$pruned" -eq 1 ]; then
    echo "  [cleaned]  removed leftover empty hook skeleton"
  else
    echo "  [ok]     no canon Claude hooks found"
  fi
}

_uninstall_pi() {
  local ext_dst="$HOME/.pi/agent/extensions/handoff.ts"
  if [ ! -f "$ext_dst" ]; then
    echo "  [skip]  Pi handoff extension not found"
    return 0
  fi
  if grep -q 'install_path' "$ext_dst" && grep -q 'auto-handoff.sh' "$ext_dst"; then
    rm -f "$ext_dst"
    echo "  [removed]  Pi handoff extension"
  else
    echo "  [warn]  Pi handoff extension did not look canon-managed; skipped"
  fi
}

_uninstall_install_path() {
  local config="$HOME/.config/canon/install_path"
  local projects="$HOME/.config/canon/projects"
  if [ ! -f "$config" ]; then
    echo "  [skip]  ~/.config/canon/install_path not found"
  else
    local installed
    installed="$(cat "$config")"
    if [ "$installed" = "$SKILLS_ROOT" ]; then
      rm -f "$config"
      echo "  [removed]  install_path"
    else
      echo "  [warn]  install_path points at $installed; expected $SKILLS_ROOT"
    fi
  fi
  if [ -f "$projects" ]; then
    rm -f "$projects"
    echo "  [removed]  projects"
  fi
  rmdir "$HOME/.config/canon" 2>/dev/null || true
}
