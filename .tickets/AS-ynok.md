---
id: AS-ynok
status: closed
deps: []
links: []
created: 2026-04-22T14:40:11Z
type: task
priority: 1
assignee: Sunit Joshi
---
# Make RTK optional in agent init stage

init-agent.sh hard-gates on RTK presence. Make it optional: detect RTK, wire-hook if present, warn, and skip if absent. Add OS-aware install hint (macOS vs WSL).
