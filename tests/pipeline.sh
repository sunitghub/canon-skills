#!/usr/bin/env bash
# pipeline (t-00e0) — tools/pipeline.sh, the one reader of the sprint pipeline, end to end on a real default file:
#   - canon's default (skills/sprint/pipeline.yaml) resolves to the 14 real nodes in order, no repo-check, the user-decided locked set,
#     and every node's prompt path exists;
#   - a project file (<dir>/canon-config/pipeline.yaml) switches off an open node and reorders only the wrapup group, and a CRLF file works;
#   - it refuses, exit 2 with one message naming the node or line, a locked node, an unknown node, a reorder outside the wrapup group, a
#     bad shape, a symlink, a binary file and an oversized one, and nothing in either file is ever executed;
#   - a malformed-input loop (fixed cases plus random mutations; `--fuzz` runs many more) never ends in a shell error, a hang or a write;
#   - drift: every gate name that complete.md's Wrapup Gates example, wrapup/SKILL.md, docs/wrapup-gates.md and docs/plugins.md list is a
#     node id of the file, so those lists cannot name a gate the pipeline lacks (repo-check was removed in t-0a7c).
# Protects the shipped command `tools/pipeline.sh resolve` that t-7e76 (sprint complete) and t-3a58 (Factory tab) read, and the gate lists
# in the docs `sprint complete` and wrapup read.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
P="$ROOT/tools/pipeline.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
CASES=60; [[ "${1:-}" == "--fuzz" ]] && CASES=600

# ── the default ──
expect="10 start step on locked
20 plan step on locked
30 approve-plan you on locked
40 build step on locked
50 code-simplifier gate on open
52 code-reviewer gate on open
54 doc-audit gate on open
60 skill-eval gate on open
62 break-it agent on open
70 reviewer agent on open
80 security-review gate on locked
90 mutation-test gate on open
100 eval agent on locked
110 close step on locked"
assert_eq "$expect" "$("$P" resolve)"
[[ "$("$P" check)" == "pipeline: ok (14 nodes)" ]] || fail "pipeline: check on the default did not say ok (14 nodes)"
ids="$("$P" ids | tr '\n' ' ')"
[[ "$ids" != *repo-check* ]] || fail "pipeline: repo-check is a node again (removed in t-0a7c)"
# --full: nine tab-separated fields, '-' for none; a locked node carries its reason; every prompt path exists in canon's folder
while IFS=$'\t' read -r _ id _ _ lk _ _ prompt reason; do
  [[ -n "$reason" ]] || fail "pipeline: --full line for $id has fewer than 9 fields"
  [[ "$lk" != locked || "$reason" != "-" ]] || fail "pipeline: locked node $id has no reason"
  [[ "$prompt" == "-" || -f "$ROOT/$prompt" ]] || fail "pipeline: node $id names a prompt that does not exist: $prompt"
done < <("$P" resolve --full)

# ── a project override ──
mkproj() { local d; d="$(mktemp -d "$T/proj.XXXXXX")"; mkdir "$d/canon-config"; printf '%b' "$1" > "$d/canon-config/pipeline.yaml"; printf '%s\n' "$d"; }
d="$(mkproj 'extends: canon-default\noff: [mutation-test, skill-eval]\nwrapup-order: [doc-audit, code-simplifier, code-reviewer]\n')"
got="$("$P" resolve --project "$d")"
assert_eq "50 doc-audit gate on open
52 code-simplifier gate on open
54 code-reviewer gate on open
60 skill-eval gate off open
90 mutation-test gate off open" "$(printf '%s\n' "$got" | grep -E ' (doc-audit|code-simplifier|code-reviewer|skill-eval|mutation-test) ')"
assert_eq "$(printf '%s\n' "$expect" | grep -vE ' (doc-audit|code-simplifier|code-reviewer|skill-eval|mutation-test) ')" "$(printf '%s\n' "$got" | grep -vE ' (doc-audit|code-simplifier|code-reviewer|skill-eval|mutation-test) ')"
# block lists, comments, a CRLF file and `extends` alone give the default
d="$(mkproj '# team policy\r\nextends: canon-default\r\noff:\r\n  - break-it\r\n  - reviewer\r\n')"
got="$("$P" resolve --project "$d")"
[[ "$got" == *"62 break-it agent off open"* && "$got" == *"70 reviewer agent off open"* ]] || fail "pipeline: a CRLF block-list override did not switch break-it and reviewer off"
d="$(mkproj 'extends: canon-default\n')"
assert_eq "$expect" "$("$P" resolve --project "$d")"
assert_eq "$expect" "$("$P" resolve --project "$T")"   # a folder with no canon-config: canon's default

