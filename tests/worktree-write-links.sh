#!/usr/bin/env bash
# t-f7e6: in a linked worktree a branch or cloud PR controls the tree, so a link it plants at .tickets, .tickets/<id>, .claude, or a
# file canon writes must not carry the write out of the project. Protects every bash writer into a worktree's .tickets/ and .claude/
# (tkt, sprint, the gate scripts, work-beat; the Cockpit's and tkt land's worktrees): each refuses with one line, and nothing outside
# changes or appears. A main checkout's own links keep working (user, 2026-11-15: worktrees only).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(command mktemp -d "${TMPDIR:-/tmp}/wt-write-links.XXXXXX")" && pwd -P)"
# t-c206: the sweep runs gate-snapshot.sh pre ~80 times; unpinned, each scope went to the real /tmp registry (a parallel suite's
# uninstall, and the user's own canon update for 2 h, then refused) and its dir to the system temp folder (macOS `mktemp -d`
# ignores TMPDIR), so the trap removes every dir its own registry recorded and fails if one survives.
REG="$W/registry"; export CANON_GATE_SCOPE_DIR="$REG"
scope_cleanup() {
  local f d left=""
  for f in "$CANON_GATE_SCOPE_DIR"/*; do
    [[ -f "$f" ]] || continue
    d="$(sed -n 's/^dir=//p' "$f")"; [[ "$d" == /*/* ]] || continue
    rm -rf "$d"; [[ ! -e "$d" ]] || left+=" $d"
  done
  rm -rf "$W"
  [[ -z "$left" ]] || { echo "FAIL: worktree-write-links left gate scope dirs:$left" >&2; exit 1; }
}
trap scope_cleanup EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
unset CANON_TICKETS_DIR   # a stamp exports it (the checklist's recipe): the writers here must resolve the worktree's own tickets
git config --global init.defaultBranch main; git config --global user.name t; git config --global user.email t@e

