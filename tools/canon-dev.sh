#!/usr/bin/env bash
# canon-dev.sh — contributor tooling for the canon repo itself
#
# Usage:
#   canon-dev.sh catalog          Regenerate CATALOG.md from current skills
#   canon-dev.sh lint [dir] [--strict]  Validate skills/ against skill-setup-std conventions
#                                       (structural errors block; prose/best-practice
#                                       findings are advisory warnings unless --strict)
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
  local skills_dir="" strict=0 errors=0 warnings=0
  local valid_categories="dev agent-ops ops"
  local _arg
  for _arg in "$@"; do
    case "$_arg" in
      --strict) strict=1 ;;
      -*) echo "lint: unknown option '$_arg' (supported: --strict)" >&2; return 2 ;;
      *) skills_dir="$_arg" ;;
    esac
  done
  skills_dir="${skills_dir:-$SKILLS_ROOT/skills}"

  # Blocking structural errors.
  err() { printf 'skills/%s: %s\n' "$1" "$2"; errors=$((errors + 1)); }
  # Advisory prose/best-practice findings — non-blocking, unless --strict promotes them.
  warn() {
    if [ "$strict" -eq 1 ]; then
      err "$1" "$2"
    else
      printf 'skills/%s: warning: %s\n' "$1" "$2"
      warnings=$((warnings + 1))
    fi
  }

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

  # --- Advisory prose / best-practice checks (non-blocking unless --strict) ---
  # Mechanical/deterministic tier: flags candidate no-ops, weak descriptions, stale
  # patterns, and missing evals. Deeper semantic quality is the judgment tier's job
  # (skills/repo-workflow-audit, skill-eval). Degrades gracefully without python3.
  local py_bin="${CANON_DEV_PYTHON:-python3}"
  if command -v "$py_bin" >/dev/null 2>&1; then
    local prose_tmp prose_rel prose_msg
    prose_tmp="$(mktemp)"
    "$py_bin" - "$skills_dir" "$(dirname "$SCRIPT")/no-op-phrases.txt" > "$prose_tmp" <<'PYEOF' || true
import json, os, re, sys, pathlib

skills_dir = pathlib.Path(sys.argv[1])
noop_file = pathlib.Path(sys.argv[2])

def out(rel, msg):
    print(f"{rel}\t{msg}")

# Canonical no-op / filler phrase list (shared with repo-workflow-audit + skill-export).
noops = []
try:
    for line in noop_file.read_text(errors="replace").splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            noops.append(s.lower())
except FileNotFoundError:
    pass

def split_fm(text):
    m = re.match(r"---\n(.*?)\n---\n?(.*)", text, re.S)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return fm, m.group(2)

def clean_line(line):
    # Drop backticked and double-quoted spans so quoted examples don't false-positive.
    line = re.sub(r"`[^`]*`", " ", line)
    line = re.sub(r'"[^"]*"', " ", line)
    return line

skill_files = sorted(skills_dir.glob("*/SKILL.md"))

# Build the depends graph (for hidden-consistency) from the walked tree only.
skills = []
depended = set()
for f in skill_files:
    fm, body = split_fm(f.read_text(errors="replace"))
    name = fm.get("name") or f.parent.name
    skills.append((f, fm, body, name))
    for d in fm.get("depends", "").strip("[]").split(","):
        d = d.strip()
        if d:
            depended.add(d)

person_pat = re.compile(
    r"(^|[^a-z])(i can|i'll|i will|i help|we can|we will|you can|you should|"
    r"use this (to|skill|when)|let me|helps you)([^a-z]|$)")
trigger_pat = re.compile(r"\b(use when|use to|use for|when |after |before |trigger)")
time_pat = re.compile(
    r"\b(before|after|until|as of|since)\s+\w*\s*20\d\d\b"
    r"|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+20\d\d\b"
    r"|\bin\s+20\d\d\b", re.I)

