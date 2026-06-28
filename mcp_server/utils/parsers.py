import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Dict, Any
from .models import Ticket

def parse_tickets(tickets_dir: Path) -> List[Ticket]:
    tickets = []
    if not tickets_dir.exists():
        return tickets
    
    # Iterate through subdirectories in .tickets/
    for subdir in tickets_dir.iterdir():
        if subdir.is_dir():
            ticket_file = subdir / "ticket.md"
            if ticket_file.exists():
                content = ticket_file.read_text(encoding='utf-8')
                # Simple YAML-like frontmatter parsing
                # Looking for id, title, status, etc.
                data = {}
                # Try frontmatter first (---\n...\n---), then fall back to first line
                frontmatter_match = re.search(r'^---\n(.*?)\n---', content, re.MULTILINE | re.DOTALL)
                if frontmatter_match:
                    lines = frontmatter_match.group(1).strip().split('\n')
                    for line in lines:
                        if ':' in line:
                            key, value = line.split(':', 1)
                            data[key.strip().lower()] = value.strip()
                else:
                    # Fall back: parse first line as id, rest as body
                    first_line = content.strip().split('\n', 1)[0]
                    if first_line:
                        data['id'] = first_line.strip()
                
                # Extract Acceptance Criteria from the body
                acceptance_criteria = ""
                body_match = re.search(r'^## Acceptance Criteria\n(.*?)(?=\n\n##|$)', content, re.DOTALL)
                if body_match:
                    acceptance_criteria = body_match.group(1).strip()
                
                # Extract description: everything between ## Description and the next heading
                description = ""
                desc_match = re.search(r'^## Description\n(.*?)(?=\n\n##|$)', content, re.DOTALL)
                if desc_match:
                    description = desc_match.group(1).strip()
                
                tickets.append(Ticket(
                    id=data.get('id', 'unknown'),
                    status=data.get('status', 'unknown'),
                    title=data.get('title', 'No Title'),
                    description=description,
                    acceptance_criteria=acceptance_criteria
                ))
    return tickets

def parse_handoff(handoff_path: Path) -> Dict[str, Any]:
    if not handoff_path.exists():
        return {"active_tasks": []}
    
    content = handoff_path.read_text(encoding='utf-8')
    active_tasks = []
    
    # Extract Active Tasks section — handle both bold and plain formats
    tasks_match = re.search(r'## Active Tasks\n(.*?)(?=\n\n##|$)', content, re.DOTALL)
    if tasks_match:
        tasks_section = tasks_match.group(1).strip()
        for line in tasks_section.split('\n'):
            line = line.strip()
            # Strip markdown bold markers (**text** or *text*)
            line = re.sub(r'\*\*(.*?)\*\*', r'\1', line)
            line = re.sub(r'\*(.*?)\*', r'\1', line)
            if line and line.startswith('- '):
                active_tasks.append(line[2:].strip())
                
    return {
        "active_tasks": active_tasks,
        "context": "Extracted from HANDOFF.md"
    }

