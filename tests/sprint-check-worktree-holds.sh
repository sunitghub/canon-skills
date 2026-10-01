#!/usr/bin/env bash
# sprint-check-worktree-holds (t-2241) — /api/worktrees marks which worktrees
# another ticket still needs (`held_by`), identically in server.py and main.go,
# and never hides the requesting ticket's own worktree (`own`). One fresh repo
# with a worktree per state: bound + in progress, reserved by an open ticket's
# preference, dirty, unmerged, runtime-noise-only, and free. Also checks the
# footer signal `branch_divergence.dirty`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-worktree-holds: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
GO_BIN=""
PIDS=()
TMP="$(mktemp -d)"
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
  [[ -n "${GO_LAYOUT:-}" ]] && rm -rf "$GO_LAYOUT"
  return 0
}
trap cleanup EXIT

if command -v go >/dev/null 2>&1; then
  # Built into a miniature install (tools/ + skills beside it) because the Go backend finds the skills
  # it links into new worktrees (t-07a8) relative to its own tools/ directory.
  GO_LAYOUT="$(mktemp -d)"
  mkdir -p "$GO_LAYOUT/tools"
  ln -s "$ROOT/skills" "$GO_LAYOUT/skills"; ln -s "$ROOT/tools/sprint-check-app" "$GO_LAYOUT/tools/sprint-check-app"
  GO_BIN="$GO_LAYOUT/tools/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

ticket() { # dir id status [preference]
  mkdir -p "$1/.tickets/$2"
  { printf -- '---\nid: %s\nstatus: %s\ntype: task\npriority: 2\n' "$2" "$3"
    [[ -n "${4:-}" ]] && printf 'worktree_preference: %s\n' "$4"
    printf -- '---\n# %s\n' "$2"; } > "$1/.tickets/$2/ticket.md"
}

REPO="$TMP/proj"; WT="$TMP/proj-worktrees"
mkdir -p "$REPO" "$WT"
git -C "$REPO" init -q -b master
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf '.cockpit-*\nACTIVE\n' > "$REPO/.tickets.gitignore.tmp"
mkdir -p "$REPO/.tickets" && mv "$REPO/.tickets.gitignore.tmp" "$REPO/.tickets/.gitignore"
ticket "$REPO" t-bnd1 open               # bound; open on main, in progress in its worktree
ticket "$REPO" t-res1 open sprint/res    # open, reserved sprint/res
ticket "$REPO" t-cls1 closed             # closed, bound to the dirty worktree
ticket "$REPO" t-mine open sprint/mine   # the requester in the own-view checks
ticket "$REPO" t-want open sprint/bnd    # prefers a branch another ticket is running in
echo a > "$REPO/a.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
for b in bnd res dirty unmerged noise free mine gone lnk jnc cfg extra trk; do git -C "$REPO" worktree add -q -b "sprint/$b" "$WT/$b"; done
rm -rf "$WT/gone"                                                       # deleted folder: git lists it as prunable
# t-07a8: canon links its skills into every new worktree (.agents/skills, .claude/skills); a project that does
# not gitignore them sees them untracked. lnk = real symlinks, jnc = real dirs with files (what a Windows
# junction lists under --untracked-files=all). Both are canon's own and must stay free. The next three are
# real work that must STILL hold the worktree: a notes file next to the links, a lookalike dir, and a
# tracked file under .claude/skills that was then modified.
mkdir -p "$WT/lnk/.agents" "$WT/lnk/.claude"
ln -s "$ROOT/skills" "$WT/lnk/.agents/skills"; ln -s "$ROOT/skills" "$WT/lnk/.claude/skills"
mkdir -p "$WT/jnc/.agents/skills/x" "$WT/jnc/.claude/skills/x"
echo s > "$WT/jnc/.agents/skills/x/SKILL.md"; echo s > "$WT/jnc/.claude/skills/x/SKILL.md"
mkdir -p "$WT/cfg/.claude"; echo n > "$WT/cfg/.claude/notes.md"
mkdir -p "$WT/extra/.claude/skills-extra"; echo x > "$WT/extra/.claude/skills-extra/x"
mkdir -p "$WT/trk/.claude/skills/t"; echo v1 > "$WT/trk/.claude/skills/t/SKILL.md"
git -C "$WT/trk" add .claude/skills/t/SKILL.md; git -C "$WT/trk" commit -q -m trk; echo v2 > "$WT/trk/.claude/skills/t/SKILL.md"
# Bindings: the daemon writes the absolute worktree path into the main checkout's lock file.
echo "$WT/bnd" > "$REPO/.tickets/t-bnd1/.cockpit-cwd"
echo "$WT/dirty" > "$REPO/.tickets/t-cls1/.cockpit-cwd"
echo work > "$WT/dirty/wip.txt"                                        # uncommitted work
echo c > "$WT/unmerged/c.txt"; git -C "$WT/unmerged" add c.txt; git -C "$WT/unmerged" commit -q -m c   # unmerged commit
echo log > "$WT/noise/.tickets/t-bnd1/cockpit-sessions.md"             # runtime noise only
echo x > "$WT/noise/.tickets/t-bnd1/.cockpit-agent"
# The running sprint's uncommitted edits: in_progress in the worktree copy only
# (the VM case where the footer wrongly said "branch merged").
sed -i.bak 's/^status: open$/status: in_progress/' "$WT/bnd/.tickets/t-bnd1/ticket.md" && rm -f "$WT/bnd/.tickets/t-bnd1/ticket.md.bak"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

