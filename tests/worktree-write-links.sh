#!/usr/bin/env bash
# t-f7e6: in a linked worktree a branch or cloud PR controls the tree, so a link it plants at .tickets, .tickets/<id>, .claude, or a
# file canon writes must not carry the write out of the project. Protects every bash writer into a worktree's .tickets/ and .claude/
# (tkt, sprint, the gate scripts, work-beat; the Cockpit's and tkt land's worktrees): each refuses with one line, and nothing outside
# changes or appears. A main checkout's own links keep working (user, 2026-11-15: worktrees only).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(command mktemp -d "${TMPDIR:-/tmp}/wt-write-links.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
git config --global init.defaultBranch main; git config --global user.name t; git config --global user.email t@e

# A project that tracks .tickets/: its worktree has its own real copy, the layout where .tickets and .claude are written in the worktree.
P="$W/project"; mkdir -p "$P"; cd "$P"; git init -q
echo base > f.txt; git add f.txt; git commit -qm base
id="$("$TKT" create "Planted" -t task)"
printf '# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved\n\n## Approach\nx\n' > ".tickets/$id/plan.md"
git add -f .tickets; git commit -qm "chore: ticket"
WT="$W/wt"; git worktree add -q "$WT" -b feat/w
OUT="$W/out"; mkdir -p "$OUT/t-dir"; git -C "$OUT" init -q   # outside the project, a git repository of its own
cp -R "$WT/.tickets/$id/." "$OUT/t-dir/"; cp -R "$WT/.tickets/." "$OUT/"; echo outside > "$OUT/file.txt"
outsig() { (cd "$OUT" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do [[ -f "$f" ]] && cksum < "$f" | tr '\n' ' '; echo "$f"; done); }
reset_wt() { git -C "$WT" checkout -qf feat/w -- . 2>/dev/null; git -C "$WT" reset -q --hard; git -C "$WT" clean -qfdx; rm -rf "$WT/.claude"; }
link() { rm -rf "${WT:?}/${1:?}"; ln -s "$2" "$WT/$1"; }

# planted <label> <expected exit> <plant command> -- <command run in the worktree...>: refuses with the line, outside unchanged, nothing new.
# An expected exit of "-": the command never reaches a write (tkt finds tickets with `find`, which does not enter a linked start folder;
# land and evidence stop at their own checks first), so only "nothing outside changed or appeared" is checked.
planted() {
  local label="$1" want="$2"; shift 2; local plant=()
  while [[ "$1" != -- ]]; do plant+=("$1"); shift; done; shift
  reset_wt; "${plant[@]}"
  local before rc=0 out; before="$(outsig)"
  out="$(cd "$WT" && "$@" 2>&1 < /dev/null)" || rc=$?
  if [[ "$want" != - ]]; then
    [[ "$rc" == "$want" ]] || fail "$label: exit $rc, want $want: $out"
    assert_contains "$out" "refusing to write"; assert_contains "$out" "t-f7e6"
  fi
  [[ "$(outsig)" == "$before" ]] || fail "$label: something outside the worktree changed: $out"
  [[ ! -e "$W/outnew" ]] || fail "$label: a file was created outside through a dangling link"
  echo "worktree-write-links: refused $label"
}
now() { "$@"; }
plan_ok() { printf '# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved\n\n## Approach\nx\n' > "$OUT/plan.md"; }

