#!/usr/bin/env bash
# canon-dev.sh — contributor tooling for the canon repo itself
#
# Usage:
#   canon-dev.sh catalog          Regenerate CATALOG.md from current skills
#   canon-dev.sh lint [dir]       Validate skills/ against skill-setup-std conventions
#   canon-dev.sh delete <skill>   Permanently remove a skill from canon

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
SEARCH_DIRS=("$SKILLS_ROOT/standards" "$SKILLS_ROOT/tools" "$SKILLS_ROOT/skills")
# shellcheck source=tools/skill-lib.sh
source "$(dirname "$SCRIPT")/skill-lib.sh"

cmd_catalog() {
  python3 - "$SKILLS_ROOT" <<'PYEOF'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
dirs = [root / "standards", root / "tools", root / "skills"]

def fm(path):
    text = path.read_text(errors="replace")
    m = re.match(r"---\n(.*?)\n---", text, re.S)
    data = {}
    if not m:
        return data
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip()
    return data

items = []
for d in dirs:
    if not d.exists():
        continue
    for p in sorted(set(d.glob("*.md")) | set(d.glob("*/*.md"))):
        data = fm(p)
        if data.get("name"):
            data["path"] = p
            items.append(data)

deps = {}
for item in items:
    for dep in item.get("depends", "").strip("[]").split(","):
        dep = dep.strip()
        if dep:
            deps.setdefault(dep, []).append(item["name"])

def is_standard(item):
    return item["path"].parent.name == "standards"

standards  = [i for i in items if is_standard(i) and i.get("hidden") != "true"]
standalone = [
    i for i in items
    if not is_standard(i) and i.get("hidden") != "true" and i["name"] not in deps
]
subskills = [i for i in items if not is_standard(i) and i["name"] in deps]

lines = [
    "# canon Catalog",
    "",
    "> Static snapshot - run `skills.sh list` for live output.",
    "",
    "## Standalone Skills",
    "",
    "Register these directly into a project with `skills.sh add <name>`.",
    "",
    "| Skill | Category | Description |",
    "|---|---|---|",
]
for item in standalone:
    desc = item.get("summary") or item.get("description", "")
    lines.append(f"| `{item['name']}` | {item.get('category', '')} | {desc} |")

lines += [
    "",
    "## Standards",
    "",
    "Auto-injected / contributor reference — not registered directly.",
    "",
    "| Standard | Category | Description |",
    "|---|---|---|",
]
for item in standards:
    desc = item.get("summary") or item.get("description", "")
    lines.append(f"| `{item['name']}` | {item.get('category', '')} | {desc} |")

lines += [
    "",
    "## Sub-skills",
    "",
    "Imported automatically by the skills above. Do not register directly.",
    "",
    "| Skill | Imported by |",
    "|---|---|",
]
for item in subskills:
    imported_by = ", ".join(sorted(deps.get(item["name"], []))) or "-"
    lines.append(f"| `{item['name']}` | {imported_by} |")

(root / "CATALOG.md").write_text("\n".join(lines) + "\n")
PYEOF
  echo "CATALOG.md updated."
}