run_checks() {
  local kind="$1" label="$2" port base
  port="$(free_port)"
  if [[ "$kind" == py ]]; then
    SPRINT_CHECK_ROOT="$REPO" CANON_HOME="$TMP/$kind-canon" COCKPIT_STATE_DIR="$TMP/$kind-ck" COCKPIT_DAEMON_BIN=/usr/bin/false \
      python3 "$SERVER_PY" "$port" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$REPO" CANON_HOME="$TMP/$kind-canon" COCKPIT_STATE_DIR="$TMP/$kind-ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_NO_BROWSER=1 \
      "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!"); disown "$!" 2>/dev/null || true
  base="http://127.0.0.1:$port"
  for _ in $(seq 1 50); do curl -s -o /dev/null "$base/api/git" && break; sleep 0.1; done

  python3 - "$label" "$(curl -s "$base/api/worktrees")" "$(curl -s "$base/api/worktrees?ticket=t-mine")" "$(curl -s "$base/api/worktrees?ticket=t-bnd1")" "$(curl -s "$base/api/worktrees?ticket=t-want")" <<'EOF'
import json, sys
label, anon, mine, bnd, want_view = sys.argv[1], *[json.loads(a) for a in sys.argv[2:]]
def by_branch(lst): return {e.get('branch'): e for e in lst if not e.get('is_main')}
a = by_branch(anon)
want = {
  'sprint/bnd':      {'ticket': 't-bnd1', 'reason': 'in progress'},
  'sprint/res':      {'ticket': 't-res1', 'reason': 'reserved'},
  'sprint/dirty':    {'ticket': 't-cls1', 'reason': 'uncommitted changes'},
  'sprint/unmerged': {'ticket': '',       'reason': 'branch not merged'},
  'sprint/mine':     {'ticket': 't-mine', 'reason': 'reserved'},
  'sprint/gone':     {'ticket': '',       'reason': 'folder missing'},
  'sprint/cfg':      {'ticket': '',       'reason': 'uncommitted changes'},
  'sprint/extra':    {'ticket': '',       'reason': 'uncommitted changes'},
  'sprint/trk':      {'ticket': '',       'reason': 'uncommitted changes'},
}
for br, hb in want.items():
    assert a[br].get('held_by') == hb, f'{label}: {br} held_by {a[br].get("held_by")} != {hb}'
for br in ('sprint/noise', 'sprint/free', 'sprint/lnk', 'sprint/jnc'):
    assert 'held_by' not in a[br], f'{label}: {br} should be free, got {a[br].get("held_by")}'
assert not any(e.get('own') for e in anon), f'{label}: no ticket given, nothing is own'
m = by_branch(mine)
assert m['sprint/mine'].get('own') is True and 'held_by' not in m['sprint/mine'], f'{label}: t-mine must see sprint/mine as own: {m["sprint/mine"]}'
assert m['sprint/bnd'].get('held_by') == want['sprint/bnd'], f'{label}: other holds unchanged for t-mine'
b = by_branch(bnd)
assert b['sprint/bnd'].get('own') is True and 'held_by' not in b['sprint/bnd'], f'{label}: the bound ticket must see its worktree as own: {b["sprint/bnd"]}'
w = by_branch(want_view)
assert 'own' not in w['sprint/bnd'] and w['sprint/bnd'].get('held_by') == want['sprint/bnd'], f'{label}: a preference must not claim a worktree another ticket is running in: {w["sprint/bnd"]}'
EOF

  # Footer signal: t-bnd1 is in_progress only in its worktree's uncommitted copy → dirty.
  python3 - "$label" "$(curl -s "$base/api/tickets")" <<'EOF'
import json, sys
label, tickets = sys.argv[1], json.loads(sys.argv[2])
t = next((t for t in tickets if t.get('id') == 't-bnd1'), None)
d = (t or {}).get('branch_divergence') or {}
assert d.get('where') == 'worktree' and d.get('status') == 'in_progress', f'{label}: expected worktree divergence, got {d}'
assert d.get('dirty') is True, f'{label}: branch_divergence.dirty must be true for uncommitted worktree edits, got {d}'
EOF
  # t-07a8: end to end — a worktree created through the API with a custom (non sprint/<ticket-id>) name gets the
  # skill links, and must be offered, not hidden as "uncommitted changes" the moment it exists.
  local nb="sprint/custom-$kind"
  curl -s -X POST -H 'Content-Type: application/json' -d "{\"branch\":\"$nb\"}" "$base/api/worktrees" | grep -q '"ok": *true' \
    || fail "$label: creating $nb through the API failed"
  [[ -e "$WT/sprint-custom-$kind/.claude/skills" ]] || fail "$label: the created worktree got no .claude/skills link (the premise of this check)"
  python3 - "$label" "$nb" "$(curl -s "$base/api/worktrees?ticket=t-mine")" <<'EOF'
import json, sys
label, nb, lst = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
e = next((e for e in lst if e.get('branch') == nb), None)
assert e is not None, f'{label}: {nb} missing from /api/worktrees'
assert 'held_by' not in e, f'{label}: a freshly created {nb} must be offered, got held_by {e.get("held_by")}'
EOF
  echo "  $label: worktree holds ok"
}

run_checks py server.py
if [[ -n "$GO_BIN" ]]; then
  run_checks go main.go
else
  echo "  main.go: go absent — Go half skipped"
fi
echo "sprint-check-worktree-holds: ok"
