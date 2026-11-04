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

# t-f5e4: a branch or cloud PR controls what is in a worktree, so a link planted at .claude, .agents or deeper must not carry a
# write out of it. Same rule as the Go side (worktreelinks.go underLink / notRegular), held by tests/worktree-links-parity.sh.
# _under_link <root> <path>: 0 when a folder from <root> down to <path>'s parent is a symlink/junction or not a folder
# (canon then writes nothing below it). Stricter than resolving the path: a link that points back inside is refused too.
_under_link() {
  local root="${1%/}" rel part cur
  rel="$(dirname "$2")"; rel="${rel#"$root"}"; rel="${rel#/}"
  [ -n "$rel" ] || return 1
  cur="$root"
  while [ -n "$rel" ]; do
    part="${rel%%/*}"; cur="$cur/$part"
    case "$rel" in */*) rel="${rel#*/}" ;; *) rel="" ;; esac
    [ -e "$cur" ] || [ -L "$cur" ] || return 1   # not there yet: mkdir makes a real folder
    _is_dir_link "$cur" && return 0
    [ -d "$cur" ] || return 0
  done
  return 1
}
# _not_regular <path>: 0 when <path> exists and is not a plain file (a symlink, even a dangling one, or a folder).
_not_regular() { { [ -e "$1" ] || [ -L "$1" ]; } && { [ -L "$1" ] || [ ! -f "$1" ]; }; }

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
  local gi entry rel tmp
  gi="$(_ignore_file "$project_dir")"
  if _not_regular "$gi"; then echo "  [gitignore] $gi is not a regular file — left as is"; return 0; fi
  # t-c433: no trailing slash — git treats a symlink as a file, so "/.claude/skills/" (directories only) never
  # matched the link on macOS/Linux; the slash-less form matches a symlink, a directory and a Windows junction.
  for entry in "/.claude/skills" "/.agents/skills"; do
    # The directory-only line an earlier canon wrote: replace it in place, or drop it if the slash-less line exists.
    if has_line "$entry/" "$gi"; then
      tmp="$(mktemp)"
      HAVE="$(has_line "$entry" "$gi" && echo 1 || echo 0)" E="$entry" awk 'BEGIN { e = ENVIRON["E"] }
        { l = $0; sub(/\r$/, "", l) } l == e "/" { if (ENVIRON["HAVE"] == "0") print e; next } { print }' "$gi" > "$tmp"
      cat "$tmp" > "$gi"; rm -f "$tmp"
      echo "  [gitignore] $entry (replaced $entry/)"
    fi
    if ! has_line "$entry" "$gi"; then
      [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ] && echo >> "$gi"
      printf '%s\n' "$entry" >> "$gi"
      echo "  [gitignore] $entry"
    fi
    rel="${entry#/}"
    if [ -n "$(git -C "$project_dir" ls-files -- "$rel" 2>/dev/null | head -1)" ]; then
      git -C "$project_dir" rm -r --cached --quiet -- "$rel" >/dev/null 2>&1 || true
      echo "  [gitignore] untracked previously-committed mirror: $rel"
    fi
  done
  # t-ba62: the close's run records (the gates' run log, gate-snapshot.sh's snapshot and scope) are never committed; left
  # untracked in a worktree they made `tkt worktree-reset` refuse. Added only, never untracked from an earlier commit.
  for entry in "/.claude/subagent-runs.jsonl" "/.tickets/*/gate-snapshot.txt*"; do
    if ! has_line "$entry" "$gi"; then
      [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ] && echo >> "$gi"
      printf '%s\n' "$entry" >> "$gi"
      echo "  [gitignore] $entry"
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
  if _under_link "$project_dir" "$link"; then echo "  [agents]  $link is under a link — left as is"; return 0; fi
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
  elif [ -d "$link" ] && _canon_only_agents_dir "$link" && _remove_canon_only_dir "$link"; then
    # t-38ab: empty, or only canon's own marked files: the link, not copies that age between refreshes
    _create_dir_link "$target" "$link"
    echo "  [agents]  replaced a folder of canon's own files with a link: $link"
    _ensure_agents_link_gitignored "$project_dir"
  elif [ -d "$link" ]; then
    for src in "$target"/canon-*.md; do
      dst="$link/$(basename "$src")"
      if _not_regular "$dst"; then
        echo "  [agents]  $dst is not a regular file — left as is"
        continue
      fi
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