# A project that tracks .tickets/: its worktree has its own real copy, the layout where .tickets and .claude are written in the worktree.
P="$W/project"; mkdir -p "$P"; cd "$P"; git init -q
echo base > f.txt; printf '# Handoff\n\n<!-- canon:handoff:BEGIN -->\n## Current Focus\nx\n<!-- canon:handoff:END -->\n' > HANDOFF.md
git add f.txt HANDOFF.md; git commit -qm base
id="$("$TKT" create "Planted" -t task)"
printf '# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved\n\n## Approach\nx\n' > ".tickets/$id/plan.md"
awk '/^---$/ && ++n == 2 { print "github: acme/app#21" } { print }' ".tickets/$id/ticket.md" > "$W/t.md" && mv "$W/t.md" ".tickets/$id/ticket.md"   # land needs it
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
# tkt land run inside this worktree (it tracks its own .tickets, so land's markers go into the worktree's ticket folder): a stub gh and
# an origin with the PR head; evaluator attempt 3 found these markers written through a planted link
git -C "$P" remote add origin https://github.com/acme/app.git; git init -q --bare "$W/origin.git"; git -C "$P" push -q "$W/origin.git" "HEAD:refs/pull/7/head"
PRH="$(git -C "$P" rev-parse HEAD)"; mkdir -p "$W/lbin"; REAL_GIT="$(type -P git)"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr view") printf "OPEN\\t%%s\\tfalse\\tMERGEABLE\\tmain\\n" "%s" ;; *) exit 9 ;; esac\n' "$PRH" > "$W/lbin/gh"
printf '#!/usr/bin/env bash\nif [[ " $* " == *" fetch "* ]]; then a=(); for x in "$@"; do [[ "$x" == origin ]] && x="%s"; a+=("$x"); done; set -- "${a[@]}"; fi\nexec "%s" "$@"\n' "$W/origin.git" "$REAL_GIT" > "$W/lbin/git"
chmod +x "$W/lbin/gh" "$W/lbin/git"
landrun() { PATH="$W/lbin:$PATH" "$TKT" land "$id" --pr 7; }
planted "tkt land's .land-head linked out" 1 link ".tickets/$id/.land-head" "$OUT/file.txt" -- landrun
planted "tkt land's .land-pr dangling" 1 link ".tickets/$id/.land-pr" "$W/outnew" -- landrun
planted "tkt land's .cockpit-cwd dangling" 1 link ".tickets/$id/.cockpit-cwd" "$W/outnew" -- landrun
planted "plan.md linked out (sprint approve)" 1 link ".tickets/$id/plan.md" "$OUT/plan.md" -- "$SPRINT" approve "$id"
printf 'evaluator-run-id: 1-1\ngraded-head: x\n## Verdict\nfail: no\n' > "$OUT/eval.md"
planted "ticket.md linked out (sprint eval-verdict)" 1 now sh -c "ln -sf '$OUT/eval.md' '$WT/.tickets/$id/eval-report.md'; rm '$WT/.tickets/$id/ticket.md'; ln -s '$OUT/file.txt' '$WT/.tickets/$id/ticket.md'" -- "$SPRINT" eval-verdict "$id"
planted "evidence stamp under a linked ticket folder" - link ".tickets/$id" "$OUT/t-dir" -- "$ROOT/tools/evidence.sh" stamp "$id" test-sh -- true
planted "gate snapshot under a linked ticket folder" 1 link ".tickets/$id" "$OUT/t-dir" -- "$ROOT/tools/gate-snapshot.sh" pre ".tickets/$id/gate-snapshot.txt"
planted ".claude linked out (subagent-log)" 1 link .claude "$OUT" -- "$ROOT/tools/subagent-log.sh" --agent-id a1 --agent-type reviewer --ticket "$id" --tokens 1 --minutes 1
planted "subagent-runs.jsonl linked out" 1 now sh -c "mkdir -p '$WT/.claude'; ln -s '$OUT/file.txt' '$WT/.claude/subagent-runs.jsonl'" -- "$ROOT/tools/subagent-log.sh" --agent-id a1 --agent-type reviewer --ticket "$id" --tokens 1 --minutes 1
planted "work-beat with a dangling ACTIVE.beat (best effort: exit 0)" 0 now sh -c "echo '$id' > '$WT/.tickets/ACTIVE'; ln -s '$W/outnew' '$WT/.tickets/ACTIVE.beat'" -- "$ROOT/tools/work-beat" touch
echo beat > "$OUT/ACTIVE.beat"
planted "work-beat clear under a linked .tickets (evaluator: it removed an outside file)" 0 link .tickets "$OUT" -- "$ROOT/tools/work-beat" clear
[[ -f "$OUT/ACTIVE.beat" ]] || fail "work-beat clear removed the outside ACTIVE.beat"
plan_ok; cp "$OUT/plan.md" "$W/plan.ok"
planted "the approve-time handoff marker linked out (sprint approve)" 0 now sh -c "cp '$W/plan.ok' '$WT/.tickets/$id/plan.md'; ln -s '$OUT/file.txt' '$WT/.tickets/$id/.cockpit-handoff-at-approve'" -- "$SPRINT" approve "$id"
planted "gate snapshot post removing a linked .scope" 0 now sh -c "cd '$WT' && '$ROOT/tools/gate-snapshot.sh' pre '.tickets/$id/gate-snapshot.txt' >/dev/null 2>&1; rm -f '$WT/.tickets/$id/gate-snapshot.txt.scope'; ln -s '$OUT/file.txt' '$WT/.tickets/$id/gate-snapshot.txt.scope'" -- "$ROOT/tools/gate-snapshot.sh" post ".tickets/$id/gate-snapshot.txt"
[[ -f "$OUT/file.txt" ]] || fail "gate-snapshot post removed an outside file"
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

