#!/usr/bin/env bash
# tests/skills-agents.sh — t-c774: canon's close-gate agent definitions (agents/), how skills.sh installs
# them into a project, the system-installer deny rules, and the Codex mirror's parity.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp_home="$(mktemp -d)"
export HOME="$tmp_home"
dirs=("$tmp_home")
trap 'rm -rf "${dirs[@]}"' EXIT
newp() { local d; d="$(make_project)"; dirs+=("$d"); printf '# Agents\n' > "$d/AGENTS.md"; printf '%s\n' "$d"; }
fm() { awk -v k="$2" 'NR==1{next} /^---/{exit} index($0, k": ")==1 {print substr($0, length(k)+3)}' "$1"; }
# lib <project> <skills_root> <function>: call one skills.sh function with the given SKILLS_ROOT.
lib() { SKILLS_ROOT="$2" bash -c 'source "$1/tools/skills/project.sh"; source "$1/tools/skills/prompts.sh"; "$2" "$3"' _ "$ROOT" "$3" "$1"; }

# --- 1. definitions ---------------------------------------------------------------------------
registry="$ROOT/tools/sprint-check-app/model-tiers.json"
anth_id="$(python3 -c "import json;print(json.load(open('$registry'))['defaults']['eval']['anthropic'])")"
anth_alias="$(python3 -c "import json;d=json.load(open('$registry'));print(next(m['alias'] for m in d['models']['anthropic'] if m['id']=='$anth_id'))")"
openai_id="$(python3 -c "import json;print(json.load(open('$registry'))['defaults']['eval']['openai'])")"
for g in reviewer evaluator; do
  md="$ROOT/agents/canon-$g.md"; toml="$ROOT/agents/codex/canon-$g.toml"
  assert_file_exists "$md"; assert_file_exists "$toml"
  assert_eq "---" "$(head -1 "$md")"                       # byte 0 is '-' (no BOM, no '\---')
  assert_eq "canon-$g" "$(fm "$md" name)"
  assert_eq "$anth_alias" "$(fm "$md" model)"               # model floor = registry's eval default
  assert_eq "high" "$(fm "$md" effort)"
  tools="$(fm "$md" tools)"
  assert_eq "Read, Grep, Glob, Bash" "$tools"
  for bad in Edit Write Agent; do [[ ", $tools," != *", $bad,"* ]] || fail "$md grants $bad"; done
  assert_count 1 "canon:agent" "$md"
  # Codex parity: same name, effort, registry-owned model, and no write access.
  tv() { sed -n "s/^$1 = \"\\(.*\\)\"$/\\1/p" "$toml"; }
  assert_eq "canon-$g" "$(tv name)"
  assert_eq "$openai_id" "$(tv model)"
  assert_eq "$(fm "$md" effort)" "$(tv model_reasoning_effort)"
  assert_eq "read-only" "$(tv sandbox_mode)"
done

# --- 2. fresh project: add sprint links .claude/agents and gitignores it -----------------------
p1="$(newp)"
"$SKILLS" add sprint "$p1" >/dev/null
[[ -L "$p1/.claude/agents" ]] || fail "expected .claude/agents link"
assert_eq "$ROOT/agents" "$(readlink "$p1/.claude/agents")"
[ "$(grep -cxF "/.claude/agents" "$p1/.gitignore")" -eq 1 ] || fail "link not gitignored once"
git -C "$p1" check-ignore -q .claude/agents || fail "git does not actually ignore the .claude/agents link"
"$SKILLS" refresh "$p1" >/dev/null 2>&1
[ "$(grep -cxF "/.claude/agents" "$p1/.gitignore")" -eq 1 ] || fail "refresh duplicated the gitignore entry"

# remove sprint removes only canon's link.
"$SKILLS" remove sprint "$p1" >/dev/null
[[ ! -e "$p1/.claude/agents" && ! -L "$p1/.claude/agents" ]] || fail "remove left the canon link"

