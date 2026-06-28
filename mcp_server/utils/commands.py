import os
import re
import subprocess
from pathlib import Path
from typing import List, Dict, Any, Union

from .parsers import _get_section, _parse_plan_approved, _parse_plan_decision


def add_acceptance_criterion(
    tickets_dir: Path,
    ticket_id: str,
    criterion_text: str,
) -> Dict[str, Any]:
    ticket_dir = tickets_dir / ticket_id
    acceptance_file = ticket_dir / "acceptance.md"

    if not acceptance_file.exists():
        return {"error": f"acceptance.md not found for ticket {ticket_id}"}

    content = acceptance_file.read_text(encoding='utf-8')

    acceptance_heading = "## Acceptance Criteria"
    heading_idx = content.find(acceptance_heading)
    if heading_idx == -1:
        new_content = f"{acceptance_heading}\n- [ ] {criterion_text}\n"
        acceptance_file.write_text(new_content, encoding='utf-8')
        return {"ticket_id": ticket_id, "criterion": criterion_text, "status": "ok"}

    list_start = heading_idx + len(acceptance_heading)
    list_section = content[list_start:].strip()

    if not list_section:
        new_content = content.rstrip() + f"\n- [ ] {criterion_text}\n"
        acceptance_file.write_text(new_content, encoding='utf-8')
        return {"ticket_id": ticket_id, "criterion": criterion_text, "status": "ok"}

    lines = list_section.split('\n')
    # skip leading blank lines before list
    list_start_idx = 0
    while list_start_idx < len(lines) and not lines[list_start_idx].strip():
        list_start_idx += 1

    last_num = 0
    is_numbered = False
    found_existing_items = False

    for i in range(list_start_idx, len(lines)):
        stripped = lines[i].strip()
        if not stripped:
            break
        numbered_match = re.match(r'^(\d+)\.\s*', stripped)
        if numbered_match:
            is_numbered = True
            last_num = int(numbered_match.group(1))
            found_existing_items = True
        elif re.match(r'^[-*]\s*', stripped):
            found_existing_items = True
        else:
            break

    if not found_existing_items:
        new_content = content.rstrip() + f"\n- [ ] {criterion_text}\n"
    elif is_numbered:
        new_num = last_num + 1
        new_content = content.rstrip() + f"\n{new_num}. [ ] {criterion_text}\n"
    else:
        new_content = content.rstrip() + f"\n- [ ] {criterion_text}\n"

    acceptance_file.write_text(new_content, encoding='utf-8')

    return {
        "ticket_id": ticket_id,
        "criterion": criterion_text,
        "status": "ok",
    }


def create_sprint_ticket(
    tickets_dir: Path,
    description: str,
    priority: str,
) -> Dict[str, Any]:
    ticket_id = f"TKT-{os.urandom(4).hex().upper()}"
    ticket_dir = tickets_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    title = description if len(description) <= 50 else description[:47] + "..."
    safe_title = _yaml_escape(title)

    ticket_file = ticket_dir / "ticket.md"
    ticket_file.write_text(
        f"---\nid: {ticket_id}\ntitle: \"{safe_title}\"\nstatus: open\npriority: {priority}\n---\n\n## Description\n{description}\n\n## Acceptance Criteria\n",
        encoding='utf-8'
    )

    acceptance_file = ticket_dir / "acceptance.md"
    acceptance_file.write_text("## Acceptance Criteria\n", encoding='utf-8')

    test_plan_file = ticket_dir / "test_plan.md"
    test_plan_file.write_text("## Test Plan\n", encoding='utf-8')

    return {
        "ticket_id": ticket_id,
        "status": "ok",
    }


VALID_STATUSES = frozenset({"open", "in_progress", "closed", "cancelled", "archived"})


def update_ticket_status(
    tickets_dir: Path,
    ticket_id: str,
    new_status: str,
) -> Dict[str, Any]:
    if new_status not in VALID_STATUSES:
        return {
            "error": (
                f"Invalid status '{new_status}'. "
                f"Must be one of: {', '.join(sorted(VALID_STATUSES))}"
            )
        }

    ticket_file = tickets_dir / ticket_id / "ticket.md"
    if not ticket_file.exists():
        return {"error": f"Ticket {ticket_id} not found"}

    content = ticket_file.read_text(encoding='utf-8')
    new_content = re.sub(r'^status:.*$', f'status: {new_status}', content, flags=re.MULTILINE)
    ticket_file.write_text(new_content, encoding='utf-8')

    return {
        "ticket_id": ticket_id,
        "new_status": new_status,
        "status": "ok",
    }


def list_skills(skills_dir: Path, skill_name: str = None) -> Union[List[Dict[str, Any]], Dict[str, Any]]:
    if not skills_dir.exists():
        return {"error": f"Skills directory not found: {skills_dir}"}

    if skill_name:
        skill_path = skills_dir / skill_name / "SKILL.md"
        if not skill_path.exists():
            return {"error": f"Skill '{skill_name}' not found at {skill_path}"}
        content = skill_path.read_text(encoding='utf-8')
        return {"name": skill_name, "content": content}

    results: List[Dict[str, Any]] = []
    for entry in sorted(skills_dir.iterdir()):
        if not entry.is_dir():
            continue
        skill_file = entry / "SKILL.md"
        if not skill_file.exists():
            continue

        content = skill_file.read_text(encoding='utf-8')
        frontmatter_match = re.search(r'^---\n(.*?)\n---', content, re.DOTALL)
        data = {}
        if frontmatter_match:
            for line in frontmatter_match.group(1).strip().split('\n'):
                if ':' in line:
                    key, value = line.split(':', 1)
                    data[key.strip()] = value.strip()

        is_hidden = data.get("hidden", "false") == "true"
        if is_hidden:
            continue
        results.append({
            "name": data.get("name", entry.name),
            "description": data.get("description", ""),
            "category": data.get("category", ""),
            "tags": _parse_yaml_list(data.get("tags", "")),
            "hidden": is_hidden,
            "depends": _parse_yaml_list(data.get("depends", "")),
            "path": str(skill_file),
        })

    return results


