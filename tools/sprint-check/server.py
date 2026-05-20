#!/usr/bin/env python3
"""sprint-check local HTTP server — stdlib only, no pip required."""

import json
import os
import re
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

# ── Locate project root ───────────────────────────────────────────────────

def find_project_root(start: Path) -> Path:
    """Walk up from start until we find .git or .tickets/, or return start."""
    d = start.resolve()
    while d != d.parent:
        if (d / '.git').exists() or (d / '.tickets').exists():
            return d
        d = d.parent
    return start.resolve()

PROJECT_ROOT = find_project_root(Path(os.environ.get('SPRINT_CHECK_ROOT', Path.cwd())))
TICKETS_DIR  = PROJECT_ROOT / '.tickets'
HANDOFF_FILE = PROJECT_ROOT / 'HANDOFF.md'
APP_HTML     = Path(__file__).parent / 'app.html'

# ── Ticket parsing ────────────────────────────────────────────────────────

_FRONTMATTER = re.compile(r'^---\s*\n(.*?)\n---\s*\n', re.DOTALL)
_FIELD       = re.compile(r'^(\w+):\s*(.+)$', re.MULTILINE)

def parse_ticket(path: Path) -> dict:
    text = path.read_text(encoding='utf-8', errors='replace')
    fm_match = _FRONTMATTER.match(text)
    fields = {}
    body = text
    if fm_match:
        fm_text = fm_match.group(1)
        for m in _FIELD.finditer(fm_text):
            key, val = m.group(1), m.group(2).strip()
            # coerce priority to int
            if key == 'priority':
                try: val = int(val)
                except ValueError: pass
            fields[key] = val
        body = text[fm_match.end():].strip()
    # title from first markdown heading or filename
    title_match = re.search(r'^#\s+(.+)$', body, re.MULTILINE)
    fields.setdefault('title', title_match.group(1).strip() if title_match else path.stem)
    fields['body'] = body
    fields.setdefault('id', path.stem)
    return fields

def load_tickets() -> list:
    if not TICKETS_DIR.is_dir():
        return []
    tickets = []
    for f in sorted(TICKETS_DIR.glob('*.md')):
        try:
            tickets.append(parse_ticket(f))
        except Exception:
            pass
    return tickets

# ── HANDOFF.md parsing ────────────────────────────────────────────────────

def load_handoff() -> dict:
    if not HANDOFF_FILE.exists():
        return {'focus': None, 'raw': ''}
    raw = HANDOFF_FILE.read_text(encoding='utf-8', errors='replace')
    # Extract "## Current Focus" section (first paragraph after the heading)
    focus = None
    m = re.search(r'##\s+Current Focus\s*\n+([\s\S]+?)(?:\n##|\Z)', raw)
    if m:
        block = m.group(1).strip()
        # drop snapshot markers and blank lines; take first non-empty paragraph
        lines = [l for l in block.splitlines()
                 if l.strip() and not l.startswith('<!--')]
        focus = ' '.join(lines[:3]).strip() or None
    return {'focus': focus, 'raw': raw}

# ── Git info ──────────────────────────────────────────────────────────────

def run(cmd: list, cwd: Path) -> str:
    try:
        return subprocess.check_output(cmd, cwd=cwd, stderr=subprocess.DEVNULL,
                                       text=True, timeout=5).strip()
    except Exception:
        return ''

def load_git() -> dict:
    cwd = PROJECT_ROOT
    branch   = run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], cwd) or 'main'
    project  = cwd.name
    status   = run(['git', 'status', '--porcelain'], cwd)
    modified = len([l for l in status.splitlines() if l.strip()]) if status else 0
    log_raw  = run(['git', 'log', '--oneline', '-8'], cwd)
    log = []
    for line in log_raw.splitlines():
        parts = line.split(' ', 1)
        if len(parts) == 2:
            log.append({'hash': parts[0], 'message': parts[1]})
    return {'branch': branch, 'project': project, 'modified': modified, 'log': log}

# ── Status write ──────────────────────────────────────────────────────────

def write_status(ticket_id: str, new_status: str) -> bool:
    """Update the status field in a ticket's YAML frontmatter."""
    if not TICKETS_DIR.is_dir():
        return False
    matches = list(TICKETS_DIR.glob(f'{ticket_id}*.md'))
    if not matches:
        # also search by id field
        for f in TICKETS_DIR.glob('*.md'):
            try:
                t = parse_ticket(f)
                if t.get('id') == ticket_id:
                    matches = [f]; break
            except Exception:
                pass
    if not matches:
        return False
    path = matches[0]
    text = path.read_text(encoding='utf-8', errors='replace')
    updated = re.sub(r'^(status:\s*)(\S+)$', rf'\g<1>{new_status}', text, flags=re.MULTILINE)
    if updated == text:
        return False
    path.write_text(updated, encoding='utf-8')
    return True

# ── HTTP handler ──────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        first = str(args[0]) if args else ''
        if '/api/' in first:
            print(f'  {first}', file=sys.stderr)

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Connection', 'close')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, path: Path):
        try:
            body = path.read_bytes()
        except FileNotFoundError:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path.rstrip('/')
        if path in ('', '/'):
            self.send_html(APP_HTML)
        elif path == '/api/tickets':
            self.send_json(load_tickets())
        elif path == '/api/handoff':
            self.send_json(load_handoff())
        elif path == '/api/git':
            self.send_json(load_git())
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        m = re.match(r'^/api/ticket/([^/]+)/status$', path)
        if not m:
            self.send_error(404); return
        ticket_id = m.group(1)
        length = int(self.headers.get('Content-Length', 0))
        try:
            body = json.loads(self.rfile.read(length))
            new_status = str(body.get('status', ''))
        except Exception:
            self.send_error(400); return
        ok = write_status(ticket_id, new_status)
        self.send_json({'ok': ok, 'status': new_status})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

# ── Entry point ───────────────────────────────────────────────────────────

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8423
    import threading

    # HTTPServer.serve_forever() uses selectors.DefaultSelector (kqueue on macOS),
    # which is restricted in some sandboxed environments. Use a raw accept loop
    # instead — BaseHTTPRequestHandler is instantiated per connection directly.
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('127.0.0.1', port))
    sock.listen(32)

    print(f'sprint-check  http://localhost:{port}  (project: {PROJECT_ROOT.name})', file=sys.stderr)
    print(f'tickets: {TICKETS_DIR}', file=sys.stderr)

    # Minimal server stub that BaseHTTPRequestHandler expects
    class _Server:
        server_name    = 'localhost'
        server_port    = port
        timeout        = None

    stub = _Server()

    def handle_conn(conn, addr):
        try:
            Handler(conn, addr, stub)
        except Exception:
            pass
        finally:
            try: conn.close()
            except Exception: pass

    try:
        while True:
            conn, addr = sock.accept()
            threading.Thread(target=handle_conn, args=(conn, addr), daemon=True).start()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        sock.close()

if __name__ == '__main__':
    main()