def add_acceptance_criterion(
    tickets_dir: Path,
    ticket_id: str,
    criterion_text: str,
) -> Dict[str, Any]:
    """Append a new acceptance criterion to a ticket's acceptance.md."""
    ticket_dir = tickets_dir / ticket_id
    acceptance_file = ticket_dir / "acceptance.md"

    if not acceptance_file.exists():
        return {"error": f"acceptance.md not found for ticket {ticket_id}"}

    content = acceptance_file.read_text(encoding='utf-8')
    lines = content.splitlines()

    # Find the last line that looks like a list item
    last_index = -1
    list_type = None # 'bullet' or 'numbered'
    last_num = 0

    for i in range(len(lines) - 1, -1, -1):
        line = lines[i].strip()
        if not line:
            continue
        
        # Check for bullet: - [ ] or * [ ]
        bullet_match = re.match(r'^([-*])\s*\[\s*\]\s*', line)
        if bullet_match:
            last_index = i
            list_type = 'bullet'
            break
            
        # Check for numbered: 1. [ ] or 1. 
        numbered_match = re.match(r'^(\d+)\.\s*\[\s*\]\s*', line)
        if numbered_match:
            last_index = i
            list_type = 'numbered'
            last_num = int(numbered_match.group(1))
            break
        
        # Also check for numbered without [ ] just in case
        numbered_match_no_checkbox = re.match(r'^(\d+)\.\s*', line)
        if numbered_match_no_checkbox:
            last_index = i
            list_type = 'numbered'
            last_num = int(numbered_match_no_checkbox.group(1))
            break

    if last_index == -1:
        # No list items found, default to bullet
        if not content.strip() or content.strip() == "## Acceptance Criteria":
            new_content = f"## Acceptance Criteria\n- [ ] {criterion_text}\n"
        else:
            new_content = content.rstrip() + f"\n- [ ] {criterion_text}\n"
    elif list_type == 'bullet':
        new_content = content.rstrip() + f"\n- [ ] {criterion_text}\n"
    elif list_type == 'numbered':
        new_num = last_num + 1
        new_content = content.rstrip() + f"\n{new_num}. [ ] {criterion_text}\n"
    else:
        # Fallback
        new_content = content.rstrip() + f"\n- [ ] {criterion_text}\n"

    acceptance_file.write_text(new_content, encoding='utf-8')

    return {
        "ticket_id": ticket_id,
        "criterion": criterion_text,
        "status": "ok",
    }

def _get_section(content: str, heading: str) -> str:
    """Extract content under a ## heading until the next ## heading or end."""
    pattern = re.compile(
        r'^##\s+' + re.escape(heading) + r'\s*$(.*?)(?=^##\s|\Z)',
        re.MULTILINE | re.DOTALL
    )
    m = pattern.search(content)
    return m.group(1).strip() if m else ""


def _parse_plan_approved(plan_path: Path) -> bool:
    """Check if plan.md's ## Sign-off section has a checked item."""
    if not plan_path.exists():
        return False
    content = plan_path.read_text(encoding='utf-8')
    signoff = _get_section(content, 'Sign-off')
    return bool(re.search(r'^\s*[-*]\s+\[[xX]\]\s+\S', signoff, re.MULTILINE))


def _parse_plan_decision(plan_path: Path) -> str:
    """Extract first ### heading from ## Decisions section of plan.md."""
    if not plan_path.exists():
        return ""
    content = plan_path.read_text(encoding='utf-8')
    decisions = _get_section(content, 'Decisions')
    for line in decisions.split('\n'):
        line = line.strip()
        if line.startswith('### '):
            return line[4:].strip()
    return ""


AGENT_RUN_LOG_PATHS = [
    ".canon/subagent-runs.jsonl",
    ".claude/subagent-runs.jsonl",
    ".opencode/subagent-runs.jsonl",
    ".vscode/subagent-runs.jsonl",
]


def log_subagent_run(
    project_root: Path,
    agent_id: str,
    agent_type: str = "agent",
    session_id: str = "",
) -> Dict[str, Any]:
    """Log a subagent run to .canon/subagent-runs.jsonl (shared canonical path).

    Called by sprint complete protocol after the evaluator subagent finishes,
    making the audit trail IDE-agnostic. Also written by Claude Code's
    SubagentStop hook (subagent-log.sh) for backward compat.
    """
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = {
        "ts": ts,
        "session_id": session_id,
        "agent_id": agent_id,
        "agent_type": agent_type,
        "transcript_path": "",
    }
    log_dir = project_root / ".canon"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "subagent-runs.jsonl"
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
    return {"status": "ok", "entry": entry}