# ── refusals: exit 2, one message naming the problem, nothing run ──
refuse() {   # refuse <expected text> <file content, printf %b>
  local d out rc=0
  d="$(mkproj "$2")"
  out="$("$P" resolve --project "$d" 2>&1 >/dev/null)" || rc=$?
  [[ "$rc" == 2 ]] || fail "pipeline: expected exit 2 for $(printf '%q' "$2"), got $rc: $out"
  [[ "$out" == *"$1"* ]] || fail "pipeline: refusal for $(printf '%q' "$2") did not say '$1': $out"
  [[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 1 ]] || fail "pipeline: refusal for $(printf '%q' "$2") is not one line: $out"
}
refuse "node 'eval' is locked: Always runs" 'extends: canon-default\noff: [eval]\n'
refuse "node 'security-review' is locked" 'extends: canon-default\noff:\n  - security-review\n'
refuse "unknown node 'repo-check'" 'extends: canon-default\noff: [repo-check]\n'
refuse "wrapup-order must list exactly: code-simplifier, code-reviewer, doc-audit" 'extends: canon-default\nwrapup-order: [reviewer, doc-audit, code-reviewer]\n'
refuse "wrapup-order must list exactly" 'extends: canon-default\nwrapup-order: [doc-audit, code-reviewer]\n'
refuse "listed twice in off" 'extends: canon-default\noff: [break-it, break-it]\n'
refuse "missing 'extends: canon-default'" 'off: [break-it]\n'
refuse "extends must be canon-default" 'extends: something-else\n'
refuse "extends twice" 'extends: canon-default\nextends: canon-default\n'
refuse "off twice" 'extends: canon-default\noff: []\noff: []\n'
refuse "bad node id" 'extends: canon-default\noff: [Break_It]\n'
refuse "unsupported line" 'extends: canon-default\nnodes:\n  - id: x\n'
refuse "unsupported line" '\textends: canon-default\n'
refuse "must be [id, id]" 'extends: canon-default\noff: {a: 1}\n'
refuse "must be [id, id]" 'extends: canon-default\noff: 5\n'
refuse "must be [id, id]" 'extends: canon-default\nwrapup-order: "x"\n'
refuse "missing 'extends: canon-default'" ''
refuse "line over 400 characters" "extends: canon-default\\n# $(printf 'x%.0s' $(seq 1 450))\\n"
d="$(mkproj 'extends: canon-default\n')"
mkdir -p "$T/linkproj/canon-config"; ln -s "$d/canon-config/pipeline.yaml" "$T/linkproj/canon-config/pipeline.yaml"
out="$("$P" resolve --project "$T/linkproj" 2>&1)" && fail "pipeline: a symlinked project file was read" || [[ "$out" == *"refusing a symlink"* ]] || fail "pipeline: symlink refusal said: $out"
d="$(mkproj 'extends: canon-default\n')"; printf 'extends: canon-default\n\000\n' > "$d/canon-config/pipeline.yaml"
out="$("$P" resolve --project "$d" 2>&1)" && fail "pipeline: a binary project file was read" || [[ "$out" == *"binary file"* ]] || fail "pipeline: binary refusal said: $out"
d="$(mkproj 'extends: canon-default\n')"; { printf 'extends: canon-default\n'; head -c 70000 /dev/zero | tr '\0' '#'; printf '\n'; } > "$d/canon-config/pipeline.yaml"
out="$("$P" resolve --project "$d" 2>&1)" && fail "pipeline: an oversized project file was read" || [[ "$out" == *"over 65536 bytes"* ]] || fail "pipeline: size refusal said: $out"
out="$("$P" resolve --project "$T/nope" 2>&1)" && fail "pipeline: a missing project folder was accepted" || [[ "$out" == *"not a folder"* ]] || fail "pipeline: missing-folder refusal said: $out"
out="$("$P" resolve --bogus 2>&1)" && fail "pipeline: an unknown option was accepted" || [[ "$out" == *"unknown option"* ]] || fail "pipeline: unknown-option refusal said: $out"
d="$(mkproj 'extends: canon-default\n')"; for n in $(seq 1 2100); do printf '# c\n'; done >> "$d/canon-config/pipeline.yaml"
out="$("$P" resolve --project "$d" 2>&1)" && fail "pipeline: a 2100-line project file was read" || [[ "$out" == *"more than 2000 lines"* ]] || fail "pipeline: line-count refusal said: $out"

