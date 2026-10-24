#!/usr/bin/env bash
# sprint-headless-eval-tools.sh — unit tests for the config-driven evaluator
# allowedTools resolution in tools/sprint-headless-eval. Uses the hidden
# --print-allowed-tools seam so nothing invokes claude / the network.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
EVAL="tools/sprint-headless-eval"

fails=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
assert() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# Temp dir INSIDE the repo so the tool's upward .git walk resolves to canon.
tmp="$(mktemp -d "$repo_root/.hetools.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
# t-b62a: the tool parses JSON with the board binary's helpers; a fresh build, not the fetched one (which may be older).
source "$repo_root/tests/helpers.sh"
use_fresh_board "$tmp"
spec="$tmp/spec.md"; printf '# tools test spec\n- [ ] a criterion to satisfy extraction\n' > "$spec"

# Expected least-privilege default (skills/ layout → ./tools subagent-log allow).
read -r -d '' EXPECT_DEFAULT <<'EOF' || true
Agent
Bash(__GIT_READ__:*)
Bash(./tools/subagent-log.sh:*)
Read
Grep
Glob
LS
EOF

EXPECT_DEFAULT="${EXPECT_DEFAULT/__GIT_READ__/$(cd -P "$repo_root/tools" && pwd)/git-read}"   # t-5ff5: the install's git-read, by absolute path
git_allow="Bash($(cd -P "$repo_root/tools" && pwd)/git-read:*)"

echo "--- default (no --allowed-tools-file) ---"
def="$(bash "$EVAL" "$spec" --base-ref HEAD --print-allowed-tools)"
assert '[ "$def" = "$EXPECT_DEFAULT" ]'                          "default = exact least-privilege list (backward-compatible)"
assert '! printf "%s\n" "$def" | grep -xE "Bash|Bash\(bash.*" >/dev/null'  "default has NO general Bash / Bash(bash...) grant"

echo "--- config REPLACES list + force-adds mechanism entries ---"
cfg="$tmp/tools.json"; printf '["Read","Grep","Bash(bash tests/run.sh:*)"]\n' > "$cfg"
set +e; ext="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$cfg" --print-allowed-tools 2>/dev/null)"; erc=$?; set -e
assert '[ "$erc" -eq 0 ]'                                        "config run exits 0"
assert 'printf "%s\n" "$ext" | grep -xF "Bash(bash tests/run.sh:*)" >/dev/null' "narrow runner grant present from config"
assert 'printf "%s\n" "$ext" | grep -xF "Agent" >/dev/null'                "Agent force-added when omitted by config"
assert 'printf "%s\n" "$ext" | grep -xF "Bash(./tools/subagent-log.sh:*)" >/dev/null' "subagent-log allow force-added when omitted"
assert '! printf "%s\n" "$ext" | grep -xF "Bash(git diff:*)" >/dev/null'   "config REPLACES the default (git-diff grant gone)"
assert 'printf "%s\n" "$ext" | grep -xF "$git_allow" >/dev/null'           "t-5ff5: git-read force-added when omitted by config"

echo "--- t-5ff5: a config that still grants plain git warns (and keeps working) ---"
gcfg="$tmp/git.json"; printf '["Read","Bash(git diff:*)"]\n' > "$gcfg"
set +e; gout="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$gcfg" --print-allowed-tools 2>&1)"; grc=$?; set -e
assert '[ "$grc" -eq 0 ]'                                                       "plain-git config still runs"
assert 'grep -qF "Warning: $gcfg grants '"'"'Bash(git diff:*)'"'"': plain git under dontAsk can write files" <<<"$gout"' "plain-git config prints the write-risk warning"
set +e; nwout="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$cfg" --print-allowed-tools 2>&1)"; set -e
assert '! grep -qF "Warning:" <<<"$nwout"'                                      "a config without plain git prints no warning"
g2="$tmp/git2.json"; printf '["Bash(git:*)"]\n' > "$g2"
set +e; g2out="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$g2" --print-allowed-tools 2>&1)"; set -e
assert 'grep -qF "grants '"'"'Bash(git:*)'"'"': plain git under dontAsk" <<<"$g2out"' "a Bash(git:*) grant warns too"
g3="$tmp/git3.json"; printf '["Read","%s"]\n' "$git_allow" > "$g3"
g3out="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$g3" --print-allowed-tools 2>/dev/null)"
assert '[ "$(grep -cxF "$git_allow" <<<"$g3out")" -eq 1 ]'                     "a config that lists git-read keeps one grant (not force-added twice)"

