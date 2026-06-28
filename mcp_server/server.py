import os
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import List, Dict, Any, Optional

from mcp.server.fastmcp import FastMCP
from mcp_server.utils.models import Ticket
from mcp_server.utils.project_context import find_project_root
import mcp_server.utils.parsers as _parsers

from mcp_server.utils.parsers import (
    get_sprint_board as parse_sprint_board,
    create_sprint_ticket as parse_create_sprint_ticket,
    update_ticket_status as parse_update_ticket_status,
    add_acceptance_criterion as parse_add_acceptance_criterion,
    list_skills as parse_list_skills,
    get_ticket as parse_get_ticket,
    start_sprint as parse_start_sprint,
    update_ticket_body as parse_update_ticket_body,
    read_doc as parse_read_doc,
    write_doc as parse_write_doc,
    git_info as parse_git_info,
    log_subagent_run as parse_log_subagent_run,
)

# Initialize FastMCP server
app = FastMCP("canon-mcp-server")

PROJECT_ROOT = find_project_root(Path(__file__).parent.parent.resolve())


@app.tool()
def list_skills(skill_name: str = None) -> Any:
    """Inventory all canon skills from the skills/ directory.
    
    If skill_name is provided, returns the full content of that skill's SKILL.md.
    Otherwise returns metadata for all available skills (name, description, category, etc.).
    """
    skills_dir = PROJECT_ROOT / "skills"
    return parse_list_skills(skills_dir, skill_name)


@app.tool()
def get_ticket(ticket_id: str) -> Dict[str, Any]:
    """Read a specific ticket's files (ticket.md, acceptance.md, plan.md, summary.md, test_plan.md)."""
    return parse_get_ticket(PROJECT_ROOT / ".tickets", ticket_id)


@app.tool()
def start_sprint(title: str = None, ticket_id: str = None) -> Dict[str, Any]:
    """
    Start a sprint: create a ticket with plan.md and ensure DECISIONS.md and HANDOFF.md exist.
    Provide either a title (creates new ticket) or an existing ticket_id.
    """
    if not title and not ticket_id:
        return {"error": "Provide either a title (to create a new ticket) or an existing ticket_id."}
    if title and ticket_id:
        return {"error": "Provide either a title or a ticket_id, not both."}
    return parse_start_sprint(PROJECT_ROOT, title or "", ticket_id)


@app.tool()
def get_sprint_board() -> Dict[str, Any]:
    """Get the current sprint board including tickets and handoff context."""
    return parse_sprint_board(PROJECT_ROOT)


@app.tool()
def create_sprint_ticket(description: str, priority: str) -> Dict[str, Any]:
    """Create a new sprint ticket with acceptance criteria and test plan templates."""
    result = parse_create_sprint_ticket(
        tickets_dir=PROJECT_ROOT / ".tickets",
        description=description,
        priority=priority,
    )
    return result


@app.tool()
def update_ticket_status(ticket_id: str, new_status: str) -> Dict[str, Any]:
    """Update the status field of an existing ticket's frontmatter."""
    result = parse_update_ticket_status(
        tickets_dir=PROJECT_ROOT / ".tickets",
        ticket_id=ticket_id,
        new_status=new_status,
    )
    return result


@app.tool()
def update_ticket_body(ticket_id: str, body: str) -> Dict[str, Any]:
    """Replace the markdown body of a ticket, preserving YAML frontmatter."""
    return parse_update_ticket_body(
        tickets_dir=PROJECT_ROOT / ".tickets",
        ticket_id=ticket_id,
        body=body,
    )


@app.tool()
def add_acceptance_criterion(ticket_id: str, criterion: str) -> Dict[str, Any]:
    """Add an acceptance criterion to an existing ticket."""
    result = parse_add_acceptance_criterion(
        tickets_dir=PROJECT_ROOT / ".tickets",
        ticket_id=ticket_id,
        criterion_text=criterion,
    )
    return result


@app.tool()
def read_doc(ticket_id: str, doc_name: str) -> Dict[str, Any]:
    """Read a companion document from a ticket directory (acceptance.md, plan.md, test_plan.md, summary.md)."""
    return parse_read_doc(PROJECT_ROOT / ".tickets", ticket_id, doc_name)


@app.tool()
def write_doc(ticket_id: str, doc_name: str, content: str) -> Dict[str, Any]:
    """Write content to a companion document in a ticket directory."""
    return parse_write_doc(PROJECT_ROOT / ".tickets", ticket_id, doc_name, content)


