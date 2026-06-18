#!/usr/bin/env bash
# auto-handoff.sh — Safety-net HANDOFF.md update from observable git state.
# Called by the Claude Code Stop hook. Maintains a FIFO window of the last
# 2 snapshots: append newest, prune oldest.
# Safe to run frequently — skips silently when working tree is clean.

set -euo pipefail

MAX_SNAPSHOTS=2

# Derive tkt path from this canon installation — no PATH dependency.
# Hooks are registered with absolute paths, so BASH_SOURCE[0] is always the real file.
CANON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TKT_BIN="$CANON_ROOT/tools/tkt"
[ -f "$TKT_BIN" ] || TKT_BIN=$(command -v tkt 2>/dev/null || command -v tk 2>/dev/null || true)

# Must be inside a git repo — anchor HANDOFF.md to the git root, not cwd.
# cwd can drift when Claude's Bash shell retains a cd from a prior tool call.
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

HANDOFF="$GIT_ROOT/HANDOFF.md"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
MODIFIED=$(git status --short 2>/dev/null)

# Nothing uncommitted — nothing worth capturing
[ -z "$MODIFIED" ] && exit 0

RECENT_COMMITS=$(git log --oneline -5 2>/dev/null || echo "none")

TICKETS=""
if [ -n "$TKT_BIN" ]; then
  TICKETS=$("$TKT_BIN" ls --status=in_progress 2>/dev/null | head -10 || true)
fi

# Build the new snapshot block
NEW_SNAPSHOT="<!-- HANDOFF-SNAPSHOT:START ${TIMESTAMP} branch:${BRANCH} -->
**Modified files:**
\`\`\`
${MODIFIED}
\`\`\`

**Recent commits:**
\`\`\`
${RECENT_COMMITS}
\`\`\`"

if [ -n "$TICKETS" ]; then
  NEW_SNAPSHOT="${NEW_SNAPSHOT}

**In-progress tickets:**
\`\`\`
${TICKETS}
\`\`\`"
fi

NEW_SNAPSHOT="${NEW_SNAPSHOT}

**Convention check:** Did this session introduce any patterns, naming norms, or gotchas worth adding to \`AGENTS.md\`? If yes, propose the addition before ending.
<!-- HANDOFF-SNAPSHOT:END -->"

if [ -f "$HANDOFF" ] && command -v python3 &>/dev/null; then
  python3 - "$HANDOFF" "$MAX_SNAPSHOTS" "$NEW_SNAPSHOT" << 'PYEOF'
import sys, re

path, max_snap, new_snap = sys.argv[1], int(sys.argv[2]), sys.argv[3]

content = open(path).read()

# Split human content from snapshot blocks
marker = '<!-- HANDOFF-SNAPSHOT:START'
split = content.find(marker)
human = content[:split].rstrip() if split != -1 else content.rstrip()

# Extract existing snapshot blocks in file order.
blocks = re.findall(
    r'<!-- HANDOFF-SNAPSHOT:START.*?<!-- HANDOFF-SNAPSHOT:END -->',
    content, re.DOTALL
)

# FIFO: append newest, prune oldest.
all_snapshots = (blocks + [new_snap])[-max_snap:]

result = human + '\n\n' + '\n\n'.join(all_snapshots) + '\n'
open(path, 'w').write(result)
PYEOF

else
  cat > "$HANDOFF" << EOF
# Handoff

_Auto-created: $TIMESTAMP | Branch: ${BRANCH}_

## Current Focus
<!-- One sentence: what were you working on? Fill this in. -->

## In Progress
$([ -n "$TICKETS" ] && echo "$TICKETS" || echo "- (run \`${TKT_BIN:-tkt} ls --status=in_progress\` to check)")

## Dead Ends
-

## Next Steps
1.

${NEW_SNAPSHOT}
EOF
fi

# Commit just HANDOFF.md — --only scopes the commit to this path so any files the
# user already staged are left untouched. Gracefully skip if HANDOFF is gitignored,
# the commit is blocked, or there is nothing to commit.
git add "$HANDOFF" 2>/dev/null || true
git commit --only "$HANDOFF" -m "chore: auto-update handoff snapshot [$TIMESTAMP]" 2>/dev/null || true

echo "[handoff] Snapshot saved → HANDOFF.md (FIFO, keeping last ${MAX_SNAPSHOTS})"