planted ".tickets linked out (set_field, ACTIVE)" - link .tickets "$OUT" -- "$TKT" start "$id"
mkdir -p "$OUT/$id"; cp -R "$OUT/t-dir/." "$OUT/$id/"
planted ".tickets/<id> linked out" - link ".tickets/$id" "$OUT/t-dir" -- "$TKT" start "$id"
planted "ticket.md linked out" - link ".tickets/$id/ticket.md" "$OUT/file.txt" -- "$TKT" start "$id"
planted "ticket.md.tmp dangling" 1 link ".tickets/$id/ticket.md.tmp" "$W/outnew" -- "$TKT" start "$id"
planted "ticket.md.tmp dangling (remove_field: demo off)" 1 link ".tickets/$id/ticket.md.tmp" "$W/outnew" -- "$TKT" demo "$id" off
planted "ticket.md.tmp dangling (set_or_add_field: demo on)" 1 link ".tickets/$id/ticket.md.tmp" "$W/outnew" -- "$TKT" demo "$id" on
planted "ACTIVE linked out" 1 link ".tickets/ACTIVE" "$OUT/file.txt" -- "$TKT" start "$id"
planted ".gitignore seed dangling (ensure_tickets_dir)" 1 link ".tickets/.gitignore" "$W/outnew" -- "$TKT" create "Another" -t task
planted "create under a linked .tickets" 1 link .tickets "$OUT" -- "$TKT" create "Another" -t task
planted ".cockpit-cwd marker linked out" - link ".tickets/$id/.cockpit-cwd" "$OUT/file.txt" -- "$TKT" land "$id" --pr 7
plan_ok
planted ".cockpit-cwd dangling (tkt start binds the worktree)" 1 link ".tickets/$id/.cockpit-cwd" "$W/outnew" -- "$TKT" start "$id"
planted "learnings.md dangling (tkt learn)" 1 now sh -c "printf '# Summary\n| a | delivered | b |\n' > '$WT/.tickets/$id/summary.md'; ln -s '$W/outnew' '$WT/.tickets/$id/learnings.md'" -- "$TKT" learn "$id"
planted "plan.md dangling (sprint start)" 1 now sh -c "rm '$WT/.tickets/$id/plan.md'; ln -s '$W/outnew' '$WT/.tickets/$id/plan.md'" -- "$SPRINT" start "$id"
mkdir -p "$W/oldt/t-0ld1/evidence"; printf -- '---\nid: t-0ld1\nstatus: closed\n---\n# old\n' > "$W/oldt/t-0ld1/ticket.md"
echo r > "$W/oldt/t-0ld1/evidence/board-spec-chromium-run1.json"; touch -t 202501010000 "$W/oldt/t-0ld1/ticket.md"
planted "compact under a linked .tickets (reviewer: it deleted outside files)" 1 link .tickets "$W/oldt" -- "$TKT" compact --older-than 1
[[ -f "$W/oldt/t-0ld1/evidence/board-spec-chromium-run1.json" ]] || fail "compact deleted an outside evidence file"
planted "plan.md linked out (sprint approve)" 1 link ".tickets/$id/plan.md" "$OUT/plan.md" -- "$SPRINT" approve "$id"
printf 'evaluator-run-id: 1-1\ngraded-head: x\n## Verdict\nfail: no\n' > "$OUT/eval.md"
planted "ticket.md linked out (sprint eval-verdict)" 1 now sh -c "ln -sf '$OUT/eval.md' '$WT/.tickets/$id/eval-report.md'; rm '$WT/.tickets/$id/ticket.md'; ln -s '$OUT/file.txt' '$WT/.tickets/$id/ticket.md'" -- "$SPRINT" eval-verdict "$id"
planted "evidence stamp under a linked ticket folder" - link ".tickets/$id" "$OUT/t-dir" -- "$ROOT/tools/evidence.sh" stamp "$id" test-sh -- true
planted "gate snapshot under a linked ticket folder" 1 link ".tickets/$id" "$OUT/t-dir" -- "$ROOT/tools/gate-snapshot.sh" pre ".tickets/$id/gate-snapshot.txt"
planted ".claude linked out (subagent-log)" 1 link .claude "$OUT" -- "$ROOT/tools/subagent-log.sh" --agent-id a1 --agent-type reviewer --ticket "$id" --tokens 1 --minutes 1
planted "subagent-runs.jsonl linked out" 1 now sh -c "mkdir -p '$WT/.claude'; ln -s '$OUT/file.txt' '$WT/.claude/subagent-runs.jsonl'" -- "$ROOT/tools/subagent-log.sh" --agent-id a1 --agent-type reviewer --ticket "$id" --tokens 1 --minutes 1
planted "work-beat with a dangling ACTIVE.beat (best effort: exit 0)" 0 now sh -c "echo '$id' > '$WT/.tickets/ACTIVE'; ln -s '$W/outnew' '$WT/.tickets/ACTIVE.beat'" -- "$ROOT/tools/work-beat" touch
planted "evidence stamp under a linked .tickets" 125 link .tickets "$OUT" -- "$ROOT/tools/evidence.sh" stamp "$id" test-sh -- true
planted "work-beat under a linked .tickets (best effort: exit 0)" - link .tickets "$OUT" -- "$ROOT/tools/work-beat" touch