echo "--- malformed / non-array / missing configs fail-closed ---"
badj="$tmp/bad.json"; printf '{not valid json' > "$badj"
set +e; bout="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$badj" --print-allowed-tools 2>&1)"; brc=$?; set -e
assert '[ "$brc" -ne 0 ]'                                        "malformed JSON exits non-zero"
assert 'printf "%s" "$bout" | grep "invalid JSON" >/dev/null'            "malformed JSON error is clear"

naj="$tmp/na.json"; printf '{"a":1}' > "$naj"
set +e; nout="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$naj" --print-allowed-tools 2>&1)"; nrc=$?; set -e
assert '[ "$nrc" -ne 0 ]'                                        "non-array JSON exits non-zero"
assert 'printf "%s" "$nout" | grep "must be a JSON array" >/dev/null'    "non-array error is clear"

set +e; mout="$(bash "$EVAL" "$spec" --base-ref HEAD --allowed-tools-file "$tmp/nope.json" --print-allowed-tools 2>&1)"; mrc=$?; set -e
assert '[ "$mrc" -ne 0 ]'                                        "missing config file exits non-zero"
assert 'printf "%s" "$mout" | grep "not found" >/dev/null'               "missing-file error is clear"

echo "--- a spec with no git repository above it is still refused (a worktree's .git FILE is accepted, nothing is not) ---"
nogit="$(mktemp -d)"
printf '# spec\n- [ ] a criterion\n' > "$nogit/spec.md"
set +e; gout="$(bash "$EVAL" "$nogit/spec.md" --base-ref HEAD --print-allowed-tools 2>&1)"; grc=$?; set -e
rm -rf "$nogit"
assert '[ "$grc" -ne 0 ]'                                         "no .git anywhere above the spec exits non-zero"
assert 'printf "%s" "$gout" | grep "could not find a git repository" >/dev/null' "no-.git error is clear"

echo "--- shipped template parses and equals the default (minus runtime log entry) ---"
assert 'python3 -c "import json;json.load(open(\"tools/headless-eval-tools.json\"))"' "template is valid JSON"

echo "--- t-89b0: CANON_GATE_SKILLS pins skills and the install's subagent-log.sh; a dir without sprint/ is refused ---"
pin_allow="Bash($(cd -P "$repo_root/tools" && pwd)/subagent-log.sh:*)"
pinned="$(CANON_GATE_SKILLS="$repo_root/skills" bash "$EVAL" "$spec" --base-ref HEAD --print-allowed-tools)"
assert 'printf "%s\n" "$pinned" | grep -xF "$pin_allow" >/dev/null'                  "pinned: allows the install's subagent-log.sh"
set +e; bad="$(CANON_GATE_SKILLS="$tmp/none" bash "$EVAL" "$spec" --base-ref HEAD --print-allowed-tools 2>&1)"; brc=$?; set -e
assert '[ "$brc" -ne 0 ] && grep -q "has no sprint/ skill docs" <<<"$bad"' "pinned dir without sprint/ is refused"
echo "--- t-30bf: a graded project outside this install gets the install's subagent-log.sh, never its own ---"
proj="$(mktemp -d)"; trap 'rm -rf "$tmp" "$proj"' EXIT
git -C "$proj" init -q; mkdir -p "$proj/skills/sprint" "$proj/tools"
printf '#!/bin/sh\necho planted\n' > "$proj/tools/subagent-log.sh"; chmod +x "$proj/tools/subagent-log.sh"
pspec="$proj/spec.md"; printf '# outside spec\n- [ ] a criterion\n' > "$pspec"
install_allow="Bash($(cd -P "$repo_root/tools" && pwd)/subagent-log.sh:*)"
out_def="$(bash "$EVAL" "$pspec" --base-ref HEAD --print-allowed-tools)"
assert 'printf "%s\n" "$out_def" | grep -xF "$install_allow" >/dev/null'        "outside project: default allows the install's subagent-log.sh"
assert '! printf "%s\n" "$out_def" | grep -F "./tools/subagent-log.sh" >/dev/null' "outside project: default never allows ./tools/subagent-log.sh"
out_cfg="$(bash "$EVAL" "$pspec" --base-ref HEAD --allowed-tools-file "$cfg" --print-allowed-tools 2>/dev/null)"
assert 'printf "%s\n" "$out_cfg" | grep -xF "$install_allow" >/dev/null'        "outside project: force-add uses the install's subagent-log.sh"
assert '! printf "%s\n" "$out_cfg" | grep -F "./tools/subagent-log.sh" >/dev/null' "outside project: force-add never adds ./tools/subagent-log.sh"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
