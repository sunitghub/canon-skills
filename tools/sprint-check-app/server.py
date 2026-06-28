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
from urllib.parse import parse_qs, unquote, urlparse

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

def _doc_name(path: Path) -> str:
    return path.stem.replace('-', ' ').title()

def _safe_ticket_doc(doc_file: str) -> Path | None:
    p = Path(doc_file)
    if p.is_absolute() or '..' in p.parts or p.suffix != '.md':
        return None
    target = TICKETS_DIR / p
    try:
        target.resolve().relative_to(TICKETS_DIR.resolve())
    except ValueError:
        return None
    return target

def _section(text: str, heading: str) -> str:
    lines, active = [], False
    for line in text.splitlines():
        if re.match(r'^##\s+' + re.escape(heading) + r'\s*$', line):
            active = True; continue
        if active and re.match(r'^##\s+', line):
            break
        if active:
            lines.append(line)
    return '\n'.join(lines)

def _useful_text(text: str, placeholders: tuple[str, ...] = ()) -> bool:
    cleaned = re.sub(r'<!--[\s\S]*?-->', '', text)
    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    if not lines:
        return False
    normalized = '\n'.join(lines).strip()
    return normalized not in placeholders

def _section_has_checked_item(text: str, heading: str) -> bool:
    section = _section(text, heading)
    return bool(re.search(r'^\s*[-*]\s+\[[xX]\]\s+\S', section, re.MULTILINE))

def _unquote_yaml_scalar(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value

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
            elif isinstance(val, str):
                val = _unquote_yaml_scalar(val)
            fields[key] = val
        body = text[fm_match.end():].strip()
    title_match = re.search(r'^#{1,6}\s+(.+)$', body, re.MULTILINE)
    fields.setdefault('title', title_match.group(1).strip() if title_match else path.stem)
    fields['body'] = body
    docs = []
    if path.name == 'ticket.md' and path.parent != TICKETS_DIR:
        ticket_id = fields.get('id') or path.parent.name
        fields['id'] = ticket_id
        fields.setdefault('status', 'open')
        fields['layout'] = 'folder'
        for f in sorted(path.parent.glob('*.md')):
            if f.name == 'ticket.md':
                continue
            docs.append({'name': _doc_name(f), 'file': f'{path.parent.name}/{f.name}'})
        # Check acceptance completeness: Criteria and Test Plan each need ≥1 checkbox item
        fields['acceptance_has_items'] = None
        fields['acceptance_unchecked'] = None
        acc_path = path.parent / 'acceptance.md'
        if acc_path.is_file():
            try:
                acc_text = acc_path.read_text(encoding='utf-8', errors='replace')
                # Require checkbox with actual text content (not bare placeholder `- [ ]`)
                _cb = re.compile(r'^\s*[-*]\s+\[[ xX]\]\s+\S', re.MULTILINE)
                fields['acceptance_has_items'] = (
                    bool(_cb.search(_section(acc_text, 'Criteria'))) and
                    bool(_cb.search(_section(acc_text, 'Test Plan')))
                )
                # True if any unchecked items exist (blocks drag-to-done)
                _unchecked = re.compile(r'^\s*[-*]\s+\[ \]\s+\S', re.MULTILINE)
                fields['acceptance_unchecked'] = bool(_unchecked.search(acc_text))
            except Exception:
                pass
        fields['plan_has_approach'] = None
        fields['plan_approved'] = None
        plan_path = path.parent / 'plan.md'
        if plan_path.is_file():
            try:
                plan_text = plan_path.read_text(encoding='utf-8', errors='replace')
                fields['plan_has_approach'] = _useful_text(
                    _section(plan_text, 'Approach')
                )
                fields['plan_approved'] = _section_has_checked_item(plan_text, 'Sign-off')
            except Exception:
                pass
    else:
        fields.setdefault('id', path.stem)
        fields.setdefault('status', 'open')
        fields['layout'] = 'flat'
        stem = path.stem
        for f in sorted(path.parent.glob(f'{stem}-*.md')):
            doc_name = f.stem[len(stem)+1:].replace('-', ' ').title()
            docs.append({'name': doc_name, 'file': f.name})
    fields['docs'] = docs
    return fields

def ticket_paths() -> list[Path]:
    if not TICKETS_DIR.is_dir():
        return []
    paths = []
    seen: set[str] = set()
    for ticket in sorted(TICKETS_DIR.glob('*/ticket.md')):
        paths.append(ticket)
        seen.add(ticket.parent.name)
    for f in sorted(TICKETS_DIR.glob('*.md')):
        if f.stem in seen:
            continue
        if re.match(r'^.+-(blueprint|acceptance|plan|decisions|qa|notes)$', f.stem):
            continue
        paths.append(f)
    return paths

def legacy_doc_target(doc_file: str) -> Path | None:
    safe = Path(doc_file).name
    if not safe.endswith('.md'):
        return None
    m = re.match(r'^([A-Za-z]+-[A-Za-z0-9]+)-(.+)\.md$', safe)
    if m and (TICKETS_DIR / m.group(1) / 'ticket.md').is_file():
        return TICKETS_DIR / m.group(1) / f'{m.group(2)}.md'
    return TICKETS_DIR / safe

def load_tickets() -> list:
    tickets = []
    for f in ticket_paths():
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
        if focus:
            # First sentence only; fall back to 80-char cap
            m2 = re.match(r'(.+?\.[^\w\s]*)\s', focus)
            focus = m2.group(1) if m2 else (focus[:80].rsplit(' ', 1)[0] + '…' if len(focus) > 80 else focus)
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
    return {'branch': branch, 'project': project, 'root': str(cwd), 'modified': modified, 'log': log}

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

def _ticket_by_id(ticket_id: str) -> tuple[Path, dict] | None:
    for path in ticket_paths():
        try:
            ticket = parse_ticket(path)
        except Exception:
            continue
        if ticket.get('id') == ticket_id:
            return path, ticket
    return None

def _known_ticket_ids() -> set[str]:
    ids = set()
    for path in ticket_paths():
        try:
            ticket_id = str(parse_ticket(path).get('id', ''))
        except Exception:
            continue
        if ticket_id:
            ids.add(ticket_id)
    return ids

def _plan_decision(ticket_path: Path) -> str:
    plan = ticket_path.parent / 'plan.md' if ticket_path.name == 'ticket.md' else ticket_path.with_name(f'{ticket_path.stem}-plan.md')
    if not plan.is_file():
        return ''
    text = plan.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'^##\s+Decisions\s*$([\s\S]*)', text, re.MULTILINE)
    if not m:
        return ''
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith('### '):
            return line[4:].strip()
    return ''

