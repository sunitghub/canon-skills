#!/usr/bin/env python3
"""Cross-platform launcher for the canon MCP server.
Finds the project's .venv Python and runs mcp_server.server.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def _find_python() -> str:
    venv_dirs = [ROOT / ".venv", ROOT / "mcp_server" / ".venv"]
    for venv in venv_dirs:
        candidates = [
            venv / "Scripts" / "python.exe",
            venv / "bin" / "python3",
            venv / "bin" / "python",
        ]
        for c in candidates:
            if c.is_file():
                return str(c)
    for name in ("python3", "python"):
        found = shutil.which(name)
        if found:
            return found
    print("Error: Python not found. Ensure a .venv or system Python is available.", file=sys.stderr)
    sys.exit(1)


def main():
    python = _find_python()
    cmd = [python, "-m", "mcp_server.server"] + sys.argv[1:]
    os.chdir(str(ROOT))
    result = subprocess.run(cmd)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