def get_ticket(tickets_dir: Path, ticket_id: str) -> Dict[str, Any]:
    ticket_dir = tickets_dir / ticket_id
    if not ticket_dir.exists():
        return {"error": f"Ticket '{ticket_id}' not found at {ticket_dir}"}

    result = {"ticket_id": ticket_id, "files": {}}
    for fname in ["ticket.md", "acceptance.md", "plan.md", "summary.md", "test_plan.md"]:
        fpath = ticket_dir / fname
        if fpath.exists():
            result["files"][fname] = fpath.read_text(encoding='utf-8')
    plan_path = ticket_dir / "plan.md"
    result["plan"] = {
        "approved": _parse_plan_approved(plan_path),
        "decision": _parse_plan_decision(plan_path),
    }
    return result


def update_ticket_body(
    tickets_dir: Path,
    ticket_id: str,
    body: str,
) -> Dict[str, Any]:
    ticket_file = tickets_dir / ticket_id / "ticket.md"
    if not ticket_file.exists():
        return {"error": f"Ticket {ticket_id} not found"}

    content = ticket_file.read_text(encoding='utf-8')
    if not body.strip():
        return {"error": "Ticket body cannot be empty"}

    frontmatter_match = re.search(r'^(---\n.*?\n---)\n?', content, re.DOTALL)
    if frontmatter_match:
        new_content = frontmatter_match.group(1) + "\n\n" + body.lstrip("\n")
    else:
        new_content = body

    ticket_file.write_text(new_content, encoding='utf-8')
    return {"ticket_id": ticket_id, "status": "ok"}


def read_doc(
    tickets_dir: Path,
    ticket_id: str,
    doc_name: str,
) -> Dict[str, Any]:
    valid_docs = {"acceptance.md", "plan.md", "test_plan.md", "summary.md"}
    if doc_name.lower() not in valid_docs:
        return {
            "error": (
                f"Invalid doc_name '{doc_name}'. "
                f"Must be one of: {', '.join(sorted(valid_docs))}"
            )
        }

    doc_path = tickets_dir / ticket_id / doc_name
    if not doc_path.exists():
        return {"error": f"Document '{doc_name}' not found for ticket {ticket_id}"}

    content = doc_path.read_text(encoding='utf-8')
    return {
        "ticket_id": ticket_id,
        "doc_name": doc_name,
        "content": content,
    }


def write_doc(
    tickets_dir: Path,
    ticket_id: str,
    doc_name: str,
    content: str,
) -> Dict[str, Any]:
    valid_docs = {"acceptance.md", "plan.md", "test_plan.md", "summary.md"}
    if doc_name.lower() not in valid_docs:
        return {
            "error": (
                f"Invalid doc_name '{doc_name}'. "
                f"Must be one of: {', '.join(sorted(valid_docs))}"
            )
        }

    doc_path = tickets_dir / ticket_id / doc_name
    ticket_dir = tickets_dir / ticket_id
    if not ticket_dir.exists():
        return {"error": f"Ticket {ticket_id} not found"}

    doc_path.parent.mkdir(parents=True, exist_ok=True)
    doc_path.write_text(content, encoding='utf-8')
    return {
        "ticket_id": ticket_id,
        "doc_name": doc_name,
        "status": "ok",
    }


def _yaml_escape(value: str) -> str:
    return (
        value
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def _parse_yaml_list(raw: str) -> List[str]:
    if raw.startswith("[") and raw.endswith("]"):
        inner = raw[1:-1]
        return [p.strip() for p in inner.split(",") if p.strip()]
    return [raw] if raw else []


def git_info(project_root: Path) -> Dict[str, Any]:
    def _run_git(*args: str) -> str:
        try:
            return subprocess.check_output(
                ["git", *args],
                cwd=str(project_root),
                stderr=subprocess.STDOUT,
                text=True,
            ).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            return ""

    branch = _run_git("rev-parse", "--abbrev-ref", "HEAD")
    log_output = _run_git("log", "--oneline", "--format=%H|%an|%s", "-5")
    status_output = _run_git("status", "--porcelain")

    commits = []
    if log_output:
        for line in log_output.splitlines():
            parts = line.strip().split("|", 2)
            if len(parts) == 3:
                commits.append({"hash": parts[0], "author": parts[1], "subject": parts[2]})
            elif len(parts) == 2:
                commits.append({"hash": parts[0], "author": parts[1], "subject": ""})
            elif parts:
                commits.append({"hash": parts[0], "author": "", "subject": ""})

    modified_count = len([l for l in status_output.splitlines() if l.strip()]) if status_output else 0

    return {
        "branch": branch or "unknown",
        "commits": commits,
        "modified_file_count": modified_count,
    }