# ── nothing in a file is ever run (cwd is a scratch folder: a stray `touch` would land there) ──
mkdir "$T/cwd"
for body in 'extends: canon-default\noff: [$(touch PWNED)]\n' 'extends: canon-default\noff: [`touch PWNED`]\n' 'extends: canon-default\n# $(touch PWNED)\noff: [break-it]\n' 'extends: canon-default\noff: ["$(touch PWNED)"]\n'; do
  d="$(mkproj "$body")"; (cd "$T/cwd" && "$P" resolve --project "$d" >/dev/null 2>&1) || true
  [[ ! -e "$T/cwd/PWNED" ]] || fail "pipeline: a project file ran a command ($body)"
done

# ── the default file is read the same way: a hostile copy of it is refused, not run ──
mkdir -p "$T/fake/tools" "$T/fake/skills/sprint"; cp "$P" "$T/fake/tools/pipeline.sh"
printf 'nodes:\n  - id: a$(touch PWNED)\n    kind: step\n' > "$T/fake/skills/sprint/pipeline.yaml"
out="$(cd "$T/cwd" && "$T/fake/tools/pipeline.sh" resolve 2>&1)" && fail "pipeline: a default file with a hostile id was read" || [[ "$out" == *"bad node id"* && ! -e "$T/cwd/PWNED" ]] || fail "pipeline: hostile default id said: $out"

# ── malformed-input loop: wrong shapes, random mutations; exit 0 or 2, a one-line "pipeline:" message on 2, never a write ──
RANDOM=20261109
frags=('extends: canon-default' 'extends: canon-default' 'off: [break-it]' 'off: []' 'off:' '  - break-it' '  - eval' '  - nope' 'wrapup-order: [doc-audit, code-simplifier, code-reviewer]'
  'wrapup-order:' '  - doc-audit' 'nodes:' '  - id: x' '    kind: gate' '# comment' '' '   ' $'\t'"off: [a]" 'off: [$(touch PWNED)]' 'off: [`id`]' 'off: [a,,b]' 'off: [,]'
  'off: [../../etc/passwd]' 'off: null' 'off: ~' 'off: [[a]]' 'off: [a: b]' 'extends: "canon-default"' "extends: 'canon-default'" 'wrapup-order: [doc-audit, doc-audit, doc-audit]'
  '   deeply:    nested:      more' $'\xff\xfe' 'off: [ΩΩ]' 'off: [a'"$(printf 'b%.0s' $(seq 1 60))"']' '- - - -' '{' ']' '"' "'")