# The sweep (evaluator, attempt 3: every writer must remember its guard, so each attempt found a new one): every writing command, run
# with each folder canon writes under planted as a link to an outside folder. A folder link catches a writer with no guard at all (or one
# that writes before its first guard); a second write after a guarded one is stopped by that guard's refusal first, so those are the
# planted file cases above (each found by an evaluator). The full name-by-name matrix (~460 runs, ~4 min) is too slow for the suite.
sweep_cmds=("$TKT start $id" "$TKT reopen $id" "$TKT demo $id on" "$TKT demo $id off" "$TKT manual $id on" "$TKT gate $id on" "$TKT tags $id add x"
  "$TKT learn $id" "$TKT compact --older-than 0" "$TKT create N -t task" "$SPRINT start $id" "$SPRINT approve $id" "$SPRINT eval-verdict $id"
  "$ROOT/tools/work-beat touch" "$ROOT/tools/work-beat clear" "$ROOT/tools/gate-snapshot.sh pre .tickets/$id/gate-snapshot.txt"
  "$ROOT/tools/gate-snapshot.sh post .tickets/$id/gate-snapshot.txt" "$ROOT/tools/evidence.sh stamp $id test-sh -- true"
  "$ROOT/tools/subagent-log.sh --agent-id a --agent-type reviewer --ticket $id --tokens 1 --minutes 1" landrun)
escaped=""; nsw=0
for d in .tickets ".tickets/$id" ".tickets/$id/evidence" .claude; do
  for c in "${sweep_cmds[@]}"; do
    reset_wt; mkdir -p "$WT/.tickets/$id/evidence" "$WT/.claude"; echo "$id" > "$WT/.tickets/ACTIVE"
    (cd "$WT" && "$ROOT/tools/gate-snapshot.sh" pre ".tickets/$id/gate-snapshot.txt" >/dev/null 2>&1) || true
    rm -rf "$OUT/swept"; mkdir -p "$OUT/swept"; cp -R "$WT/$d/." "$OUT/swept/" 2>/dev/null || true
    rm -rf "${WT:?}/${d:?}"; ln -s "$OUT/swept" "$WT/$d"; before="$(outsig)"
    (cd "$WT" && eval "$c" >/dev/null 2>&1 < /dev/null) || true
    nsw=$((nsw + 1)); [[ "$(outsig)" == "$before" ]] || escaped+="  $d linked: ${c#"$ROOT/tools/"}"$'\n'
  done
done
rm -rf "$OUT/swept"
[[ -z "$escaped" ]] || fail "these writes went outside the worktree through a planted folder link:"$'\n'"$escaped"
echo "worktree-write-links: sweep: $nsw runs, nothing outside changed"
# A bare call under set -e at the worktree's top returns 0 for a plain path (git's empty --show-prefix line made read return 1 there)
reset_wt; r="$(cd "$WT" && bash -c 'set -e; source "$1/tools/platform-lib.sh"; wt_write_ok f.txt; echo passed' _ "$ROOT" 2>&1)" || true
assert_eq passed "$r"
# The PowerShell link checks take the path from the environment, never pasted into the command (a ' in a name ran as PowerShell).
! grep -rn "LiteralPath '\$(cygpath" "$ROOT/tools" || fail "a PowerShell link check pastes the path into its command again"
# One copy of the rule, and no writer keeps its own link walk (the old _safe_ticket_path loop).
! grep -rn 'while \[\[ "\$p" == "\$base"/\* \]\]' "$ROOT/tools" || fail "a writer walks for links on its own again"
# One copy of the rule.
for fn in _is_dir_link _under_link _not_regular wt_write_ok; do
  n="$(grep -rhE "^${fn}\(\)" "$ROOT/tools" | wc -l | tr -d ' ')"; assert_eq 1 "$n"
done
# t-c206: the scopes went to the pinned registry, and the real one holds nothing of ours (only our own records are checked: a real
# gate or a parallel suite may add or prune others meanwhile).
ls "$REG"/* >/dev/null 2>&1 || fail "no gate scope landed in the pinned registry (CANON_GATE_SCOPE_DIR not used)"
ours="$(cd "$REG" && sed -n 's/^dir=//p' ./* | sort -u)"
for f in "/tmp/canon-gate-scope-$(id -u)"/*; do
  [[ -f "$f" ]] || continue
  ! grep -qxF "home=$HOME" "$f" || fail "a scope of this test is in the real registry: $f"
  d="$(sed -n 's/^dir=//p' "$f")"; [[ -z "$d" ]] || ! grep -qxF -- "$d" <<< "$ours" || fail "a scope dir of this test is in the real registry: $f"
done
echo "worktree-write-links: gate scopes stayed in the pinned registry"
echo "worktree-write-links: ok"
