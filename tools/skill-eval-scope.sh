#!/usr/bin/env bash
# skill-eval-scope.sh — which skills did this diff change, and can their evals run (t-8d28)?
#   skill-eval-scope.sh [<base-ref>]
# Prints one sorted, de-duplicated line per changed skill: `run <skill>` when skills/<skill>/evals/evals.json is a plain file, else
# `skip <skill> (no evals/evals.json)`. Nothing printed means no skill's instructions changed. The advisory skill-eval gate in
# skills/sprint/reference/complete.md runs only the `run` lines.
# Changed = base-ref (default: merge-base of HEAD and origin/main, as the gates derive it) against the working tree, plus untracked files.
# A path counts when it is skills/<name>/SKILL.md or any other .md under skills/<name>/ outside evals/ (reference files, gates/), and a
# top-level agents/*.md counts as `sprint` (the gate agents have no evals of their own). evals/, skill-eval-result.md, scripts and tools/
# never count: they are not the skill's instructions. Paths come from `git ... -z`, and the skill name is the only part that is printed,
# so a hostile file name can neither inject a line nor leave the name pattern.
set -euo pipefail

die() { echo "skill-eval-scope: $*" >&2; exit 1; }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"

base="${1-}"
if [[ -z "$base" ]]; then
  base="$(git -C "$root" merge-base HEAD origin/main 2>/dev/null)" || die "cannot derive a base: no merge-base of HEAD and origin/main (pass a base ref)"
else
  [[ "$base" != -* ]] || die "base ref must not start with '-' (got '$base')"
  git -C "$root" rev-parse --verify -q "$base^{commit}" >/dev/null || die "base ref '$base' is not a commit"
fi

name_re='[a-z0-9][a-z0-9-]*'
skill_doc_re="^skills/($name_re)/(.+)\\.md\$"

changed=""   # newline-separated skill names; names match name_re, so no path can add a line of its own
note() {
  local p="$1" name="" rest=""
  if [[ "$p" =~ $skill_doc_re ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    [[ "$rest" != evals/* && "$p" != */skill-eval-result.md ]] || name=""
  elif [[ "$p" =~ ^agents/[^/]+\.md$ ]]; then name="sprint"
  fi
  if [[ -n "$name" ]]; then changed+="$name"$'\n'; fi
  return 0
}

diff_paths="$(mktemp)"; trap 'rm -f "$diff_paths"' EXIT
{ git -C "$root" diff --name-only -z "$base" -- && git -C "$root" ls-files --others --exclude-standard -z; } > "$diff_paths" \
  || die "git could not list the changed files"
while IFS= read -r -d '' p; do note "$p"; done < "$diff_paths"

[[ -n "$changed" ]] || exit 0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if [[ ! -L "$root/skills/$name" && ! -L "$root/skills/$name/evals" && -f "$root/skills/$name/evals/evals.json" && ! -L "$root/skills/$name/evals/evals.json" ]]; then
    echo "run $name"
  else
    echo "skip $name (no evals/evals.json)"
  fi
done < <(printf '%s' "$changed" | LC_ALL=C sort -u)