def load_why(file_: str) -> dict:
    target = file_.strip()
    if not target:
        return {'file': '', 'results': [], 'message': 'Enter a file path.'}

    p = Path(target)
    if p.is_absolute() or '..' in p.parts:
        return {'file': target, 'results': [], 'message': 'Use a project-relative file path.'}

    cwd = PROJECT_ROOT
    log_subjects = run(['git', 'log', '--follow', '--format=%s', '--', target], cwd)
    if not log_subjects:
        return {'file': target, 'results': [], 'message': f'No git history found for {target}.'}

    matched_ids: list[str] = []
    def add_unique(ticket_id: str):
        if ticket_id not in matched_ids:
            matched_ids.append(ticket_id)

    known_ids = _known_ticket_ids()
    for ticket_id in re.findall(r'\b[a-zA-Z]+-[a-z0-9]{3,}\b', log_subjects):
        if ticket_id in known_ids:
            add_unique(ticket_id)

    if not matched_ids:
        stop = {
            'update','change','changed','refact','clean','minor','patch','revert',
            'merge','commit','sprint','feature','implement','style','docs','chore',
            'ticket','tickets',
        }
        words = {
            word for word in re.findall(r'[a-z]{4,}', log_subjects.lower())
            if word not in stop
        }
        scored = []
        if words:
            for path in ticket_paths():
                try:
                    ticket = parse_ticket(path)
                except Exception:
                    continue
                title_words = {
                    word for word in re.findall(r'[a-z]{4,}', str(ticket.get('title', '')).lower())
                    if word not in stop
                }
                hits = len(words & title_words)
                if hits:
                    scored.append((hits / max(len(title_words), 1), str(ticket.get('id', ''))))
        for _, ticket_id in sorted(scored, reverse=True)[:5]:
            add_unique(ticket_id)

    results = []
    for ticket_id in matched_ids:
        found = _ticket_by_id(ticket_id)
        if not found:
            continue
        path, ticket = found
        results.append({
            'id': ticket.get('id', ticket_id),
            'status': ticket.get('status', ''),
            'title': ticket.get('title', ''),
            'decision': _plan_decision(path),
        })

    return {
        'file': target,
        'results': results,
        'message': '' if results else f'No tickets found for {target}.',
    }