@app.tool()
def git_info() -> Dict[str, Any]:
    """Return git branch, recent commits, and modified file count for the project."""
    return parse_git_info(PROJECT_ROOT)


@app.tool()
def close_sprint() -> Dict[str, Any]:
    """
    Validates mechanical close gates, generates a delivery receipt, 
    and updates HANDOFF.md with the final summary.
    """
    return _parsers.close_sprint(PROJECT_ROOT)


@app.tool()
def log_subagent_run(agent_id: str, agent_type: str = "agent", session_id: str = "") -> Dict[str, Any]:
    """Log a subagent run to the shared audit trail (.canon/subagent-runs.jsonl).

    Called by sprint complete protocol after the evaluator subagent finishes.
    Makes the evaluator audit trail work across all IDEs (Claude Code, opencode,
    VSCode) instead of relying on IDE-specific SubagentStop hooks.
    
    Args:
        agent_id: The evaluator-run-id from eval-report.md (e.g. "1719000000-12345")
        agent_type: Type of subagent (default: "agent")
        session_id: Optional session identifier
    """
    return parse_log_subagent_run(PROJECT_ROOT, agent_id, agent_type, session_id)


def _dashboard_port() -> Optional[int]:
    """Return the port of an already-running dashboard, or None."""
    for port in range(8423, 8431):
        try:
            resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/tickets?all=1", timeout=0.5)
            if resp.status == 200:
                return port
        except (urllib.error.URLError, ConnectionError, OSError):
            continue
    return None


def _find_free_port(start: int = 8423, end: int = 8430) -> int:
    """Find a free TCP port in range [start, end]."""
    for port in range(start, end + 1):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError(f"No free port found in range {start}-{end}")


def _start_dashboard(port: int) -> bool:
    """Launch sprint-check server on the given port as a background process.
    Returns True once the dashboard is confirmed responding.
    """
    env = {**os.environ, "SPRINT_CHECK_ROOT": str(PROJECT_ROOT)}

    if sys.platform == "win32":
        server_script = PROJECT_ROOT / "tools" / "sprint-check-app" / "server.py"
        cmd = [sys.executable, str(server_script), str(port)]
        creationflags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        script_path = PROJECT_ROOT / "tools" / "sprint-check"
        cmd = ["bash", str(script_path), str(port)]
        creationflags = 0

    subprocess.Popen(
        cmd,
        cwd=str(PROJECT_ROOT),
        env=env,
        creationflags=creationflags,
    )

    # Wait up to 3s for the dashboard to start responding
    for _ in range(10):
        try:
            resp = urllib.request.urlopen(
                f"http://127.0.0.1:{port}/api/tickets?all=1", timeout=0.5
            )
            ok = resp.status == 200
            resp.close()
            if ok:
                return True
        except Exception:
            pass
        time.sleep(0.3)
    return False


def _open_browser(url: str) -> None:
    """Open a URL in the default browser using platform-specific commands."""
    if sys.platform == "win32":
        subprocess.Popen(["powershell.exe", "/c", f"start '{url}'"])
    elif sys.platform == "darwin":
        subprocess.Popen(["open", url])
    elif sys.platform == "linux":
        for cmd in ["xdg-open", "wslview", "open"]:
            try:
                subprocess.Popen([cmd, url])
                return
            except FileNotFoundError:
                continue
        print(f"Open in your browser: {url}", file=sys.stderr)


@app.tool()
def open_dashboard() -> str:
    """Launch the local kanban dashboard web UI."""
    try:
        port = _dashboard_port()
        if port is None:
            port = _find_free_port()
            if not _start_dashboard(port):
                return f"Dashboard failed to start on port {port}"
        url = f"http://127.0.0.1:{port}"
        _open_browser(url)
        return f"Dashboard launched on {url}"
    except Exception as e:
        print(f"Failed to launch dashboard: {e}", file=sys.stderr)
        return f"Failed to launch dashboard: {e}"


# Auto-start dashboard server when MCP server starts (headless, no browser)
_port = _dashboard_port()
if _port is None:
    try:
        _port = _find_free_port()
        if _start_dashboard(_port):
            url = f"http://127.0.0.1:{_port}"
            print(f"sprint-check started on {url}", file=sys.stderr)
        else:
            print(f"sprint-check dashboard failed to start on port {_port}", file=sys.stderr)
    except Exception as e:
        print(f"sprint-check auto-start skipped: {e}", file=sys.stderr)

if __name__ == "__main__":
    app.run()
