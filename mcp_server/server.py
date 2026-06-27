import os
import socket
import subprocess
import sys
from pathlib import Path
from typing import List, Dict, Any

from mcp.server.fastmcp import FastMCP
from mcp_server.utils.models import Ticket
from mcp_server.utils.project_context import find_project_root
from mcp_server.utils.parsers import get_sprint_board as parse_sprint_board, create_sprint_ticket, update_ticket_status, add_acceptance_criterion

# Initialize FastMCP server
app = FastMCP("canon-mcp-server")

PROJECT_ROOT = find_project_root(Path(__file__).parent.parent.resolve())


@app.tool()
def hello_world() -> str:
    """A simple hello world tool."""
    return "Hello from the canon MCP server!"


@app.tool()
def get_sprint_board() -> List[Dict[str, Any]]:
    """Get the current sprint board including tickets and handoff context."""
    return parse_sprint_board(PROJECT_ROOT)


@app.tool()
def create_sprint_ticket(description: str, priority: str) -> Dict[str, Any]:
    """Create a new sprint ticket with acceptance criteria and test plan templates."""
    result = create_sprint_ticket(
        tickets_dir=PROJECT_ROOT / ".tickets",
        description=description,
        priority=priority,
    )
    return result


@app.tool()
def update_ticket_status(ticket_id: str, new_status: str) -> Dict[str, Any]:
    """Update the status field of an existing ticket's frontmatter."""
    result = update_ticket_status(
        tickets_dir=PROJECT_ROOT / ".tickets",
        ticket_id=ticket_id,
        new_status=new_status,
    )
    return result


@app.tool()
def add_acceptance_criterion(ticket_id: str, criterion: str) -> Dict[str, Any]:
    """Add an acceptance criterion to an existing ticket."""
    result = add_acceptance_criterion(
        tickets_dir=PROJECT_ROOT / ".tickets",
        ticket_id=ticket_id,
        criterion=criterion,
    )
    return result


@app.tool()
def open_dashboard() -> str:
    """Launch the local kanban dashboard web UI."""
    script_path = PROJECT_ROOT / "tools" / "sprint-check"

    try:
        # Find a free port (try 8423-8430)
        port = 8423
        while port <= 8430:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s.bind(("127.0.0.1", port))
                    s.close()
                    break
                except OSError:
                    port += 1
        else:
            raise RuntimeError("No free port found in range 8423-8430")

        # Set SPRINT_CHECK_ROOT environment variable
        env = {**os.environ, "SPRINT_CHECK_ROOT": str(PROJECT_ROOT)}

        # Launch sprint-check in background (platform-aware)
        if sys.platform == "win32":
            cmd = ["cmd", "/c", str(script_path)]
        else:
            cmd = ["bash", str(script_path)]
        
        subprocess.Popen(
            cmd,
            cwd=str(PROJECT_ROOT),
            env=env,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0,
        )

        # Generate URL and open browser
        url = f"http://127.0.0.1:{port}"
        _open_browser(url)

        return f"Dashboard launched on {url}"
    except Exception as e:
        print(f"Failed to launch dashboard: {e}", file=sys.stderr)
        return f"Failed to launch dashboard: {e}"


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


if __name__ == "__main__":
    app.run()
