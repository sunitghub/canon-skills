import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any

from .parsers import parse_tickets, parse_handoff, _parse_plan_approved, _parse_plan_decision, AGENT_RUN_LOG_PATHS, _check_subagent_run
from .commands import create_sprint_ticket


def get_sprint_board(project_root: Path) -> Dict[str, Any]:
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


def log_subagent_run(
    project_root: Path,
    agent_id: str,
    agent_type: str = "agent",
    session_id: str = "",
) -> Dict[str, Any]:
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


def start_sprint(project_root: Path, title: str, ticket_id: str = None) -> Dict[str, Any]:
    tickets_dir = project_root / ".tickets"

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

    plan_file = tdir / "plan.md"
    if not plan_file.exists():
        plan_file.write_text(
            f"---\nid: {tid}\n---\n\n# Plan\n\nTicket: `{tid}`\n\n"
            f"## Sign-off\n\n- [ ] Plan approved — proceed to implementation\n\n"
            f"## Approach\n\n\n## Files\n\n\n## Decisions\n\n",
            encoding='utf-8'
        )

    for ctx_file, ctx_content in [
        (project_root / "DECISIONS.md",
         "# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n"),
        (project_root / "HANDOFF.md",
         "# Handoff\n\n## Current Focus\n\n## In Progress\n\n## Discoveries\n\n## Next Steps\n\n1. \n"),
    ]:
        if not ctx_file.exists():
            ctx_file.write_text(ctx_content, encoding='utf-8')

    active_file = tickets_dir / "ACTIVE"
    active_file.write_text(f"{tid}\n", encoding='utf-8')

    return {
        "ticket_id": tid,
        "ticket_dir": str(tdir),
        "status": "started",
        "message": f"Sprint started: {tid}",
    }


def close_sprint(project_root: Path) -> Dict[str, Any]:
    tickets_dir = project_root / ".tickets"
    handoff_path = project_root / "HANDOFF.md"

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

    for t in tickets:
        if t.status.lower() != "closed":
            continue
        tdir = tickets_dir / t.id
        plan_path = tdir / "plan.md"
        report_path = tdir / "eval-report.md"

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

    receipt_lines = ["## Delivery Receipt", "| Ticket ID | Status | Title |", "| --- | --- | --- |"]
    for t in tickets:
        receipt_lines.append(f"| {t.id} | {t.status} | {t.title} |")

    receipt_content = "\n".join(receipt_lines)

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