# The worktree reached through a symlinked path (a logical $PWD, as a shell opened through a link has): still refused, and outside unchanged
reset_wt; link .tickets "$OUT"; ln -sfn "$WT" "$W/wtlink"; before="$(outsig)"
rc=0; out="$(cd "$W/wtlink" && "$TKT" create "Through a link" -t task 2>&1)" || rc=$?
[[ "$rc" == 1 && "$(outsig)" == "$before" ]] || fail "a write from a logical path into the worktree went through (rc $rc): $out"
assert_contains "$out" "refusing to write"; rm "$W/wtlink"
echo "worktree-write-links: refused from a logical path to the worktree"
# Fail closed: a shell that loads only frontmatter-lib.sh still refuses (it loads platform-lib.sh itself).
reset_wt; link ".tickets/$id/ticket.md" "$OUT/file.txt"; before="$(outsig)"
rc=0; out="$(cd "$WT" && bash -c 'source "$1/tools/frontmatter-lib.sh"; set_field "$2" status closed' _ "$ROOT" ".tickets/$id/ticket.md" 2>&1)" || rc=$?
[[ "$rc" != 0 && "$(outsig)" == "$before" ]] || fail "frontmatter-lib.sh alone wrote through a planted link (rc $rc): $out"
echo "worktree-write-links: frontmatter-lib.sh alone refuses"
# ...and still writes a plain ticket in a main checkout: it loads platform-lib.sh itself, so the check is there, not missing (127)
rc=0; out="$(cd "$P" && bash -c 'source "$1/tools/frontmatter-lib.sh"; set_field "$2" priority 3' _ "$ROOT" ".tickets/$id/ticket.md" 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "frontmatter-lib.sh alone could not write a plain ticket (rc $rc): $out"; assert_grep '^priority: 3$' "$P/.tickets/$id/ticket.md"

# Still works: the same worktree with no links, CANON_TICKETS_DIR naming the main checkout's tickets, a main checkout whose .tickets
# is the person's own link, and a worktree without .tickets whose main .tickets is such a link.
reset_wt; (cd "$WT" && "$TKT" start "$id" >/dev/null) || fail "a plain worktree write was refused"
assert_grep '^status: in_progress$' "$WT/.tickets/$id/ticket.md"
reset_wt; (cd "$WT" && CANON_TICKETS_DIR="$P/.tickets" "$TKT" start "$id" >/dev/null) || fail "CANON_TICKETS_DIR naming main's tickets was refused"
M="$W/mine"; mkdir -p "$M/real-tickets"; git -C "$M" init -q; ln -s "$M/real-tickets" "$M/.tickets"
mid="$(cd "$M" && "$TKT" create "Mine" -t task)" || fail "a main checkout with its own linked .tickets was refused"
[[ -f "$M/real-tickets/$mid/ticket.md" ]] || fail "the main checkout's linked .tickets did not get the ticket"
U="$W/untracked"; mkdir -p "$U/real"; git -C "$U" init -q; (cd "$U" && echo b > b && git add b && git commit -qm b && printf '.tickets\n' > .gitignore)
ln -s "$U/real" "$U/.tickets"; uid="$(cd "$U" && "$TKT" create "U" -t task)"; git -C "$U" worktree add -q "$W/wtu" -b feat/u
# (create, not start: tkt's find does not enter a linked .tickets for reads, in a main checkout too: older than t-f7e6)
wid="$(cd "$W/wtu" && "$TKT" create "From the worktree" -t task)" || fail "a worktree writing to its main checkout's own linked .tickets was refused"
[[ -f "$U/real/$wid/ticket.md" && -n "$uid" ]] || fail "the worktree's write did not reach the main checkout's linked .tickets"
echo "worktree-write-links: plain worktree, CANON_TICKETS_DIR and the person's own links still work"

# A bare call under set -e at the worktree's top returns 0 for a plain path (git's empty --show-prefix line made read return 1 there)
reset_wt; r="$(cd "$WT" && bash -c 'set -e; source "$1/tools/platform-lib.sh"; wt_write_ok f.txt; echo passed' _ "$ROOT" 2>&1)" || true
assert_eq passed "$r"
# The PowerShell link checks take the path from the environment, never pasted into the command (a ' in a name ran as PowerShell).
! grep -rn "LiteralPath '\$(cygpath" "$ROOT/tools" || fail "a PowerShell link check pastes the path into its command again"
# One copy of the rule.
for fn in _is_dir_link _under_link _not_regular wt_write_ok; do
  n="$(grep -rhE "^${fn}\(\)" "$ROOT/tools" | wc -l | tr -d ' ')"; assert_eq 1 "$n"
done
echo "worktree-write-links: ok"