# --- 3. project's own real .claude/agents: copy canon files, keep the user's ------------------
p2="$(newp)"
mkdir -p "$p2/.claude/agents"
printf -- '---\nname: mine\ndescription: x\n---\nuser agent\n' > "$p2/.claude/agents/mine.md"
printf -- '---\nname: canon-evaluator\ndescription: my own\n---\nuser-owned, no marker\n' > "$p2/.claude/agents/canon-evaluator.md"
h_mine="$(md5sum "$p2/.claude/agents/mine.md" | cut -d' ' -f1)"
h_user_eval="$(md5sum "$p2/.claude/agents/canon-evaluator.md" | cut -d' ' -f1)"
out="$(lib "$p2" "$ROOT" upsert_gate_agents)"
[[ ! -L "$p2/.claude/agents" ]] || fail "a real folder must not be replaced by a link"
cmp -s "$ROOT/agents/canon-reviewer.md" "$p2/.claude/agents/canon-reviewer.md" || fail "canon-reviewer.md not copied"
assert_eq "$h_user_eval" "$(md5sum "$p2/.claude/agents/canon-evaluator.md" | cut -d' ' -f1)"
assert_contains "$out" "not canon-managed"
assert_eq "$h_mine" "$(md5sum "$p2/.claude/agents/mine.md" | cut -d' ' -f1)"
[[ ! -e "$p2/.gitignore" ]] || ! grep -qxF "/.claude/agents" "$p2/.gitignore" || fail "a real agents folder must stay tracked"

# a stale canon copy (marker kept) is refreshed; an identical one is left alone and silent.
printf '\nstale line\n' >> "$p2/.claude/agents/canon-reviewer.md"
lib "$p2" "$ROOT" upsert_gate_agents >/dev/null
cmp -s "$ROOT/agents/canon-reviewer.md" "$p2/.claude/agents/canon-reviewer.md" || fail "stale canon copy not refreshed"
out="$(lib "$p2" "$ROOT" upsert_gate_agents)"
[[ "$out" != *"copied"* ]] || fail "identical copy re-copied: $out"

# remove: canon-marked copies go, the user's files stay.
lib "$p2" "$ROOT" remove_gate_agents >/dev/null
[[ ! -e "$p2/.claude/agents/canon-reviewer.md" ]] || fail "canon copy not removed"
assert_eq "$h_user_eval" "$(md5sum "$p2/.claude/agents/canon-evaluator.md" | cut -d' ' -f1)"
assert_eq "$h_mine" "$(md5sum "$p2/.claude/agents/mine.md" | cut -d' ' -f1)"

# --- 4. a link the user pointed elsewhere is left alone -------------------------------------
p3="$(newp)"; own="$(mktemp -d)"; dirs+=("$own")
mkdir -p "$p3/.claude"; ln -s "$own" "$p3/.claude/agents"
out="$(lib "$p3" "$ROOT" upsert_gate_agents)"
assert_eq "$own" "$(readlink "$p3/.claude/agents")"
assert_contains "$out" "links elsewhere"
[[ ! -e "$own/canon-reviewer.md" ]] || fail "copied into the user's linked folder"
lib "$p3" "$ROOT" remove_gate_agents >/dev/null
assert_eq "$own" "$(readlink "$p3/.claude/agents")"

# a dangling link (e.g. canon moved) is re-pointed to canon.
p4="$(newp)"; mkdir -p "$p4/.claude"; ln -s "$p4/nowhere" "$p4/.claude/agents"
lib "$p4" "$ROOT" upsert_gate_agents >/dev/null
assert_eq "$ROOT/agents" "$(readlink "$p4/.claude/agents")"