def _check_subagent_run(project_root: Path, run_epoch: int) -> bool:
    """Cross-check a run epoch against subagent-runs.jsonl across all IDE log paths (±60 min window)."""
    for rel in AGENT_RUN_LOG_PATHS:
        jsonl_path = project_root / rel
        if not jsonl_path.exists():
            continue
        try:
            with open(jsonl_path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d = json.loads(line)
                        ts = d.get('ts', '')
                        if not ts:
                            continue
                        entry_epoch = int(datetime.strptime(
                            ts, '%Y-%m-%dT%H:%M:%SZ'
                        ).replace(tzinfo=timezone.utc).timestamp())
                        if abs(entry_epoch - run_epoch) <= 3600:
                            return True
                    except Exception:
                        pass
        except Exception:
            pass
    return False


def get_sprint_board(project_root: Path) -> Dict[str, Any]:
    """Combine ticket parsing and handoff parsing into a single structured response."""
    tickets_dir = project_root / ".tickets"
    tickets = parse_tickets(tickets_dir)
    handoff = parse_handoff(project_root / "HANDOFF.md")
    
    ticket_list = []
    for t in tickets:
        plan_path = tickets_dir / t.id / "plan.md"
        ticket_list.append({
            "id": t.id,
            "status": t.status,
            "title": t.title,
            "description": t.description,
            "acceptance_criteria": t.acceptance_criteria,
            "plan_approved": _parse_plan_approved(plan_path),
            "plan_decision": _parse_plan_decision(plan_path),
        })
    
    return {
        "tickets": ticket_list,
        "handoff": handoff,
        "project_root": str(project_root)
    }

def create_sprint_ticket(
    tickets_dir: Path,
    description: str,
    priority: str,
) -> Dict[str, Any]:
    """Create a new sprint ticket directory and files."""
    ticket_id = f"TKT-{os.urandom(4).hex().upper()}"
    ticket_dir = tickets_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ticket_file = ticket_dir / "ticket.md"
    ticket_file.write_text(
        f"---\nid: {ticket_id}\ntitle: {description[:50]}...\nstatus: open\npriority: {priority}\n---\n\n## Description\n{description}\n\n## Acceptance Criteria\n",
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

VALID_STATUSES = {"open", "in_progress", "closed", "cancelled", "archived"}


def update_ticket_status(
    tickets_dir: Path,
    ticket_id: str,
    new_status: str,
) -> Dict[str, Any]:
    """Update the status field of an existing ticket's frontmatter."""
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
    
    # Replace status: ... with status: new_status
    new_content = re.sub(r'^status:.*$', f'status: {new_status}', content, flags=re.MULTILINE)
    
    ticket_file.write_text(new_content, encoding='utf-8')

    return {
        "ticket_id": ticket_id,
        "new_status": new_status,
        "status": "ok",
    }

def list_skills(skills_dir: Path, skill_name: str = None) -> Any:
    """Inventory canon skills from the skills/ directory.
    
    If skill_name is provided, returns full content of that skill's SKILL.md.
    Otherwise returns metadata for all skills.
    """
    if not skills_dir.exists():
        return {"error": f"Skills directory not found: {skills_dir}"}
    
    if skill_name:
        skill_path = skills_dir / skill_name / "SKILL.md"
        if not skill_path.exists():
            return {"error": f"Skill '{skill_name}' not found at {skill_path}"}
        content = skill_path.read_text(encoding='utf-8')
        return {"name": skill_name, "content": content}
    
    results = []
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
        raw_tags = data.get("tags", "").strip("[]").replace(", ", ",")
        raw_deps = data.get("depends", "").strip("[]").replace(", ", ",")
        results.append({
            "name": data.get("name", entry.name),
            "description": data.get("description", ""),
            "category": data.get("category", ""),
            "tags": [t for t in raw_tags.split(",") if t] if data.get("tags") else [],
            "hidden": is_hidden,
            "depends": [d for d in raw_deps.split(",") if d] if data.get("depends") else [],
            "path": str(skill_file),
        })
    
    return results


def get_ticket(tickets_dir: Path, ticket_id: str) -> Dict[str, Any]:
    """Read all files in a ticket directory and return their contents."""
    ticket_dir = tickets_dir / ticket_id
    if not ticket_dir.exists():
        return {"error": f"Ticket '{ticket_id}' not found at {ticket_dir}"}

    result = {"ticket_id": ticket_id, "files": {}}
    for fname in ["ticket.md", "acceptance.md", "plan.md", "summary.md", "test_plan.md"]:
        fpath = ticket_dir / fname
        if fpath.exists():
            result["files"][fname] = fpath.read_text(encoding='utf-8')
    plan_path = ticket_dir / "plan.md"
    result["plan_approved"] = _parse_plan_approved(plan_path)
    result["plan_decision"] = _parse_plan_decision(plan_path)
    return result


def update_ticket_body(
    tickets_dir: Path,
    ticket_id: str,
    body: str,
) -> Dict[str, Any]:
    """Replace the markdown body of a ticket (preserving YAML frontmatter)."""
    ticket_file = tickets_dir / ticket_id / "ticket.md"
    if not ticket_file.exists():
        return {"error": f"Ticket {ticket_id} not found"}

    content = ticket_file.read_text(encoding='utf-8')
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
    """Read a companion document from a ticket directory."""
    valid_docs = {"acceptance.md", "plan.md", "test_plan.md", "summary.md"}
    if doc_name not in valid_docs:
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
    """Write content to a companion document in a ticket directory."""
    valid_docs = {"acceptance.md", "plan.md", "test_plan.md", "summary.md"}
    if doc_name not in valid_docs:
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


def git_info(project_root: Path) -> Dict[str, Any]:
    """Return git branch, recent commits, and modified file count."""
    import subprocess

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


def start_sprint(project_root: Path, title: str, ticket_id: str = None) -> Dict[str, Any]:
    """Start a sprint: create ticket, plan.md, and ensure context files."""
    tickets_dir = project_root / ".tickets"

    # Resolve or create ticket
    if ticket_id:
        tdir = tickets_dir / ticket_id
        if not tdir.exists():
            return {"error": f"Ticket '{ticket_id}' not found"}
        tid = ticket_id
    else:
        result = create_sprint_ticket(tickets_dir, title, "medium")
        if "error" in result:
            return result
        tid = result["ticket_id"]

    tdir = tickets_dir / tid

    # Create plan.md if missing
    plan_file = tdir / "plan.md"
    if not plan_file.exists():
        plan_file.write_text(
            f"---\nid: {tid}\n---\n\n# Plan\n\nTicket: `{tid}`\n\n"
            f"## Sign-off\n\n- [ ] Plan approved — proceed to implementation\n\n"
            f"## Approach\n\n\n## Files\n\n\n## Decisions\n\n",
            encoding='utf-8'
        )

    # Ensure context files
    for ctx_file, ctx_content in [
        (project_root / "DECISIONS.md",
         "# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n"),
        (project_root / "HANDOFF.md",
         "# Handoff\n\n## Current Focus\n\n## In Progress\n\n## Discoveries\n\n## Next Steps\n\n1. \n"),
    ]:
        if not ctx_file.exists():
            ctx_file.write_text(ctx_content, encoding='utf-8')

    # Write ACTIVE marker
    active_file = tickets_dir / "ACTIVE"
    active_file.write_text(f"{tid}\n", encoding='utf-8')

    return {
        "ticket_id": tid,
        "ticket_dir": str(tdir),
        "status": "started",
        "message": f"Sprint started: {tid}",
    }


def close_sprint(project_root: Path) -> Dict[str, Any]:
    """
    Validates mechanical close gates, generates a delivery receipt, 
    and updates HANDOFF.md with the final summary.
    """
    tickets_dir = project_root / ".tickets"
    handoff_path = project_root / "HANDOFF.md"
    
    # 1. Validate Mechanical Close Gates
    # All tickets must be in a terminal state
    terminal_statuses = {"closed", "cancelled", "archived"}
    tickets = parse_tickets(tickets_dir)
    incomplete_tickets = [
        t.id for t in tickets
        if t.status.lower() not in terminal_statuses
    ]
    
    if incomplete_tickets:
        return {
            "status": "error",
            "message": f"Cannot close sprint. The following tickets are not terminal (closed/cancelled/archived): {', '.join(incomplete_tickets)}"
        }
    
    # 1b. Validate evaluator-run-id for each closed ticket
    for t in tickets:
        if t.status.lower() != "closed":
            continue
        tdir = tickets_dir / t.id
        plan_path = tdir / "plan.md"
        report_path = tdir / "eval-report.md"
        
        # Skip trivial-tier sprints
        if plan_path.exists():
            plan_content = plan_path.read_text(encoding='utf-8')
            if re.search(r'tier\s*:?\s*\*{0,2}trivial', plan_content, re.IGNORECASE):
                continue
        
        if not report_path.exists():
            return {
                "status": "error",
                "message": (
                    f"Ticket {t.id} cannot close: eval-report.md is missing. "
                    f"Run the evaluator (eval skill) before closing, or confirm trivial tier in plan.md."
                )
            }
        
        report_content = report_path.read_text(encoding='utf-8')
        
        # Check evaluator-run-id field
        run_id_match = re.search(r'^evaluator-run-id:\s+(\S+)', report_content, re.MULTILINE)
        if not run_id_match:
            return {
                "status": "error",
                "message": (
                    f"Ticket {t.id} cannot close: eval-report.md is missing evaluator-run-id field. "
                    f"Ensure the evaluator subagent wrote the run-id before grading."
                )
            }
        
        run_id = run_id_match.group(1)
        
        # Cross-check against subagent-runs.jsonl across all IDE log paths
        run_parts = run_id.split('-', 1)
        run_epoch = run_parts[0] if run_parts else ""
        
        if run_epoch.isdigit():
            matched = _check_subagent_run(project_root, int(run_epoch))
            if not matched:
                paths = " or ".join(AGENT_RUN_LOG_PATHS)
                return {
                    "status": "error",
                    "message": (
                        f"Ticket {t.id} cannot close: evaluator-run-id '{run_id}' has no "
                        f"matching subagent entry in {paths} (±60 min window). "
                        f"The eval must be run as a real subagent invocation — inline writes are not accepted."
                    )
                }
        
        # Check verdict is pass
        if not re.search(r'^pass:', report_content, re.MULTILINE):
            verdict_match = re.search(r'^(pass|fail):', report_content, re.MULTILINE)
            verdict_text = verdict_match.group(0) if verdict_match else "(no verdict line found)"
            return {
                "status": "error",
                "message": (
                    f"Ticket {t.id} cannot close: eval-report.md verdict is not pass. "
                    f"{verdict_text}"
                )
            }
    
    # 2. Generate Delivery Receipt Table
    receipt_lines = ["## Delivery Receipt", "| Ticket ID | Status | Title |", "| --- | --- | --- |"]
    for t in tickets:
        receipt_lines.append(f"| {t.id} | {t.status} | {t.title} |")
    
    receipt_content = "\n".join(receipt_lines)
    
    # 3. Update HANDOFF.md
    handoff_content = handoff_path.read_text(encoding='utf-8')
    sprint_id = tickets[0].id if tickets else "N/A"
    summary_section = f"\n\n## Sprint Summary ({sprint_id})\n{receipt_content}\n"
    
    new_handoff_content = handoff_content.rstrip() + summary_section
    handoff_path.write_text(new_handoff_content, encoding='utf-8')
    
    return {
        "status": "success",
        "message": "Sprint closed successfully and HANDOFF.md updated.",
        "receipt": receipt_content
    }
