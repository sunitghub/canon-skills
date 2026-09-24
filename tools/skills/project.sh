#!/usr/bin/env bash
# tools/skills/project.sh — project registration and symlink management

set -euo pipefail

# shellcheck source=tools/skills/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Create a directory symlink (Unix) or junction (Windows — no elevated rights needed).
_create_dir_link() {
  local target="$1" link="$2"
  if _is_windows; then
    # mklink /J fails if a junction already exists — remove before recreating
    # MSYS_NO_PATHCONV: without it, Git Bash mangles the /c flag into a Windows
    # path, so cmd.exe opens interactively instead of running the command.
    [ -d "$link" ] && MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$(cygpath -w "$link")" > /dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(cygpath -w "$link")" "$(cygpath -w "$target")" > /dev/null
  else
    ln -sfn "$target" "$link"
  fi
}

# Return the target of a directory symlink/junction, or empty string if not one.
_read_dir_link() {
  local link="$1"
  if _is_windows; then
    powershell.exe -NoProfile -Command \
      "\$i=Get-Item -LiteralPath '$(cygpath -w "$link")' -EA SilentlyContinue; if(\$i){\$i.Target}" \
      2>/dev/null | tr -d '\r\n' | cygpath -u -f - 2>/dev/null || true
  else
    readlink "$link"
  fi
}

# True if path is a directory symlink (Unix) or junction (Windows).
_is_dir_link() {
  local link="$1"
  if _is_windows; then
    [ -d "$link" ] && \
      powershell.exe -NoProfile -Command \
        "\$i=Get-Item -LiteralPath '$(cygpath -w "$link")' -EA SilentlyContinue; if(\$i){(\$i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}" \
        2>/dev/null | tr -d '\r\n' | grep -qi "true"
  else
    [ -L "$link" ]
  fi
}

# Remove a directory symlink (Unix) or junction (Windows) without touching contents.
_remove_dir_link() {
  local link="$1"
  if _is_windows; then
    MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$(cygpath -w "$link")" > /dev/null 2>&1
  else
    rm "$link"
  fi
}

# t-f99b: the skill mirror (.claude/skills, .agents/skills) is a LOCAL link to
# canon's skills — it must never be committed. On Windows a junction is
# git-visible (git tracks its CONTENTS as files), so a consumer `git add -A`
# would commit stale copies that a worktree/old checkout then serves (this
# masked t-720c). Ensure the project gitignores the mirror dirs, and untrack the
# mirror if a prior commit already captured it. Only the two mirror dirs, never
# the parent .claude/.agents (which may hold other tracked config). No-op when
# the project isn't a git work tree.
_ensure_mirror_gitignored() {
  local project_dir="$1"
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local gi="$project_dir/.gitignore" entry rel
  for entry in "/.claude/skills/" "/.agents/skills/"; do
    if ! grep -qxF "$entry" "$gi" 2>/dev/null; then
      printf '%s\n' "$entry" >> "$gi"
      echo "  [gitignore] $entry"
    fi
    rel="${entry#/}"; rel="${rel%/}"
    if [ -n "$(git -C "$project_dir" ls-files -- "$rel" 2>/dev/null | head -1)" ]; then
      git -C "$project_dir" rm -r --cached --quiet -- "$rel" >/dev/null 2>&1 || true
      echo "  [gitignore] untracked previously-committed mirror: $rel"
    fi
  done
}

# t-c774: canon's close-gate agent definitions (agents/canon-reviewer.md, canon-evaluator.md) give the
# gates a fixed model floor, effort and tool list. No .claude/agents -> link the folder to canon's (a
# junction on Windows); a project's own real folder -> copy the canon-*.md files in, refreshed when
# canon's differ. A same-named file without the canon:agent marker, or a link the user pointed
# elsewhere, is never touched.
_is_canon_agents_dir() { [ -f "$1/canon-reviewer.md" ] && grep -qF "canon:agent" "$1/canon-reviewer.md"; }

