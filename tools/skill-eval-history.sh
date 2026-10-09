#!/usr/bin/env bash
# skill-eval-history.sh — record one skill-eval pass rate and say how it moved (t-8d28).
#   skill-eval-history.sh <skill> <model> <pass> <total>
# Appends one JSON line {"date":"YYYY-MM-DD","model":"<model>","pass":N,"total":M} to skills/<skill>/evals/history.jsonl and prints
# `N/M pass (was K/M)`, K/M being the most recent earlier line for the SAME model (small models are noisy, so a rate is never compared
# across models), or `N/M pass (first run on <model>)`. Earlier lines that do not parse are skipped. Every argument is validated before
# anything is written, so a refusal leaves the file as it was (and creates none). Run from the project root; skills/<skill>, its evals/
# and the history file must not be symlinks, so a write never lands in another tree. The append is one short write, so concurrent runs
# keep every line whole. Pure bash: neither jq nor python.
set -euo pipefail

die() { echo "skill-eval-history: $*" >&2; exit 1; }

[[ $# -eq 4 ]] || die "usage: skill-eval-history.sh <skill> <model> <pass> <total>"
skill="$1"; model="$2"; pass="$3"; total="$4"

[[ "$skill" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "skill name must match [a-z0-9][a-z0-9-]* (got '$skill')"
[[ "$model" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || die "model must match [A-Za-z0-9._:-]{1,64} (got '$model')"
int_re='^(0|[1-9][0-9]{0,5})$'
[[ "$pass" =~ $int_re ]] || die "pass must be a non-negative integer (got '$pass')"
[[ "$total" =~ $int_re ]] || die "total must be a non-negative integer (got '$total')"
(( total > 0 )) || die "total must be above 0"
(( pass <= total )) || die "pass ($pass) cannot exceed total ($total)"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
sdir="$root/skills/$skill"
[[ -d "$sdir" && ! -L "$sdir" ]] || die "skills/$skill is not a plain directory"
[[ ! -L "$sdir/evals" ]] || die "skills/$skill/evals is a symlink"
[[ -f "$sdir/evals/evals.json" && ! -L "$sdir/evals/evals.json" ]] || die "skills/$skill/evals/evals.json is missing"
hist="$sdir/evals/history.jsonl"
[[ ! -L "$hist" ]] || die "skills/$skill/evals/history.jsonl is a symlink"
[[ ! -e "$hist" || -f "$hist" ]] || die "skills/$skill/evals/history.jsonl is not a plain file"

line_re='^\{"date":"[0-9]{4}-[0-9]{2}-[0-9]{2}","model":"([A-Za-z0-9._:-]{1,64})","pass":(0|[1-9][0-9]{0,5}),"total":([1-9][0-9]{0,5})\}$'
was=""
if [[ -f "$hist" ]]; then
  while IFS= read -r l || [[ -n "$l" ]]; do
    l="${l%$'\r'}"
    if [[ "$l" =~ $line_re && "${BASH_REMATCH[1]}" == "$model" ]]; then was="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"; fi
  done < "$hist"
fi

lead=""
if [[ -s "$hist" && -n "$(tail -c1 "$hist")" ]]; then lead=$'\n'; fi   # a last line with no newline would swallow ours
printf '%s{"date":"%s","model":"%s","pass":%s,"total":%s}\n' "$lead" "$(date -u +%Y-%m-%d)" "$model" "$pass" "$total" >> "$hist"

if [[ -n "$was" ]]; then echo "$pass/$total pass (was $was)"; else echo "$pass/$total pass (first run on $model)"; fi