for f, fm, body, name in skills:
    rel = os.path.relpath(f, skills_dir)
    hidden = fm.get("hidden", "").strip().lower() == "true"
    desc = fm.get("description", "").strip()
    wtu = fm.get("when_to_use", "").strip()

    # Description quality (skip when missing — a blocking check already covers that).
    if desc:
        dl = desc.lower()
        if person_pat.search(dl) or re.match(r"^(i|we)\s", dl):
            out(rel, "SP-DESC-PERSON description uses first/second person — write in third "
                     "person (it is injected into the system prompt)")
        if not hidden and not trigger_pat.search(dl):
            out(rel, "SP-DESC-TRIGGER description has no when-to-use signal — state what it "
                     "does AND when to use it")
        if len(desc) + len(wtu) > 1536:
            out(rel, f"SP-DESC-CAP description+when_to_use is {len(desc)+len(wtu)} chars "
                     "(>1536 listing cap) — move extra triggers to when_to_use / trim")

    # Body scans (no-ops, time-sensitive, @-imports), skipping fenced code.
    in_fence = False
    time_flagged = False
    for i, raw in enumerate(body.splitlines(), 1):
        st = raw.strip()
        if st.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if re.match(r"^@(\./|\.\./|/)", st):
            out(rel, f"SP-ATIMPORT '@' import (line {i}) is deprecated (skill-setup-std) — "
                     "load deps via an explicit Read instruction + depends:")
        lead = re.sub(r"^\s*([-*+]|\d+\.|#{1,6}|>)\s*", "", clean_line(raw)).strip().lower()
        if lead:
            for ph in noops:
                if lead.startswith(ph):
                    rest = lead[len(ph):]
                    if rest == "" or not rest[0].isalnum():
                        out(rel, f"SP-NOOP no-op/filler phrase '{ph}' (line {i}) — remove the "
                                 "line; if agent output wouldn't change, delete it (No-Op "
                                 "Test). A linter flags candidates; evals confirm.")
                        break
        if not time_flagged and time_pat.search(raw):
            out(rel, f"SP-TIME time-sensitive wording (line {i}) — move legacy notes to an "
                     "'Old patterns' section (skill-setup-std)")
            time_flagged = True

    if len(body.splitlines()) > 500:
        out(rel, f"SP-BODYLEN SKILL.md body is {len(body.splitlines())} lines (>500) — split "
                 "into reference files (Progressive disclosure)")

    # hidden consistency — the check skill-setup-std's Validation section claims exists.
    if name in depended and not hidden:
        out(rel, f"SP-HIDDEN '{name}' is in another skill's depends: but is not marked "
                 "hidden: true — mark it hidden, or keep it standalone deliberately")

    # Evals presence/count (skill-setup-std Testing).
    evals_path = f.parent / "evals" / "evals.json"
    if not evals_path.exists():
        out(rel, "SP-EVALS-MISSING no evals/evals.json — ship >=3 execution eval cases "
                 "(skill-setup-std Testing)")
    else:
        try:
            data = json.loads(evals_path.read_text(errors="replace"))
            cases = data.get("evals", []) if isinstance(data, dict) else (
                data if isinstance(data, list) else [])
            n = len(cases) if isinstance(cases, list) else 0
            if n < 3:
                out(rel, f"SP-EVALS-COUNT evals.json has {n} case(s) — standard expects >=3")
        except Exception:
            out(rel, "SP-EVALS-INVALID evals/evals.json is not valid JSON")

# Reference/gate files: a table of contents once they exceed 100 lines.
for ref in sorted(list(skills_dir.glob("*/reference/*.md")) + list(skills_dir.glob("*/gates/*.md"))):
    lines = ref.read_text(errors="replace").splitlines()
    if len(lines) > 100:
        head = "\n".join(lines[:20]).lower()
        if "contents" not in head and "](#" not in head:
            out(os.path.relpath(ref, skills_dir),
                f"SP-REF-TOC reference file is {len(lines)} lines (>100) with no table of "
                "contents — add one so previews show full scope (Progressive disclosure)")
PYEOF
    while IFS=$'\t' read -r prose_rel prose_msg; do
      [ -n "$prose_rel" ] || continue
      warn "$prose_rel" "$prose_msg"
    done < "$prose_tmp"
    rm -f "$prose_tmp"
  else
    echo "note: advisory prose checks skipped ($py_bin not found)"
  fi

  if [ "$errors" -eq 0 ]; then
    if [ "$warnings" -eq 0 ]; then
      echo "skills lint: clean"
    else
      printf 'skills lint: clean (%d warning(s))\n' "$warnings"
    fi
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
    echo "  lint [dir] [--strict]  Validate skills/ against skill-setup-std conventions"
    echo "  delete <skill>   Permanently remove a skill from canon"
    exit 1
    ;;
esac
