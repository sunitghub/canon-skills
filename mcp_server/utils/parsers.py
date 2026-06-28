import json
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any
from .models import Ticket

logger = logging.getLogger(__name__)


def _parse_timestamp(ts: str) -> int:
    """Parse ISO 8601 timestamp to epoch int. Handles Z suffix and fractional seconds."""
    normalized = ts.replace("Z", "+00:00", 1) if ts.endswith("Z") else ts
    return int(datetime.fromisoformat(normalized).timestamp())

def parse_tickets(tickets_dir: Path) -> List[Ticket]:
    tickets = []
    if not tickets_dir.exists():
        return tickets

    for subdir in tickets_dir.iterdir():
        if subdir.is_dir():
            ticket_file = subdir / "ticket.md"
            if ticket_file.exists():
                content = ticket_file.read_text(encoding='utf-8')
                data = {}
                frontmatter_match = re.search(r'^---\n(.*?)\n---', content, re.MULTILINE | re.DOTALL)
                if frontmatter_match:
                    lines = frontmatter_match.group(1).strip().split('\n')
                    for line in lines:
                        if ':' in line:
                            key, value = line.split(':', 1)
                            data[key.strip().lower()] = value.strip()
                else:
                    first_line = content.strip().split('\n', 1)[0]
                    if first_line:
                        data['id'] = first_line.strip()

                acceptance_criteria = ""
                body_match = re.search(r'^## Acceptance Criteria\n(.*?)(?=\n##|$)', content, re.DOTALL | re.MULTILINE)
                if body_match:
                    acceptance_criteria = body_match.group(1).strip()

                description = ""
                desc_match = re.search(r'^## Description\n(.*?)(?=\n##|$)', content, re.DOTALL | re.MULTILINE)
                if desc_match:
                    description = desc_match.group(1).strip()

                tickets.append(Ticket(
                    id=data.get('id', 'unknown'),
                    status=data.get('status', 'unknown'),
                    title=data.get('title', 'No Title'),
                    description=description,
                    acceptance_criteria=acceptance_criteria,
                    priority=data.get('priority'),
                ))
    return tickets


def parse_handoff(handoff_path: Path) -> Dict[str, Any]:
    if not handoff_path.exists():
        return {"active_tasks": []}

    content = handoff_path.read_text(encoding='utf-8')
    active_tasks = []

    tasks_match = re.search(r'## Active Tasks\n(.*?)(?=\n\n##|$)', content, re.DOTALL)
    if tasks_match:
        tasks_section = tasks_match.group(1).strip()
        for line in tasks_section.split('\n'):
            line = line.strip()
            line = re.sub(r'\*\*(.*?)\*\*', r'\1', line)
            line = re.sub(r'\*(.*?)\*', r'\1', line)
            if line and line.startswith('- '):
                active_tasks.append(line[2:].strip())

    return {
        "active_tasks": active_tasks,
        "context": "Extracted from HANDOFF.md"
    }


def _get_section(content: str, heading: str) -> str:
    pattern = re.compile(
        r'^##\s+' + re.escape(heading) + r'\s*$(.*?)(?=^##(?!#)|\Z)',
        re.MULTILINE | re.DOTALL
    )
    m = pattern.search(content)
    return m.group(1).strip() if m else ""


def _parse_plan_approved(plan_path: Path) -> bool:
    if not plan_path.exists():
        return False
    content = plan_path.read_text(encoding='utf-8')
    signoff = _get_section(content, 'Sign-off')
    return bool(re.search(r'^\s*[-*]\s+\[[xX]\]\s+\S', signoff, re.MULTILINE))


def _parse_plan_decision(plan_path: Path) -> str:
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
]


def _check_subagent_run(project_root: Path, run_epoch: int) -> bool:
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
                        entry_epoch = _parse_timestamp(ts)
                        if abs(entry_epoch - run_epoch) <= 3600:
                            return True
                    except Exception as exc:
                        logger.warning("Failed to parse entry in %s: %s", jsonl_path, exc)
                        pass
        except Exception as exc:
            logger.warning("Failed to read %s: %s", jsonl_path, exc)
            pass
    return False