# ── Status write ──────────────────────────────────────────────────────────

def _find_ticket_path(ticket_id: str) -> Path | None:
    if not TICKETS_DIR.is_dir():
        return None
    folder_ticket = TICKETS_DIR / ticket_id / 'ticket.md'
    if folder_ticket.is_file():
        return folder_ticket
    flat_ticket = TICKETS_DIR / f'{ticket_id}.md'
    if flat_ticket.is_file():
        return flat_ticket
    for f in ticket_paths():
        try:
            if parse_ticket(f).get('id') == ticket_id:
                return f
        except Exception:
            pass
    return None

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
    """Read a companion doc file safely from TICKETS_DIR."""
    p = _safe_ticket_doc(doc_file)
    if p is None or not p.is_file():
        p = legacy_doc_target(doc_file)
    if p is None or not p.is_file():
        return None
    return p.read_text(encoding='utf-8', errors='replace')

def create_ticket(title: str, type_: str, status: str, priority: int, body: str) -> dict:
    """Create a new canonical ticket folder and return its parsed data."""
    TICKETS_DIR.mkdir(exist_ok=True)
    existing = {p.stem for p in ticket_paths()} | {p.name for p in TICKETS_DIR.iterdir() if p.is_dir()}
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
    ticket_dir = TICKETS_DIR / ticket_id
    ticket_dir.mkdir()
    path = ticket_dir / 'ticket.md'
    path.write_text(full, encoding='utf-8')
    return parse_ticket(path)

def write_doc(doc_file: str, content: str) -> bool:
    """Write a companion doc under TICKETS_DIR."""
    p = _safe_ticket_doc(doc_file)
    if p is None:
        p = legacy_doc_target(doc_file)
    if p is None:
        return False
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content.strip() + '\n', encoding='utf-8')
    return True

# ── HTTP handler ──────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):

    _ALLOWED_HOSTS = ('127.0.0.1', 'localhost')

    def log_message(self, fmt, *args):
        first = str(args[0]) if args else ''
        if '/api/' in first:
            print(f'  {first}', file=sys.stderr)

    def _host_ok(self) -> bool:
        # Reject requests whose Host is not loopback — closes the DNS-rebinding
        # path that the 127.0.0.1 bind alone cannot.
        host = self.headers.get('Host', '')
        hostname = host.rsplit(':', 1)[0] if host else ''
        return hostname in self._ALLOWED_HOSTS

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Connection', 'close')
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

    def send_image(self, path: Path):
        ext = path.suffix.lower()
        mime = {'png': 'image/png', 'gif': 'image/gif', 'jpg': 'image/jpeg',
                'jpeg': 'image/jpeg', 'webp': 'image/webp'}.get(ext.lstrip('.'), 'application/octet-stream')
        try:
            body = path.read_bytes()
        except FileNotFoundError:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', len(body))
        self.send_header('Cache-Control', 'public, max-age=3600')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._host_ok():
            self.send_error(403); return
        parsed = urlparse(self.path)
        path = parsed.path.rstrip('/')
        if path in ('', '/'):
            self.send_html(APP_HTML)
        elif re.match(r'^/meta/screenshots/[a-zA-Z0-9_-]+\.(png|gif|jpg|jpeg|webp)$', path):
            img = PROJECT_ROOT / path.lstrip('/')
            self.send_image(img); return
        elif path == '/api/tickets':
            tickets = load_tickets()
            if 'all=1' not in parsed.query:
                tickets = [t for t in tickets if t.get('status') != 'archived']
            self.send_json(tickets)
        elif path == '/api/handoff':
            self.send_json(load_handoff())
        elif path == '/api/git':
            self.send_json(load_git())
        elif path == '/api/why':
            file_ = parse_qs(parsed.query).get('file', [''])[0]
            self.send_json(load_why(file_))
        else:
            m = re.match(r'^/api/commit/([0-9a-f]{4,40})$', path)
            if m:
                self.send_json(load_commit(m.group(1))); return
            m = re.match(r'^/api/doc/(.+)$', path)
            if m:
                content = read_doc(unquote(m.group(1)))
                if content is None:
                    self.send_error(404); return
                self.send_json({'content': content})
            else:
                self.send_error(404)

    def do_POST(self):
        if not self._host_ok():
            self.send_error(403); return
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
            ok = write_doc(unquote(m.group(1)), str(payload.get('content', '')))
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
        if not self._host_ok():
            self.send_error(403); return
        self.send_response(204)
        self.send_header('Content-Length', 0)
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