# --- 5. canon's own root links to its own agents/ (dogfooding, like its .claude/skills) --------
fake="$(make_project)"; dirs+=("$fake")
mkdir -p "$fake/agents"; cp "$ROOT"/agents/canon-*.md "$fake/agents/"
lib "$fake" "$fake" upsert_gate_agents >/dev/null
assert_eq "$fake/agents" "$(readlink "$fake/.claude/agents")"
[ "$(grep -cxF "/.claude/agents" "$fake/.gitignore")" -eq 1 ] || fail "canon's own agents link not gitignored"
git -C "$fake" check-ignore -q .claude/agents || fail "canon's own agents link not actually ignored"

# --- 6. worktree link ---------------------------------------------------------------------------
p5="$(newp)"
git -C "$p5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$p5" worktree add -q "$p5-wt" -b wt >/dev/null 2>&1; dirs+=("$p5-wt")
"$SKILLS" link-worktree "$p5-wt" >/dev/null
assert_eq "$ROOT/agents" "$(readlink "$p5-wt/.claude/agents")"

# --- 7. system-installer deny rules ------------------------------------------------------------
rules_expected=7
p6="$(newp)"; mkdir -p "$p6/.claude"
printf '{\n  "env": {"X": "1"},\n  "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm -rf:*)"]}\n}\n' > "$p6/.claude/settings.json"
SKILLS_SH_ASSUME_YES=1 lib "$p6" "$ROOT" offer_install_deny_rules >/dev/null
python3 - "$p6/.claude/settings.json" "$rules_expected" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); deny = d["permissions"]["deny"]
assert d["env"] == {"X": "1"} and d["permissions"]["allow"] == ["Bash(ls:*)"], d
assert deny[0] == "Bash(rm -rf:*)", deny
assert "Bash(brew install:*)" in deny and "Bash(winget install:*)" in deny, deny
assert len(deny) == 1 + int(sys.argv[2]), deny
EOF
h6="$(md5sum "$p6/.claude/settings.json" | cut -d' ' -f1)"
SKILLS_SH_ASSUME_YES=1 lib "$p6" "$ROOT" offer_install_deny_rules >/dev/null
assert_eq "$h6" "$(md5sum "$p6/.claude/settings.json" | cut -d' ' -f1)"   # no duplicates on re-run

# some canon rules already present: only the missing ones are added, none duplicated.
p9="$(newp)"; mkdir -p "$p9/.claude"
printf '{"permissions": {"deny": ["Bash(brew install:*)"]}}\n' > "$p9/.claude/settings.json"
SKILLS_SH_ASSUME_YES=1 lib "$p9" "$ROOT" offer_install_deny_rules >/dev/null
python3 - "$p9/.claude/settings.json" "$rules_expected" <<'EOF2'
import json, sys
deny = json.load(open(sys.argv[1]))["permissions"]["deny"]
assert deny.count("Bash(brew install:*)") == 1 and len(deny) == int(sys.argv[2]), deny
EOF2

# no tty and no assume-yes: nothing is written.
p7="$(newp)"
lib "$p7" "$ROOT" offer_install_deny_rules </dev/null >/dev/null 2>&1 || true
[[ ! -e "$p7/.claude/settings.json" ]] || ! grep -q "brew install" "$p7/.claude/settings.json" || fail "deny rules added without consent"

# malformed settings: refused cleanly, byte-identical.
for bad in 'not json' '{"permissions": ["x"]}' '{"permissions": {"deny": "Bash(x)"}}' '[1,2]'; do
  p8="$(newp)"; mkdir -p "$p8/.claude"; printf '%s\n' "$bad" > "$p8/.claude/settings.json"
  h8="$(md5sum "$p8/.claude/settings.json" | cut -d' ' -f1)"
  out="$(SKILLS_SH_ASSUME_YES=1 lib "$p8" "$ROOT" offer_install_deny_rules 2>&1)"
  assert_eq "$h8" "$(md5sum "$p8/.claude/settings.json" | cut -d' ' -f1)"
  assert_contains "$out" "not valid JSON"
done

printf 'skills-agents: ok\n'