cmd_lint() {
  local skills_dir="${1:-$SKILLS_ROOT/skills}" errors=0
  local valid_categories="dev agent-ops ops"

  err() { printf 'skills/%s: %s\n' "$1" "$2"; errors=$((errors + 1)); }

  # Directory format — public skills must live in <name>/SKILL.md, not as flat files.
  while IFS= read -r flat; do
    [ -n "$flat" ] || continue
    printf '%s: skill must be in directory format (<name>/SKILL.md), not a flat file\n' "${flat#"$SKILLS_ROOT"/}"
    errors=$((errors + 1))
  done < <(find "$skills_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null)

  local f slug name desc category tags deps imp sib dep
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    slug=$(basename "$(dirname "$f")")

    # Naming: lowercase, hyphenated, <= 20 chars.
    printf '%s' "$slug" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' \
      || err "$slug/SKILL.md" "directory name must be lowercase and hyphenated"
    [ "${#slug}" -le 20 ] || err "$slug/SKILL.md" "name exceeds 20 characters (${#slug})"

    # Required frontmatter.
    name=$(fm_field "$f" name)
    desc=$(fm_field "$f" description)
    category=$(fm_field "$f" category)
    tags=$(fm_field "$f" tags)
    [ -n "$name" ]     || err "$slug/SKILL.md" "missing required field 'name'"
    [ -n "$desc" ]     || err "$slug/SKILL.md" "missing required field 'description'"
    [ -n "$category" ] || err "$slug/SKILL.md" "missing required field 'category'"
    { [ -n "$tags" ] && [ "$tags" != "[]" ]; } || err "$slug/SKILL.md" "missing required field 'tags'"

    # name must match directory name.
    [ -z "$name" ] || [ "$name" = "$slug" ] || err "$slug/SKILL.md" "name '$name' does not match directory name"

    # Category enum.
    if [ -n "$category" ] && ! printf ' %s ' "$valid_categories" | grep -q " $category "; then
      err "$slug/SKILL.md" "category '$category' not in {dev, agent-ops, ops}"
    fi

    # Imports resolve — paths are relative to the skill file's directory.
    local skill_dir
    skill_dir=$(dirname "$f")
    while IFS= read -r imp; do
      [ -n "$imp" ] || continue
      [ -f "$skill_dir/$imp" ] || err "$slug/SKILL.md" "import '@$imp' does not resolve"
    done < <(grep -oE '^@(\./|\.\./|/)[^[:space:]]+' "$f" | sed 's/^@//')

    # depends graph: sibling imports must be declared; declared deps must resolve.
    # Handles both flat (@./name.md) and directory (@./name/SKILL.md) formats.
    deps=$(resolve_deps "$f")
    while IFS= read -r sib; do
      [ -n "$sib" ] || continue
      printf '%s\n' "$deps" | grep -qx "$sib" \
        || err "$slug/SKILL.md" "imports '$sib' but '$sib' is not in depends"
    done < <(
      grep -oE '^@\.\./[a-z0-9-]+/SKILL\.md' "$f" | sed -E 's#^@\.\./([a-z0-9-]+)/SKILL\.md#\1#'
    )
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      find_skill "$dep" >/dev/null 2>&1 \
        || err "$slug/SKILL.md" "depends entry '$dep' does not resolve to a known skill"
    done < <(printf '%s\n' "$deps")

    # One job: a leaf skill chains actions if its description says "and then".
    if [ -z "$deps" ] && printf '%s' "$desc" | grep -qiE '(^|[^[:alpha:]])and then([^[:alpha:]]|$)'; then
      err "$slug/SKILL.md" "description chains actions ('and then') — split into one job, or compose children via depends:"
    fi

    # Vague description: too short to convey what it does and when to use it.
    if [ -n "$desc" ] && [ "${#desc}" -lt 20 ]; then
      err "$slug/SKILL.md" "description too short (${#desc} chars) — state what it does and when to use it"
    fi
  done < <(find "$skills_dir" -mindepth 2 -name 'SKILL.md' -type f 2>/dev/null)

  if [ "$errors" -eq 0 ]; then
    echo "skills lint: clean"
    return 0
  fi
  printf '\n%d issue(s) found.\n' "$errors"
  return 1
}

cmd_delete() {
  local skill="${1:-}"
  [ -z "$skill" ] && { echo "Usage: canon-dev.sh delete <skill-name>"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found. Run 'skills.sh list' to see available skills."
    exit 1
  }

  local skill_dir
  skill_dir=$(dirname "$skill_file")
  local rel_dir="${skill_dir#$SKILLS_ROOT/}"

  if [[ "$rel_dir" == skills/* ]]; then
    echo "Deleting skill directory: $rel_dir"
    rm -rf "$skill_dir"
  else
    echo "Deleting skill file: ${skill_file#$SKILLS_ROOT/}"
    rm "$skill_file"
  fi

  cmd_catalog >/dev/null

  echo ""
  echo "Deleted: $skill"
  echo "CATALOG.md updated."
  echo "Note: any projects with this skill registered will have a dangling reference — run 'skills.sh remove $skill' in those projects."
}

cmd="${1:-}"
shift || true

case "$cmd" in
  catalog) cmd_catalog "$@" ;;
  lint)    cmd_lint    "$@" ;;
  delete)  cmd_delete  "$@" ;;
  *)
    echo "Usage: canon-dev.sh <catalog|lint|delete> [args]"
    echo ""
    echo "  catalog          Regenerate CATALOG.md from current skills"
    echo "  lint [dir]       Validate skills/ against skill-setup-std conventions"
    echo "  delete <skill>   Permanently remove a skill from canon"
    exit 1
    ;;
esac