upsert_gate_agents() {
  local project_dir="$1" target="$SKILLS_ROOT/agents"
  local link="$project_dir/.claude/agents" cur src dst
  [ -d "$target" ] || return 0
  # canon's own root is linked too (like its .claude/skills), so canon's own closes run its gates.
  mkdir -p "$project_dir/.claude"
  if _is_dir_link "$link"; then
    cur="$(_read_dir_link "$link")"
    [ "$cur" = "$target" ] && { _ensure_agents_link_gitignored "$project_dir"; return 0; }
    if [ ! -d "$cur" ] || _is_canon_agents_dir "$cur"; then
      _create_dir_link "$target" "$link"
      echo "  [agents]  updated link: $link"
      _ensure_agents_link_gitignored "$project_dir"
    else
      echo "  [agents]  $link links elsewhere (not canon) — left as is; gates fall back to Plan"
    fi
  elif [ -d "$link" ]; then
    for src in "$target"/canon-*.md; do
      dst="$link/$(basename "$src")"
      if [ -e "$dst" ] && ! grep -qF "canon:agent" "$dst"; then
        echo "  [agents]  $dst exists and is not canon-managed — left as is"
        continue
      fi
      if [ ! -e "$dst" ] || ! cmp -s "$src" "$dst"; then
        cp "$src" "$dst"
        echo "  [agents]  copied: $dst"
      fi
    done
  elif [ -e "$link" ] || [ -L "$link" ]; then
    echo "  [agents]  $link is not a directory — left as is; gates fall back to Plan"
  else
    _create_dir_link "$target" "$link"
    echo "  [agents]  created link: $link"
    _ensure_agents_link_gitignored "$project_dir"
  fi
  return 0
}

# Only canon's own link or canon-marked copies; a user's files and folder stay.
remove_gate_agents() {
  local project_dir="$1" link="$1/.claude/agents" f
  if _is_dir_link "$link"; then
    if [ "$(_read_dir_link "$link")" = "$SKILLS_ROOT/agents" ]; then
      _remove_dir_link "$link"
      echo "  [agents]  removed link: $link"
    fi
  elif [ -d "$link" ]; then
    for f in "$link"/canon-*.md; do
      [ -f "$f" ] && grep -qF "canon:agent" "$f" || continue
      rm "$f"
      echo "  [agents]  removed: $f"
    done
  fi
  return 0
}

# A linked .claude/agents is local (like the skills mirror, t-f99b) and must never be committed.
_ensure_agents_link_gitignored() {
  # No trailing slash: git treats a symlink as a file, so "/.claude/agents/" (directories only) would not
  # match it on macOS/Linux — only a Windows junction, which git sees as a directory.
  local project_dir="$1" gi="$1/.gitignore" entry="/.claude/agents"
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if ! has_line "$entry" "$gi"; then
    [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ] && echo >> "$gi"
    printf '%s\n' "$entry" >> "$gi"
    echo "  [gitignore] $entry"
  fi
  return 0
}

# t-f99b: create the skills link inside a git worktree so it resolves to CURRENT
# canon (never a stale committed copy). Called by the board's createWorktree
# (via `skills.sh link-worktree <path>`) — a git worktree, being gitignored, has
# no mirror of its own otherwise. Skips a real (project-local) skills dir.
link_worktree() {
  local wt_dir target link rel
  wt_dir="$(cd "${1:-}" 2>/dev/null && pwd)" || { echo "link-worktree: no such dir: ${1:-}" >&2; return 1; }
  target="$SKILLS_ROOT/skills"
  for link in "$wt_dir/.claude/skills" "$wt_dir/.agents/skills"; do
    if _is_dir_link "$link"; then
      [ "$(_read_dir_link "$link")" = "$target" ] && continue
      _create_dir_link "$target" "$link"
    elif [ -e "$link" ]; then
      # t-9e55: a materialized real dir. If it's a git-TRACKED committed canon
      # mirror (carries the sprint/SKILL.md marker), REPLACE it so the worktree
      # serves CURRENT canon — `git worktree add` materializes the stale committed
      # copy before this runs, so the old code skipped and served stale skills.
      # _ensure_mirror_gitignored (below) untracks it. PRESERVE a genuine
      # project-local skills dir (untracked, or lacking the canon marker).
      rel="${link#"$wt_dir"/}"
      if [ -n "$(git -C "$wt_dir" ls-files -- "$rel" 2>/dev/null | head -1)" ] && [ -f "$link/sprint/SKILL.md" ]; then
        rm -rf "$link"
        _create_dir_link "$target" "$link"
        echo "  [worktree-link] replaced committed mirror: $link -> $target"
      fi
      continue   # replaced above, or a genuine project-local dir — leave it alone
    else
      mkdir -p "$(dirname "$link")"
      _create_dir_link "$target" "$link"
    fi
    echo "  [worktree-link] $link -> $target"
  done
  upsert_gate_agents "$wt_dir"
  _ensure_mirror_gitignored "$wt_dir"
}

