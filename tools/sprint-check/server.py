#!/usr/bin/env python3
"""sprint-check local HTTP server — stdlib only, no pip required."""

import json
import os
import random
import re
import socket
import string
import subprocess
import sys
from datetime import date
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
            if key == 'priority':
                try: val = int(val)
                except ValueError: pass
            fields[key] = val
        body = text[fm_match.end():].strip()
    title_match = re.search(r'^#\s+(.+)$', body, re.MULTILINE)
    fields.setdefault('title', title_match.group(1).strip() if title_match else path.stem)
    fields['body'] = body
    fields.setdefault('id', path.stem)
    # companion docs: {stem}-{docname}.md alongside the ticket
    stem = path.stem
    docs = []
    for f in sorted(path.parent.glob(f'{stem}-*.md')):
        doc_name = f.stem[len(stem)+1:].replace('-', ' ').title()
        docs.append({'name': doc_name, 'file': f.name})
    fields['docs'] = docs
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
    _SKIP = ('chore: auto-update handoff', 'chore: auto-handoff')
    log_raw = run(['git', 'log', '--oneline', '-40'], cwd)
    log = []
    for line in log_raw.splitlines():
        parts = line.split(' ', 1)
        if len(parts) == 2 and not any(parts[1].startswith(s) for s in _SKIP):
            log.append({'hash': parts[0], 'message': parts[1]})
            if len(log) == 8:
                break
    return {'branch': branch, 'project': project, 'modified': modified, 'log': log}

# ── Commit detail ─────────────────────────────────────────────────────────

def load_commit(hash_: str) -> dict:
    cwd = PROJECT_ROOT
    msg    = run(['git', 'log', '-1', '--format=%B', hash_], cwd)
    author = run(['git', 'log', '-1', '--format=%an', hash_], cwd)
    date   = run(['git', 'log', '-1', '--format=%ci', hash_], cwd)
    files  = run(['git', 'diff-tree', '--no-commit-id', '-r', '--name-only', hash_], cwd)
    lines  = msg.splitlines()
    subject = lines[0] if lines else ''
    body    = '\n'.join(lines[2:]).strip() if len(lines) > 2 else ''
    file_list = [f for f in files.splitlines() if f.strip()]
    # related tickets: IDs in the commit message + ticket files touched
    _TID = re.compile(r'\b([a-zA-Z]+-[a-z0-9]{3,})\b')
    related: set[str] = set()
    for m in _TID.finditer(msg):
        related.add(m.group(1))
    for f in file_list:
        p = Path(f)
        if p.parts[0:1] == ('.tickets',) and p.suffix == '.md':
            related.add(p.stem)
    return {
        'hash': hash_, 'subject': subject, 'body': body,
        'author': author, 'date': date[:10] if date else '',
        'files': file_list, 'related_ticket_ids': sorted(related),
    }

# ── Status write ──────────────────────────────────────────────────────────

def _find_ticket_path(ticket_id: str) -> Path | None:
    if not TICKETS_DIR.is_dir():
        return None
    matches = list(TICKETS_DIR.glob(f'{ticket_id}*.md'))
    if not matches:
        for f in TICKETS_DIR.glob('*.md'):
            try:
                if parse_ticket(f).get('id') == ticket_id:
                    return f
            except Exception:
                pass
        return None
    return matches[0]

def write_status(ticket_id: str, new_status: str) -> bool:
    path = _find_ticket_path(ticket_id)
    if not path:
        return False
    text = path.read_text(encoding='utf-8', errors='replace')
    updated = re.sub(r'^(status:\s*)(\S+)$', lambda m: m.group(1) + new_status, text, flags=re.MULTILINE)
    if updated == text:
        return False
    path.write_text(updated, encoding='utf-8')
    return True

def write_body(ticket_id: str, new_body: str) -> bool:
    """Replace the body (everything after frontmatter) of a ticket."""
    path = _find_ticket_path(ticket_id)
    if not path:
        return False
    text = path.read_text(encoding='utf-8', errors='replace')
    fm_match = _FRONTMATTER.match(text)
    updated = (text[:fm_match.end()] if fm_match else '') + new_body.strip() + '\n'
    path.write_text(updated, encoding='utf-8')
    return True

def read_doc(doc_file: str) -> str | None:
    """Read a companion doc file safely (must be a .md file in TICKETS_DIR)."""
    safe = Path(doc_file).name
    if not safe.endswith('.md'):
        return None
    p = TICKETS_DIR / safe
    if not p.is_file():
        return None
    return p.read_text(encoding='utf-8', errors='replace')

def create_ticket(title: str, type_: str, status: str, priority: int, body: str) -> dict:
    """Create a new ticket file and return its parsed data."""
    TICKETS_DIR.mkdir(exist_ok=True)
    existing = {f.stem for f in TICKETS_DIR.glob('*.md')}
    chars = string.ascii_lowercase + string.digits
    while True:
        ticket_id = 't-' + ''.join(random.choices(chars, k=4))
        if ticket_id not in existing:
            break
    created = date.today().isoformat()
    safe_title = title.replace('\n', ' ').strip()
    fm = (f'---\nid: {ticket_id}\ntitle: {safe_title}\nstatus: {status}\n'
          f'type: {type_}\npriority: {priority}\ncreated: {created}\n---\n')
    full = fm + '\n' + body.strip() + '\n' if body.strip() else fm
    path = TICKETS_DIR / f'{ticket_id}.md'
    path.write_text(full, encoding='utf-8')
    return parse_ticket(path)

def write_doc(doc_file: str, content: str) -> bool:
    """Write a companion doc (must be a .md file in TICKETS_DIR)."""
    safe = Path(doc_file).name
    if not safe.endswith('.md'):
        return False
    (TICKETS_DIR / safe).write_text(content.strip() + '\n', encoding='utf-8')
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
            m = re.match(r'^/api/commit/([0-9a-f]{4,40})$', path)
            if m:
                self.send_json(load_commit(m.group(1))); return
            m = re.match(r'^/api/doc/(.+)$', path)
            if m:
                content = read_doc(m.group(1))
                if content is None:
                    self.send_error(404); return
                self.send_json({'content': content})
            else:
                self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        origin = self.headers.get('Origin', '')
        if origin and not origin.startswith('http://127.0.0.1') and not origin.startswith('http://localhost'):
            self.send_error(403); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            payload = json.loads(self.rfile.read(length))
        except Exception:
            self.send_error(400); return

        m = re.match(r'^/api/ticket/([^/]+)/status$', path)
        if m:
            ok = write_status(m.group(1), str(payload.get('status', '')))
            self.send_json({'ok': ok}); return

        m = re.match(r'^/api/ticket/([^/]+)/body$', path)
        if m:
            ok = write_body(m.group(1), str(payload.get('body', '')))
            self.send_json({'ok': ok}); return

        m = re.match(r'^/api/doc/(.+)$', path)
        if m:
            ok = write_doc(m.group(1), str(payload.get('content', '')))
            self.send_json({'ok': ok}); return

        if path == '/api/tickets':
            t = create_ticket(
                title    = str(payload.get('title', 'Untitled')),
                type_    = str(payload.get('type', 'task')),
                status   = str(payload.get('status', 'open')),
                priority = int(payload.get('priority', 2)),
                body     = str(payload.get('body', '')),
            )
            self.send_json(t); return

        self.send_error(404)

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
