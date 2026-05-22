#!/bin/bash
# Claude Code statusline: Context % | 5h: % (reset) | 7d: % (reset)
exec 2>/dev/null

# If run interactively (not piped), offer to install
if [ -t 0 ]; then
  DEST="$HOME/.claude/statusline.sh"
  SETTINGS="$HOME/.claude/settings.json"
  printf "Install statusline → %s and wire %s? [y/N] " "$DEST" "$SETTINGS"
  read -r answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    mkdir -p "$(dirname "$DEST")"
    cp "${BASH_SOURCE[0]}" "$DEST"
    chmod +x "$DEST"
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
data["statusLine"] = {"type": "command", "command": "bash ~/.claude/statusline.sh"}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    printf "Done. Restart Claude Code to see the statusline.\n"
  fi
  exit 0
fi

CACHE_DIR="$HOME/.cache/canon-statusline"
CACHE_FILE="$CACHE_DIR/last.json"
CACHE_MAX_AGE=21600  # 6 hours: one full rate_limit window

input=$(cat)

tab=$(printf '\t')

jq_full='[
  ((.context_window.current_usage.input_tokens // 0)
   + (.context_window.current_usage.cache_creation_input_tokens // 0)
   + (.context_window.current_usage.cache_read_input_tokens // 0) | tostring),
  (.context_window.context_window_size // 0 | tostring),
  (.rate_limits.five_hour.used_percentage // null | if . then (. | round | tostring) else "null" end),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.used_percentage // null | if . then (. | round | tostring) else "null" end),
  (.rate_limits.seven_day.resets_at // "" | tostring),
  (.cwd // "" | tostring),
  (.model.display_name // "" | tostring)
] | @tsv'

jq_rl='[
  (.rate_limits.five_hour.used_percentage // null | if . then (. | round | tostring) else "null" end),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.used_percentage // null | if . then (. | round | tostring) else "null" end),
  (.rate_limits.seven_day.resets_at // "" | tostring)
] | @tsv'

# Single jq pass for live input
parsed=""
[ -n "$input" ] && parsed=$(printf '%s' "$input" | jq -r "$jq_full" 2>/dev/null)

IFS="$tab" read -r used_tokens window_size five_pct five_reset seven_pct seven_reset cwd_raw model_name <<EOF
$parsed
EOF

# If rate_limits missing from live input, read from cache
if [ "$five_pct" = "null" ] || [ -z "$five_pct" ]; then
  if [ -f "$CACHE_FILE" ]; then
    cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
    cache_age=$(( $(date +%s) - cache_mtime ))
    if [ "$cache_age" -lt "$CACHE_MAX_AGE" ]; then
      cached=$(jq -r "$jq_rl" "$CACHE_FILE" 2>/dev/null)
      IFS="$tab" read -r five_pct five_reset seven_pct seven_reset <<EOF
$cached
EOF
    fi
  fi
fi

# Persist rate_limits when present (atomic write)
if [ "$five_pct" != "null" ] && [ -n "$five_pct" ] && [ -n "$input" ]; then
  mkdir -p "$CACHE_DIR"
  printf '%s' "$input" | jq '{rate_limits: .rate_limits}' \
    > "${CACHE_FILE}.tmp" 2>/dev/null \
    && mv "${CACHE_FILE}.tmp" "$CACHE_FILE" 2>/dev/null \
    || true
fi

# --- Colors ---
RESET="\033[0m"
DIM="\033[2m"
LABEL="\033[1;37m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[94m"
MAGENTA="\033[95m"

# Format seconds remaining as "4h23m" or "1d21h"
format_reset() {
  local ts="$1"
  [ -z "$ts" ] && return
  local epoch now diff
  epoch=$(printf '%s' "$ts" | tr -dc '0-9')
  [ -z "$epoch" ] && return
  now=$(date +%s)
  diff=$((epoch - now))
  [ "$diff" -le 0 ] && return
  local mins=$(( diff / 60 ))
  local hours=$(( mins / 60 ))
  local days=$(( hours / 24 ))
  if [ "$days" -ge 1 ]; then
    printf "%dd%dh" "$days" $(( hours % 24 ))
  elif [ "$hours" -ge 1 ]; then
    printf "%dh%dm" "$hours" $(( mins % 60 ))
  else
    printf "%dm" "$mins"
  fi
}

# CWD: last two path segments
if [ -n "$cwd_raw" ]; then
  parent=$(basename "$(dirname "$cwd_raw")")
  leaf=$(basename "$cwd_raw")
  if [ "$parent" = "." ] || [ "$parent" = "/" ] || [ -z "$parent" ]; then
    cwd_display="$leaf"
  else
    cwd_display="${parent}/${leaf}"
  fi
  cwd_part="${LABEL}CWD:${RESET} ${GREEN}${cwd_display}${RESET}"
else
  cwd_part=""
fi

# Model
if [ -n "$model_name" ]; then
  model_part="${LABEL}Model:${RESET} ${YELLOW}${model_name}${RESET}"
else
  model_part=""
fi

# Context %
ctx_pct=0
if [ "$window_size" -gt 0 ] 2>/dev/null; then
  ctx_pct=$(awk -v u="${used_tokens:-0}" -v t="$window_size" 'BEGIN { printf "%d", (u/t)*100 }')
fi
if [ "$ctx_pct" -ge 85 ] 2>/dev/null; then
  ctx_color="$RED"
elif [ "$ctx_pct" -ge 70 ] 2>/dev/null; then
  ctx_color="$YELLOW"
else
  ctx_color="$GREEN"
fi
context_part="${LABEL}Ctx:${RESET} ${ctx_color}${ctx_pct}%${RESET}"

# Usage color
usage_color() {
  local pct="$1"
  if [ "$pct" -ge 90 ] 2>/dev/null; then printf "%s" "$RED"
  elif [ "$pct" -ge 70 ] 2>/dev/null; then printf "%s" "$MAGENTA"
  else printf "%s" "$BLUE"
  fi
}

# 5h part
if [ "$five_pct" != "null" ] && [ -n "$five_pct" ]; then
  color=$(usage_color "$five_pct")
  reset_str=$(format_reset "$five_reset")
  if [ -n "$reset_str" ]; then
    five_part="${LABEL}5h:${RESET} ${color}${five_pct}%${RESET} ${DIM}(${reset_str})${RESET}"
  else
    five_part="${LABEL}5h:${RESET} ${color}${five_pct}%${RESET}"
  fi
else
  five_part="${LABEL}5h:${RESET}${DIM} --${RESET}"
fi

# 7d part
if [ "$seven_pct" != "null" ] && [ -n "$seven_pct" ]; then
  color=$(usage_color "$seven_pct")
  reset_str=$(format_reset "$seven_reset")
  if [ -n "$reset_str" ]; then
    seven_part="${LABEL}7d:${RESET} ${color}${seven_pct}%${RESET} ${DIM}(${reset_str})${RESET}"
  else
    seven_part="${LABEL}7d:${RESET} ${color}${seven_pct}%${RESET}"
  fi
else
  seven_part="${LABEL}7d:${RESET}${DIM} --${RESET}"
fi

prefix=""
[ -n "$cwd_part" ] && prefix="${cwd_part}"
[ -n "$model_part" ] && prefix="${prefix:+${prefix} | }${model_part}"
[ -n "$prefix" ] && prefix="${prefix} | "

printf "%b%b | %b | %b\n" "$prefix" "$context_part" "$five_part" "$seven_part"
