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

fm_field() {
  local file="$1" field="$2"
  awk -v key="$field" '
    BEGIN { in_fm=0 }
    /^---$/ { in_fm=!in_fm; next }
    in_fm && substr($0, 1, length(key)+1) == key":" {
      val = substr($0, length(key)+2); sub(/^ +/, "", val); print val; exit
    }
  ' "$file"
}

find_skill() {
  local name="$1"
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ "$(fm_field "$f" name)" = "$name" ] && echo "$f" && return 0
    done < <(find "$dir" -name "*.md" -type f 2>/dev/null)
  done
  return 1
}

resolve_deps() {
  local file="$1" dep_str
  dep_str=$(fm_field "$file" depends)
  [ -z "$dep_str" ] && return 0
  echo "$dep_str" | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -v '^$' || true
}

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
    for p in sorted(d.glob("*.md")):
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

  # Flat location — no skills nested in subdirectories.
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    printf '%s: skill must live flat under skills/, not in a subdirectory\n' "${nested#"$SKILLS_ROOT"/}"
    errors=$((errors + 1))
  done < <(find "$skills_dir" -mindepth 2 -name '*.md' -type f 2>/dev/null)

  local f base stem name desc category tags deps imp sib dep
  for f in "$skills_dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f"); stem="${base%.md}"

    # Naming: lowercase, hyphenated, <= 20 chars.
    printf '%s' "$stem" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' \
      || err "$base" "filename must be lowercase and hyphenated"
    [ "${#stem}" -le 20 ] || err "$base" "name exceeds 20 characters (${#stem})"

    # Required frontmatter.
    name=$(fm_field "$f" name)
    desc=$(fm_field "$f" description)
    category=$(fm_field "$f" category)
    tags=$(fm_field "$f" tags)
    [ -n "$name" ]     || err "$base" "missing required field 'name'"
    [ -n "$desc" ]     || err "$base" "missing required field 'description'"
    [ -n "$category" ] || err "$base" "missing required field 'category'"
    { [ -n "$tags" ] && [ "$tags" != "[]" ]; } || err "$base" "missing required field 'tags'"

    # name must match filename.
    [ -z "$name" ] || [ "$name" = "$stem" ] || err "$base" "name '$name' does not match filename"

    # Category enum.
    if [ -n "$category" ] && ! printf ' %s ' "$valid_categories" | grep -q " $category "; then
      err "$base" "category '$category' not in {dev, agent-ops, ops}"
    fi

    # Imports resolve.
    while IFS= read -r imp; do
      [ -n "$imp" ] || continue
      [ -f "$skills_dir/$imp" ] || err "$base" "import '@$imp' does not resolve"
    done < <(grep -oE '^@[^[:space:]]+' "$f" | sed 's/^@//')

    # depends graph: sibling imports must be declared; declared deps must resolve.
    deps=$(resolve_deps "$f")
    while IFS= read -r sib; do
      [ -n "$sib" ] || continue
      printf '%s\n' "$deps" | grep -qx "$sib" \
        || err "$base" "imports '@./$sib.md' but '$sib' is not in depends"
    done < <(grep -oE '^@\./[^[:space:]]+\.md' "$f" | sed -E 's#^@\./(.*)\.md#\1#')
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      find_skill "$dep" >/dev/null 2>&1 \
        || err "$base" "depends entry '$dep' does not resolve to a known skill"
    done < <(printf '%s\n' "$deps")

    # One job: a leaf skill chains actions if its description says "and then".
    if [ -z "$deps" ] && printf '%s' "$desc" | grep -qiE '(^|[^[:alpha:]])and then([^[:alpha:]]|$)'; then
      err "$base" "description chains actions ('and then') — split into one job, or compose children via depends:"
    fi

    # Vague description: too short to convey what it does and when to use it.
    if [ -n "$desc" ] && [ "${#desc}" -lt 20 ]; then
      err "$base" "description too short (${#desc} chars) — state what it does and when to use it"
    fi
  done

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
