import os
import re
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

def get_sprint_board(project_root: Path) -> Dict[str, Any]:
    """Combine ticket parsing and handoff parsing into a single structured response."""
    tickets = parse_tickets(project_root / ".tickets")
    handoff = parse_handoff(project_root / "HANDOFF.md")
    
    return {
        "tickets": [
            {
                "id": t.id,
                "status": t.status,
                "title": t.title,
                "description": t.description,
                "acceptance_criteria": t.acceptance_criteria
            } for t in tickets
        ],
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
        f"---\nid: {ticket_id}\ntitle: {description[:50]}...\nstatus: todo\npriority: {priority}\n---\n\n## Description\n{description}\n\n## Acceptance Criteria\n",
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

def update_ticket_status(
    tickets_dir: Path,
    ticket_id: str,
    new_status: str,
) -> Dict[str, Any]:
    """Update the status field of an existing ticket's frontmatter."""
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