# _is_linked_worktree <dir> — git's own folder differs from the repository's common one only in a linked worktree; a
# submodule or a --separate-git-dir checkout also has a .git FILE but is a main checkout.
_is_linked_worktree() {
  local both
  both="$(git -C "$1" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$both" | sed -n 1p)" != "$(printf '%s\n' "$both" | sed -n 2p)" ]
}
# _ignore_file <dir> — t-74d8 (user's choice): where <dir>'s ignore lines go. In a linked worktree git's own info/exclude,
# untracked and shared by the repository's worktrees, so linking never leaves a .gitignore change on a sprint's branch (one
# blocked `tkt land --finish`); in a main checkout (a submodule and a --separate-git-dir one too) the project's .gitignore.
# Same rule as the Go side (internal/common/worktreelinks.go ignoreFile), held by tests/worktree-links-parity.sh.
_ignore_file() {
  local dir="$1" p
  if _is_linked_worktree "$dir"; then
    p="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null)"
    if [ -n "$p" ]; then
      case "$p" in /*|[A-Za-z]:*) ;; *) p="$dir/$p" ;; esac
      mkdir -p "$(dirname "$p")"
      printf '%s\n' "$p"; return 0
    fi
  fi
  printf '%s\n' "$dir/.gitignore"
}
# A linked .claude/agents is local (like the skills mirror, t-f99b) and must never be committed.
_ensure_agents_link_gitignored() {
  # No trailing slash: git treats a symlink as a file, so "/.claude/agents/" (directories only) would not
  # match it on macOS/Linux — only a Windows junction, which git sees as a directory.
  local project_dir="$1" gi entry="/.claude/agents"
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  gi="$(_ignore_file "$project_dir")"
  _not_regular "$gi" && return 0
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
    if _under_link "$wt_dir" "$link"; then echo "  [worktree-link] $link is under a link — left as is"; continue; fi
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

# _in_system_temp <dir> — t-acfa: 0 when <dir> is inside the system temp folder: $TMPDIR (on macOS /var/folders/…/T, also when TMPDIR is unset), %TEMP%
# and %TMP% on Windows, where Git Bash's /tmp is that folder too. A project there is a scratch copy (tests, gates), and the registry
# is what uninstall walks and edits, so it is never registered. /tmp and /private/tmp elsewhere stay allowed: people keep demos there.
_in_system_temp() {
  local d t r
  d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  # with TMPDIR unset (cron, env -i), macOS's per-user temp folder is still /var/folders/…/T: ask the system for it
  for t in "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}" "${TEMP:-}" "${TMP:-}"; do
    [ -n "$t" ] || continue
    case "$t" in *\\*|?:*) t="$(cygpath -u "$t" 2>/dev/null)" || continue ;; esac
    r="$(cd "$t" 2>/dev/null && pwd -P)" || continue
    case "$d/" in "${r%/}"/*) return 0 ;; esac
  done
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) case "$d/" in /tmp/*) return 0 ;; esac ;; esac
  return 1
}

# _rewrite_projects <line to drop, or ""> [<line to add>] — t-acfa: rewrites the registry without the dropped line and
# without entries whose folder no longer exists, adding <line> once; says how many vanished folders went, only when any did.
_rewrite_projects() {
  local drop="$1" add="${2:-}" tmp p gone=0 seen=0
  mkdir -p "$(dirname "$PROJECTS_FILE")"
  tmp="$(mktemp "$(dirname "$PROJECTS_FILE")/.projects.XXXXXX")" \
    || { echo "  [registry]  could not write $PROJECTS_FILE: the project list is unchanged" >&2; return 0; }
  if [ -f "$PROJECTS_FILE" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
      [ -n "$p" ] || continue
      [ "$p" = "$drop" ] && continue
      if [ ! -d "$p" ]; then gone=$((gone + 1)); continue; fi
      [ "$p" = "$add" ] && seen=1
      printf '%s\n' "$p" >> "$tmp"
    done < "$PROJECTS_FILE"
  fi
  if [ -n "$add" ] && [ "$seen" = 0 ]; then printf '%s\n' "$add" >> "$tmp"; fi
  mv "$tmp" "$PROJECTS_FILE"
  [ -s "$PROJECTS_FILE" ] || rm -f "$PROJECTS_FILE"
  if [ "$gone" -gt 0 ]; then echo "  [registry]  dropped $gone entr$([ "$gone" = 1 ] && echo y || echo ies) whose folder no longer exists"; fi
  return 0
}

register_project() {
  local project_dir
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [[ "$project_dir" == "$SKILLS_ROOT" ]] && return 0
  if _in_system_temp "$project_dir"; then
    echo "  [registry]  not registered: $project_dir is in the system temp folder (uninstall will not touch it)"
    return 0
  fi
  _rewrite_projects "" "$project_dir"
}

deregister_project() {
  local project_dir
  project_dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [ -f "$PROJECTS_FILE" ] || return 0
  _rewrite_projects "$project_dir"
}

# t-38ab: a real folder where canon's link belongs (empty, or the copies Windows `ln` makes) may be replaced by the link only when
# everything in it is proven canon's. _canon_only_skills_dir: 0 when <dir> is empty or holds only folders named after a canon skill whose
# files are links into canon or byte-identical to canon's current ones. A project-local skill, a differing (stale) copy, a link
# elsewhere or any other entry makes it 1: nothing is removed.
_canon_only_skills_dir() {
  local dir="$1" e f rel cs t root_p
  [ -d "$dir" ] && ! _is_dir_link "$dir" || return 1
  root_p="$(cd -P "$SKILLS_ROOT" 2>/dev/null && pwd -P)" || root_p="$SKILLS_ROOT"
  while IFS= read -r e; do   # find, not a glob: "$dir"/.[!.]* never matches a name starting with ".." (a user's file would be deleted)
    cs="$SKILLS_ROOT/skills/$(basename "$e")"
    { [ -d "$cs" ] && [ -d "$e" ] && [ ! -L "$e" ]; } || return 1
    while IFS= read -r f; do
      rel="${f#"$e"/}"
      if [ -L "$f" ]; then
        t="$(readlink "$f")"
        case "$t" in "$SKILLS_ROOT"/skills/*|"$root_p"/skills/*) ;; *) [ -n "$(canon_current_path "$t" 2>/dev/null)" ] || return 1 ;; esac
      elif [ -f "$f" ]; then
        cmp -s "$f" "$cs/$rel" || return 1
      else
        return 1
      fi
    done < <(find "$e" -mindepth 1 ! -type d 2>/dev/null)
    # a folder inside one that is a junction (Windows) is not walked by find as a link: refuse it, never delete through it
    while IFS= read -r f; do _is_dir_link "$f" && return 1; done < <(find "$e" -mindepth 1 -type d 2>/dev/null)
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
  return 0
}
# _canon_only_agents_dir: 0 when <dir> is empty or holds only canon-*.md files that carry the canon:agent marker (the files
# upsert_gate_agents itself writes and rewrites).
_canon_only_agents_dir() {
  local dir="$1" e
  [ -d "$dir" ] && ! _is_dir_link "$dir" || return 1
  while IFS= read -r e; do
    case "$(basename "$e")" in canon-*.md) ;; *) return 1 ;; esac
    { [ -f "$e" ] && [ ! -L "$e" ] && grep -qF "canon:agent" "$e"; } || return 1
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
  return 0
}
# _remove_canon_only_dir <dir>: after one of the checks above. Deletes the files one by one, then the folders deepest first; rmdir
# refuses a folder anything else appeared in, and the rest stays (returns 1). Never rm -rf: nothing unproven is deleted.
_remove_canon_only_dir() {
  local f
  while IFS= read -r f; do rm -f -- "$f"; done < <(find "$1" -mindepth 1 ! -type d 2>/dev/null)
  while IFS= read -r f; do rmdir -- "$f" 2>/dev/null || return 1; done < <(find "$1" -depth -type d 2>/dev/null)
}
# _link_skill_children <skill_dir> <canon skill dir>: the per-skill layout served only SKILL.md; every other child of canon's skill
# (reference/, gates/, evals/, any file) is linked too (a junction for a folder and a copy for a file on Windows). Only what is absent
# is added: a child the project already has is its own.
_link_skill_children() {
  local dst="$1" src="$2" c name
  for c in "$src"/* "$src"/.[!.]*; do
    [ -e "$c" ] || continue
    name="$(basename "$c")"
    [ "$name" = SKILL.md ] && continue
    [ -e "$dst/$name" ] || [ -L "$dst/$name" ] && continue
    if [ -d "$c" ] && _is_windows; then _create_dir_link "$c" "$dst/$name"; else ln -sfn "$c" "$dst/$name"; fi
  done
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
      # t-38ab: empty, or only canon's own files: the link, not a folder that ages
      if ! _under_link "$project_dir" "$link" && _canon_only_skills_dir "$link"; then
        if _remove_canon_only_dir "$link"; then
          _create_dir_link "$target" "$link"
          echo "  [symlink]  replaced a folder of canon's own files with a link: $link"
          continue
        fi
        echo "  [symlink]  $link changed while it was being cleared — left as is"
      fi
      # Real directory (project has local skills) — create per-skill entry instead
      if [ -n "$skill_file" ]; then
        local skill_name
        skill_name=$(basename "$(dirname "$skill_file")")
        local skill_dir="$link/$skill_name"
        if [ ! -e "$skill_dir" ]; then
          mkdir -p "$skill_dir"
          ln -sfn "$skill_file" "$skill_dir/SKILL.md"
          echo "  [skill-dir]  created: $skill_dir"
        elif [ -L "$skill_dir/SKILL.md" ] && [ "$(canon_current_path "$(readlink "$skill_dir/SKILL.md")")" = "$skill_file" ]; then
          ln -sfn "$skill_file" "$skill_dir/SKILL.md"   # t-50f7: the old location's link, re-pointed at current
          echo "  [skill-dir]  updated: $skill_dir"
        fi
        [ -d "$skill_dir" ] && [ ! -L "$skill_dir" ] && ! _is_dir_link "$skill_dir" && _link_skill_children "$skill_dir" "$(dirname "$skill_file")"
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
