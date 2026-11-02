#!/usr/bin/env bash
# handoff-recent (t-2db7) — the Recent activity block goes only into the MAIN checkout's HANDOFF.md, whichever checkout a command
# runs in (a branch carrying it would conflict at every merge); an older board without `recent` is never asked; `sprint recent
# --strip-handoff` takes the block out and leaves the narrative byte-identical. Prod path: tools/platform-lib.sh handoff_recent,
# called by sprint approve/complete and tkt merge-pr/land; `sprint recent`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
use_fresh_board "$W/board"
export HOME="$W/home" CANON_HOME="$W/canon-home" XDG_CONFIG_HOME="$W/xdg" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
M="$W/app"; mkdir -p "$M"; M="$(cd -P "$M" && pwd -P)"; git -C "$M" init -q -b main
printf '# Handoff\n\n<!-- canon:handoff:BEGIN -->\n## Current Focus\nmine\n<!-- canon:handoff:END -->\n' > "$M/HANDOFF.md"
git -C "$M" add HANDOFF.md && git -C "$M" commit -qm base
WT="$W/app-worktrees/feat-x"; git -C "$M" worktree add -q "$WT" -b feat-x
lib() { ( source "$ROOT/tools/platform-lib.sh"; "$@" ); }

# an event from the worktree, then the refresh run from inside it: main's HANDOFF.md gets the block, the worktree's copy does not
"$SPRINT_CHECK_BIN" event plan.approved --project "$(cd -P "$WT" && pwd -P)" --source sprint ticket=t-aaaa tier=normal
(cd "$WT" && lib handoff_recent "$WT")
assert_grep '· t-aaaa · plan approved \(normal\)$' "$M/HANDOFF.md"
assert_count 0 'canon:recent' "$WT/HANDOFF.md"
[[ -z "$(git -C "$WT" status --porcelain)" ]] || fail "the worktree changed: $(git -C "$WT" status --porcelain)"
assert_eq "$(lib main_checkout "$WT")" "$M"

# an older board (no `recent` in --help) is never asked: it would take the word for a port and serve
mkdir -p "$W/stub"; printf '#!/usr/bin/env bash\ncase "$1" in --help) echo "  caps [--json]";; *) touch "%s/served"; exit 9;; esac\n' "$W" > "$W/stub/old"; chmod +x "$W/stub/old"
before="$(cat "$M/HANDOFF.md")"
SPRINT_CHECK_BIN="$W/stub/old" lib handoff_recent "$WT"; rc=$?
assert_eq 0 "$rc"; [[ ! -e "$W/served" ]] || fail "an older board was asked for recent"; assert_eq "$before" "$(cat "$M/HANDOFF.md")"

# no HANDOFF.md: nothing created; outside git: nothing done
N="$W/bare"; mkdir -p "$N"; git -C "$N" init -q; lib handoff_recent "$N"; [[ ! -e "$N/HANDOFF.md" ]] || fail "a HANDOFF.md was created"
lib handoff_recent "$W/stub"

# sprint recent prints the list; --strip-handoff gives back the narrative byte-identical
cd "$M"; mkdir -p .tickets
assert_contains "$("$SPRINT" recent)" "· t-aaaa · plan approved (normal)"
"$SPRINT" recent --strip-handoff >/dev/null
assert_eq "$(git -C "$M" show HEAD:HANDOFF.md)" "$(cat "$M/HANDOFF.md")"
[[ -z "$(git -C "$M" status --porcelain HANDOFF.md)" ]] || fail "strip left a change"

echo "handoff-recent: ok"
