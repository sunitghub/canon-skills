#!/bin/bash
# Checks that all plugins listed in installed_plugins.json have their files on disk.
# Runs as a Stop hook — warns cleanly, never fails noisily.

PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"

[[ -f "$PLUGINS_JSON" ]] || exit 0

missing=()

while IFS='|' read -r name path; do
  [[ -d "$path" ]] || missing+=("$name")
done < <(python3 -c "
import json, sys
data = json.load(open('$PLUGINS_JSON'))
for name, installs in data['plugins'].items():
    for i in installs:
        print(f'{name}|{i[\"installPath\"]}')
")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "⚠ Missing plugin files (run /plugin install to fix):"
  for p in "${missing[@]}"; do
    echo "  - $p"
  done
fi

exit 0