register_project() {
  local project_dir
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [[ "$project_dir" == "$SKILLS_ROOT" ]] && return 0
  mkdir -p "$(dirname "$PROJECTS_FILE")"
  grep -qxF "$project_dir" "$PROJECTS_FILE" 2>/dev/null || echo "$project_dir" >> "$PROJECTS_FILE"
}

deregister_project() {
  local project_dir
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [ -f "$PROJECTS_FILE" ] || return 0
  local tmp
  tmp=$(mktemp)
  grep -vxF "$project_dir" "$PROJECTS_FILE" > "$tmp" || true
  mv "$tmp" "$PROJECTS_FILE"
  [ -s "$PROJECTS_FILE" ] || rm -f "$PROJECTS_FILE"
}

upsert_skills_symlinks() {
  local project_dir="$1" skill_file="${2:-}" target="$SKILLS_ROOT/skills"
  local link
  for link in "$project_dir/.claude/skills" "$project_dir/.agents/skills"; do
    mkdir -p "$(dirname "$link")"
    if _is_dir_link "$link"; then
      [ "$(_read_dir_link "$link")" = "$target" ] && continue
      _create_dir_link "$target" "$link"
      echo "  [symlink]  updated: $link"
    elif [ -d "$link" ]; then
      # Real directory (project has local skills) — create per-skill entry instead
      if [ -n "$skill_file" ]; then
        local skill_name
        skill_name=$(basename "$(dirname "$skill_file")")
        local skill_dir="$link/$skill_name"
        if [ ! -e "$skill_dir" ]; then
          mkdir -p "$skill_dir"
          ln -sfn "$skill_file" "$skill_dir/SKILL.md"
          echo "  [skill-dir]  created: $skill_dir"
        fi
      fi
    else
      _create_dir_link "$target" "$link"
      echo "  [symlink]  created: $link"
    fi
  done
  # t-f99b: never let the (Windows-junction-visible) mirror get committed → stale worktrees.
  _ensure_mirror_gitignored "$project_dir"
}

remove_skills_symlinks() {
  local project_dir="$1" skill_file="${2:-}" target="$SKILLS_ROOT/skills"
  local link
  for link in "$project_dir/.claude/skills" "$project_dir/.agents/skills"; do
    if _is_dir_link "$link"; then
      if [ -z "$skill_file" ] && [ "$(_read_dir_link "$link")" = "$target" ]; then
        _remove_dir_link "$link"
      fi
    elif [ -d "$link" ] && [ -n "$skill_file" ]; then
      # Real directory — remove per-skill entry if it was canon-managed
      local skill_name
      skill_name=$(basename "$(dirname "$skill_file")")
      local skill_dir="$link/$skill_name"
      if [ -d "$skill_dir" ] && [ -L "$skill_dir/SKILL.md" ] && \
         [ "$(readlink "$skill_dir/SKILL.md")" = "$skill_file" ]; then
        rm -rf "$skill_dir"
        echo "  [skill-dir]  removed: $skill_dir"
      fi
    fi
  done
}
