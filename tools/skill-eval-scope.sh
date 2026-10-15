#!/usr/bin/env bash
# skill-eval-scope.sh — which skills did this diff change, and can their evals run (t-8d28)?
#   skill-eval-scope.sh [<base-ref>]
# Prints one sorted, de-duplicated line per changed skill. With no plain skills/<skill>/evals/evals.json: `skip <skill> (no evals/evals.json)`.
# With one: `run <skill>` when a change can reach its evals, else `skip <skill> (only docs outside SKILL.md changed; its evals read SKILL.md
# only)` (t-a1b1). An eval executor is given the skill's SKILL.md and nothing else, so only its SKILL.md, its evals/evals.json, or a doc
# whose path (skill-relative; for agents/*.md the repo path, in sprint's) appears in that evals.json can reach them. Nothing printed means
# no skill's instructions changed. The advisory skill-eval gate in skills/sprint/reference/complete.md runs only the `run` lines.
# Changed = base-ref (default: merge-base of HEAD and origin/main, as the gates derive it) against the working tree, plus untracked files.
# A path counts when it is skills/<name>/SKILL.md or any other .md under skills/<name>/ outside evals/ (reference files, gates/), and a
# top-level agents/*.md counts as `sprint` (the gate agents have no evals of their own). skills/<name>/evals/evals.json counts; the rest of
# evals/, skill-eval-result.md, scripts and tools/ never count: they are not the skill's instructions. Paths come from `git ... -z`, and the skill name is the only part that is printed,
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

evals_file() {   # evals_file <skill>: true when skills/<skill>/evals/evals.json is a plain file reached through no symlink
  [[ ! -L "$root/skills/$1" && ! -L "$root/skills/$1/evals" && -f "$root/skills/$1/evals/evals.json" && ! -L "$root/skills/$1/evals/evals.json" ]]
}
named() {   # named <skill> <path>: the path appears in that skill's evals.json (a literal substring test: no path is ever a pattern; a
            # longer name that contains it also matches, which costs a run, never a skip)
  local text
  evals_file "$1" || return 1
  text="$(cat "$root/skills/$1/evals/evals.json")" || return 1
  [[ "$text" == *"$2"* ]]
}

changed=""   # newline-separated "<skill> read|doc"; names match name_re, so no path can add a line of its own
note() {
  local p="$1" name="" rest="" kind=doc
  if [[ "$p" =~ ^skills/($name_re)/evals/evals\.json$ ]]; then name="${BASH_REMATCH[1]}"; kind=read
  elif [[ "$p" =~ $skill_doc_re ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    if [[ "$rest" == evals/* || "$p" == */skill-eval-result.md ]]; then name=""
    elif [[ "$rest" == SKILL ]] || named "$name" "$rest.md"; then kind=read
    fi
  elif [[ "$p" =~ ^agents/[^/]+\.md$ ]]; then
    name="sprint"; if named sprint "$p"; then kind=read; fi
  fi
  if [[ -n "$name" ]]; then changed+="$name $kind"$'\n'; fi
  return 0
}

diff_paths="$(mktemp)"; trap 'rm -f "$diff_paths"' EXIT
{ git -C "$root" diff --name-only -z "$base" -- && git -C "$root" ls-files --others --exclude-standard -z; } > "$diff_paths" \
  || die "git could not list the changed files"
while IFS= read -r -d '' p; do note "$p"; done < "$diff_paths"

[[ -n "$changed" ]] || exit 0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! evals_file "$name"; then echo "skip $name (no evals/evals.json)"
  elif grep -qxF "$name read" <<< "$changed"; then echo "run $name"
  else echo "skip $name (only docs outside SKILL.md changed; its evals read SKILL.md only)"
  fi
done < <(printf '%s' "$changed" | cut -d' ' -f1 | LC_ALL=C sort -u)