nf=${#frags[@]}
for ((c = 1; c <= CASES; c++)); do
  lines=$((RANDOM % 7)); body=""
  for ((k = 0; k < lines; k++)); do body+="${frags[$((RANDOM % nf))]}"; (( RANDOM % 5 )) || body+=$'\r'; body+=$'\n'; done
  d="$(mktemp -d "$T/fz.XXXXXX")"; mkdir "$d/canon-config"; printf '%s' "$body" > "$d/canon-config/pipeline.yaml"
  rc=0; (cd "$T/cwd" && "$P" resolve --project "$d" >"$T/fz.out" 2>"$T/fz.err") || rc=$?
  [[ "$rc" == 0 || "$rc" == 2 ]] || fail "pipeline fuzz case $c: exit $rc for $(printf '%q' "$body"): $(head -c 300 "$T/fz.err")"
  if [[ "$rc" == 2 ]]; then
    [[ "$(wc -l < "$T/fz.err" | tr -d ' ')" == 1 && "$(head -c 10 "$T/fz.err")" == "pipeline: " ]] || fail "pipeline fuzz case $c: a refusal is not one 'pipeline:' line for $(printf '%q' "$body"): $(head -c 300 "$T/fz.err")"
  else
    [[ "$(wc -l < "$T/fz.out" | tr -d ' ')" == 14 ]] || fail "pipeline fuzz case $c: accepted a file but printed other than 14 nodes for $(printf '%q' "$body")"
  fi
  [[ -z "$(ls -A "$T/cwd")" ]] || fail "pipeline fuzz case $c: a file made the reader write ($(ls -A "$T/cwd"))"
  rm -rf "$d"
done

# ── drift: every gate name the docs list is a node id ──
nodeids="$("$P" ids)"
isnode() { grep -qxF -- "$1" <<<"$nodeids"; }
check_names() {   # check_names <where> <names...>
  local where="$1" n; shift
  [[ $# -gt 0 ]] || fail "pipeline drift: found no gate names in $where (the extraction is stale)"
  for n in "$@"; do isnode "$n" || fail "pipeline drift: $where names '$n', which is not a node of skills/sprint/pipeline.yaml (t-00e0; repo-check was removed in t-0a7c)"; done
}
# complete.md: the first column of the Wrapup Gates example rows
rows="$(awk '/^   ## Wrapup Gates/{f=1} f && /^   ```$/ {exit} f && /^   \| [a-z-]+ \| (ran|skipped|pending)/ { gsub(/^   \| /, ""); sub(/ \|.*/, ""); print }' "$ROOT/skills/sprint/reference/complete.md")"
# shellcheck disable=SC2086
check_names "complete.md's Wrapup Gates example" $rows
# wrapup/SKILL.md and docs/wrapup-gates.md: the pipeline line, `a → b → c → refresh docs`
wl="$(awk '/^## Pipeline/{f=1;next} f && /→/ {print; exit}' "$ROOT/skills/wrapup/SKILL.md" | sed 's/→/ /g; s/refresh docs//')"
# shellcheck disable=SC2086
check_names "skills/wrapup/SKILL.md's pipeline line" $wl
dl="$(grep -m1 'The wrapup pipeline itself is' "$ROOT/docs/wrapup-gates.md" | sed 's/^[^`]*`//; s/`.*$//; s/→/ /g; s/refresh docs//')"
# shellcheck disable=SC2086
check_names "docs/wrapup-gates.md's pipeline line" $dl
# docs/plugins.md: the backticked gate names in the wrapup.gate_started row
pl="$(grep -m1 '^| `wrapup.gate_started`' "$ROOT/docs/plugins.md" | sed 's/^[^(]*(//; s/).*$//' | grep -oE '`[a-z-]+`' | tr -d '`')"
# shellcheck disable=SC2086
check_names "docs/plugins.md's wrapup.gate_started gates" $pl
echo "PASS: pipeline ($CASES fuzz cases)"
