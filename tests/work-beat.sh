#!/usr/bin/env bash
# t-187e: tools/work-beat writes .tickets/ACTIVE.beat, the "an agent is on this ticket" label the board turns into a Working
# pill. Protects the commands every agent runs: `tkt start` / `sprint continue` / `evidence.sh stamp` refresh it, `tkt close` and
# `sprint complete` remove it, and a project's .gitignore keeps it out of git.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" HOME="$WORK/home" LC_ALL=C
unset CANON_TICKETS_DIR; mkdir -p "$HOME"
BEAT="$TOOLS_DIR/work-beat"

P="$WORK/proj"; mkdir -p "$P" && cd "$P"
git init -q -b main . && git config user.name t && git config user.email t@t
echo x > f && git add f && git commit -qm base
beat() { cat "$P/.tickets/ACTIVE.beat"; }
field() { sed -n "s/^$1=//p" "$P/.tickets/ACTIVE.beat"; }

# No ACTIVE ticket: nothing is written, and a bad call never fails the caller.
mkdir -p .tickets
"$BEAT" touch; [[ ! -e .tickets/ACTIVE.beat ]] || fail "work-beat: wrote a beat with no ACTIVE ticket"
printf 'not an id\n' > .tickets/ACTIVE; "$BEAT" touch; [[ ! -e .tickets/ACTIVE.beat ]] || fail "work-beat: wrote a beat for a garbage ACTIVE"
for bad in 'xt-aa9c' 't-aa9cd' 't-aa9c extra'; do   # only a whole ticket id counts (the anchors)
  printf '%s\n' "$bad" > .tickets/ACTIVE; "$BEAT" touch; [[ ! -e .tickets/ACTIVE.beat ]] || fail "work-beat: wrote a beat for ACTIVE '$bad'"
done
rm .tickets/ACTIVE
CANON_TICKETS_DIR="$WORK/nowhere" "$BEAT" touch; assert_eq 0 "$?"                  # an unusable folder is silent too: a label never fails its caller
CANON_TICKETS_DIR="$WORK/nowhere" "$BEAT" clear; assert_eq 0 "$?"
"$BEAT" frobnicate 2>/dev/null; assert_eq 0 "$?"

# tkt start marks ACTIVE and beats once: the ticket, the time, this host.
id="$("$TKT" create "Beat me" | tail -1)"
"$TKT" start "$id" >/dev/null
assert_eq "$id" "$(field ticket)"
now="$(date +%s)"; ts="$(field ts)"; (( now - ts < 30 )) || fail "work-beat: ts $ts is not now ($now)"
assert_eq "$(hostname | tr -d '[:space:]')" "$(field host)"
grep -qx 'pid=[0-9]*' .tickets/ACTIVE.beat || fail "work-beat: pid line is not 'pid=<digits or empty>': $(beat)"
assert_eq 4 "$(wc -l < .tickets/ACTIVE.beat | tr -d ' ')"

# sprint continue refreshes it (a beat made old by hand becomes now).
printf 'ticket=%s\nts=100\nhost=h\npid=\n' "$id" > .tickets/ACTIVE.beat
"$SPRINT" continue "$id" >/dev/null
(( $(date +%s) - $(field ts) < 30 )) || fail "work-beat: sprint continue did not refresh the beat"

# evidence.sh stamp refreshes it (it runs a command, so the beat shows an agent still going through a long step).
printf 'ticket=%s\nts=100\nhost=h\npid=\n' "$id" > .tickets/ACTIVE.beat
mkdir -p ".tickets/$id"
bash "$TOOLS_DIR/evidence.sh" stamp "$id" quick -- true >/dev/null
(( $(date +%s) - $(field ts) < 30 )) || fail "work-beat: evidence.sh stamp did not refresh the beat"

# The agent's process id is the nearest parent process called like an agent harness (a fake 'claude' here wins over any real one).
fake="$WORK/claude"; ln -s "$(command -v bash)" "$fake"   # a symlink: a copied bash is killed by macOS code signing
rm -f .tickets/ACTIVE.beat
"$fake" -c "echo \$\$ > '$WORK/fakepid'; '$BEAT' touch; :"   # not the last command, or bash execs it in place and the fake is gone
assert_eq "$(cat "$WORK/fakepid")" "$(field pid)"
# ... even several shells down (the harness runs a shell, which runs a script, which runs sprint), and the usage line names the verbs.
rm -f .tickets/ACTIVE.beat
"$fake" -c "echo \$\$ > '$WORK/fakepid'; bash -c \"bash -c '\\\"$BEAT\\\" touch; :'; :\"; :"
assert_eq "$(cat "$WORK/fakepid")" "$(field pid)"
case "$("$BEAT" frobnicate 2>&1)" in *"usage: work-beat touch|clear"*) ;; *) fail "work-beat: no usage line for an unknown verb" ;; esac
# ... and a chain with no agent leaves pid empty (the test's own ancestors may hold one, so cut the chain with env -i and a new session).
if command -v setsid >/dev/null 2>&1; then
  rm -f .tickets/ACTIVE.beat
  env -i PATH="$PATH" HOME="$HOME" setsid bash "$BEAT" touch </dev/null >/dev/null 2>&1 || true
  [[ ! -e .tickets/ACTIVE.beat || -z "$(field pid)" || "$(field pid)" =~ ^[0-9]+$ ]] || fail "work-beat: odd pid: $(beat)"
fi

# A beat for another ticket never survives ACTIVE moving: closing the active ticket removes it.
"$TKT" close "$id" --no-sprint >/dev/null
[[ ! -e .tickets/ACTIVE.beat ]] || fail "work-beat: tkt close left the beat"
[[ ! -e .tickets/ACTIVE ]] || fail "work-beat: tkt close left ACTIVE"

# The seeded .tickets/.gitignore lists the beat; one canon seeded before this change gains the line; a user's own file is left alone.
P2="$WORK/p2"; mkdir -p "$P2" && (cd "$P2" && git init -q -b main . && "$TKT" create "x" >/dev/null)
grep -qxF 'ACTIVE.beat' "$P2/.tickets/.gitignore" || fail "work-beat: a fresh .tickets/.gitignore does not list ACTIVE.beat"
printf '# canon runtime files — per-machine session state, never commit (t-2f53)\n.cockpit-*\nACTIVE\n' > "$P2/.tickets/.gitignore"
(cd "$P2" && "$TKT" create "again" >/dev/null)
assert_eq 1 "$(grep -cxF 'ACTIVE.beat' "$P2/.tickets/.gitignore")"
printf 'mine\n' > "$P2/.tickets/.gitignore"
(cd "$P2" && "$TKT" create "again" >/dev/null)
assert_eq "mine" "$(cat "$P2/.tickets/.gitignore")"

echo "work-beat: ok"
