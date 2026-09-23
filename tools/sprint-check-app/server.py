#!/usr/bin/env python3
"""sprint-check local HTTP server — stdlib only, no pip required."""

import base64
import fnmatch
import hashlib
import json
import math
import os
import random
import re
import shutil
import socket
import string
import subprocess
import sys
import threading
import time
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

SHELL_START_TIME = time.time()  # t-ade9: this server process's own start, for Cockpit Uptime

PROJECT_ROOT = find_project_root(Path(os.environ.get('SPRINT_CHECK_ROOT', Path.cwd())))
TICKETS_DIR  = PROJECT_ROOT / '.tickets'
HANDOFF_FILE = PROJECT_ROOT / 'HANDOFF.md'
APP_HTML     = Path(__file__).parent / 'app.html'
COCKPIT_HTML = Path(__file__).parent / 'cockpit.html'

# ── Canon Cockpit project registry (t-9917) ───────────────────────────────
# One shared registry of projects the Cockpit shell can open. Stored as a JSON
# array at ~/.canon/cockpit/projects.json — paths + descriptions only, no
# secrets (DECISIONS t-06cc: no encryption). Mirrored byte-for-byte in
# sprint-check-go/main.go; the id hash + JSON field order are pinned so the two
# backends stay parity-locked (tests/sprint-check-api-parity.sh).

def _registry_dir() -> Path:
    return Path(os.environ.get('CANON_HOME', Path.home() / '.canon')) / 'cockpit'

def _registry_file() -> Path:
    return _registry_dir() / 'projects.json'

def _registry_id(abs_path: str) -> str:
    """Stable short id = first 12 hex of sha256(resolved abs path)."""
    return hashlib.sha256(abs_path.encode('utf-8')).hexdigest()[:12]

def _registry_load() -> list:
    f = _registry_file()
    try:
        data = json.loads(f.read_text(encoding='utf-8'))
        return data if isinstance(data, list) else []
    except (FileNotFoundError, ValueError):
        return []

def _registry_save(entries: list) -> None:
    d = _registry_dir()
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    f = _registry_file()
    # Field order pinned to match main.go's struct marshal order (id, path,
    # name, description, added) so parity byte-compares hold.
    f.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    try:
        os.chmod(f, 0o600)
    except OSError:
        pass

def registry_list() -> list:
    return _registry_load()

def registry_add(path: str, description: str) -> dict:
    """Add a project. Validates: existing dir + not already registered. Git is
    advisory (t-07c8): a non-git dir still registers, with a `warning`. Returns
    {ok, error?, warning?, project?}. Never writes any file other than the
    registry itself; `path` is stored as data, never opened for write."""
    raw = (path or '').strip()
    if not raw:
        return {'ok': False, 'error': 'Path is required.'}
    try:
        abs_path = str(Path(raw).expanduser().resolve(strict=True))
    except (FileNotFoundError, RuntimeError, OSError):
        return {'ok': False, 'error': 'Path does not exist.'}
    if not Path(abs_path).is_dir():
        return {'ok': False, 'error': 'Path is not a directory.'}
    warning = None
    if not (Path(abs_path) / '.git').exists():
        # t-07c8: git relaxed to a non-blocking warning — register anyway; the
        # board just shows empty git state for a non-git project.
        warning = 'Path is not a git repository!'
    pid = _registry_id(abs_path)
    entries = _registry_load()
    if any(e.get('id') == pid for e in entries):
        return {'ok': False, 'error': 'Project already registered.'}
    project = {
        'id': pid,
        'path': abs_path,
        'name': Path(abs_path).name,
        'description': (description or '').strip(),
        'added': date.today().isoformat(),
    }
    entries.append(project)
    _registry_save(entries)
    result = {'ok': True, 'project': project}
    if warning:
        result['warning'] = warning
    return result

def registry_remove(pid: str) -> dict:
    """Deregister by id — registry-only, never touches the project repo.
    Unknown id is a no-op success."""
    entries = _registry_load()
    kept = [e for e in entries if e.get('id') != pid]
    removed = len(kept) != len(entries)
    if removed:
        _registry_save(kept)
    return {'ok': True, 'removed': removed}

# ── Per-request project scoping (t-a55a, Phase 2a) ─────────────────────────
# The board is single-project at process start (PROJECT_ROOT). To render a
# chosen project inside a Cockpit tab, read endpoints accept an optional
# ?project=<registry-id>; effective_root resolves it to that registered
# project's path. Trust boundary: it resolves ONLY to a REGISTERED id, never
# to a raw client path (mirrors cockpit-docs's worktree validation). Absent →
# the process PROJECT_ROOT (today's behavior, byte-unchanged).

class UnknownProject(Exception):
    """Raised when ?project=<id> is not a registered project — caller → 400."""

def effective_root(query: dict) -> Path:
    """Resolve the project root for this request from a parsed query dict
    (parse_qs form: {'project': ['<id>']}). Absent → PROJECT_ROOT. Unknown id
    → UnknownProject (never a raw path)."""
    vals = query.get('project') if isinstance(query, dict) else None
    pid = (vals[0] if vals else '').strip()
    if not pid:
        return PROJECT_ROOT
    for e in _registry_load():
        if e.get('id') == pid:
            return Path(e['path'])
    raise UnknownProject(pid)

def tickets_dir_for(root: Path) -> Path:
    return root / '.tickets'

# t-1b88: read-only directory browser backing the Add-Project "Browse" picker.
# Lists ONLY subdirectory names/paths (never files, never file contents) so the
# browser UI can navigate to a folder and hand back its absolute path (a web page
# can't obtain an absolute path itself). Loopback + Origin gated by the caller.
def browse_dirs(path: str, show_hidden: bool = False) -> dict:
    """Resolve `path` (empty → home; '~' expanded) and list its immediate
    subdirectories. Returns {path, parent, entries:[{name,path}]} or {error}.
    Directory-names-only — files are never listed and never opened. Dotfolders
    (name starting with '.') are omitted unless show_hidden (t-340d)."""
    raw = (path or '').strip()
    try:
        base = (Path(raw).expanduser() if raw else Path.home()).resolve()
    except (RuntimeError, OSError):
        return {'error': 'invalid path'}
    if not base.is_dir():
        return {'error': 'not a directory'}
    entries = []
    try:
        with os.scandir(base) as it:
            for e in it:
                if not show_hidden and e.name.startswith('.'):
                    continue  # t-340d: hide dotfolders by default
                try:
                    if e.is_dir(follow_symlinks=True):
                        entries.append({'name': e.name, 'path': str(base / e.name)})
                except OSError:
                    continue  # unreadable entry — skip, never fail the whole listing
    except (PermissionError, OSError):
        return {'error': 'cannot read directory'}
    entries.sort(key=lambda x: x['name'].lower())
    parent = str(base.parent) if base.parent != base else None
    return {'path': str(base), 'parent': parent, 'entries': entries}

# t-7485: parse the project's AGENTS.md "Active canon skills" (AI-SKILLS) table —
# the source of truth skills.sh maintains — to report which skills a project has
# registered. Pure read (no subprocess), so it behaves identically on the Go/Windows
# binary. Mirrors tools/skills/lib.sh registered_skill_rows/skill_row_name.
_AISKILLS_BLOCK = re.compile(r'<!--\s*AI-SKILLS:BEGIN\s*-->(.*?)<!--\s*AI-SKILLS:END\s*-->', re.DOTALL)

def registered_skills(root: Path) -> list:
    """Names of canon skills registered on `root`, in AGENTS.md table order.
    Missing AGENTS.md or block → []."""
    try:
        text = (root / 'AGENTS.md').read_text(encoding='utf-8')
    except Exception:
        return []
    m = _AISKILLS_BLOCK.search(text)
    if not m:
        return []
    names = []
    for line in m.group(1).splitlines():
        if not line.startswith('| '):   # skips the |---| separator (starts '|-') and non-rows
            continue
        cells = line.split('|')          # ['', ' name ', ' category ', ' source ', '']
        if len(cells) < 2:
            continue
        name = cells[1].strip()
        if not name or name.lower() == 'skill':   # skip the header row
            continue
        names.append(name)
    return names

def project_stats(root: Path) -> dict:
    """Per-project card stats (t-a55a): last git commit time (relative) +
    number of ticket dirs under .tickets/. Read-only; used by the Projects
    cards. `updated` is a relative string ('3d ago') or '' if no git/commits."""
    updated = ''
    iso = run(['git', 'log', '-1', '--format=%cI'], root)
    if iso:
        try:
            from datetime import datetime, timezone
            when = datetime.fromisoformat(iso.strip())
            now = datetime.now(when.tzinfo or timezone.utc)
            secs = int((now - when).total_seconds())
            if secs < 60: updated = 'just now'
            elif secs < 3600: updated = f'{secs // 60}m ago'
            elif secs < 86400: updated = f'{secs // 3600}h ago'
            else: updated = f'{secs // 86400}d ago'
        except Exception:
            updated = ''
    tdir = tickets_dir_for(root)
    ticket_count = 0
    if tdir.is_dir():
        ticket_count = sum(1 for p in tdir.glob('*/ticket.md'))
    return {'updated': updated, 'ticket_count': ticket_count, 'skills': registered_skills(root)}

# ── Ticket parsing ────────────────────────────────────────────────────────

_FRONTMATTER = re.compile(r'^---\s*\n(.*?)\n---\s*\n', re.DOTALL)
_FIELD       = re.compile(r'^(\w+):\s*(.+)$', re.MULTILINE)
_MODEL_MENTION = re.compile(r'\(model:\s*([^)]+)\)', re.IGNORECASE)

def _models_used(acceptance_text: str) -> list[str]:
    seen = []
    for m in _MODEL_MENTION.finditer(acceptance_text):
        name = m.group(1).strip().lower()
        if name and name not in seen:
            seen.append(name)
    return seen
IMAGE_MIME   = {'.png': 'image/png', '.gif': 'image/gif', '.jpg': 'image/jpeg',
                 '.jpeg': 'image/jpeg', '.webp': 'image/webp'}
IMAGE_EXTS   = tuple(IMAGE_MIME)

def _doc_name(path: Path) -> str:
    return path.stem.replace('-', ' ').title()

# Must stay behaviorally identical to main.go's safeTicketDoc/containedAfterSymlinks
# (tools/sprint-check-go/main.go) — enforced by tests/sprint-check-api-parity.sh, not
# shared code. Change one, change the other, then re-run that test.
def _safe_ticket_doc(doc_file: str, exts: tuple[str, ...] = ('.md',), root: Path = None) -> Path | None:
    tdir = tickets_dir_for(root) if root is not None else TICKETS_DIR
    p = Path(doc_file)
    if p.is_absolute() or '..' in p.parts or p.suffix.lower() not in exts:
        return None
    target = tdir / p
    try:
        target.resolve().relative_to(tdir.resolve())
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
        fields['models_used'] = []
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
                fields['models_used'] = _models_used(_section(acc_text, 'Wrapup Gates'))
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

def ticket_paths(root: Path = None) -> list[Path]:
    tdir = tickets_dir_for(root) if root is not None else TICKETS_DIR
    if not tdir.is_dir():
        return []
    paths = []
    seen: set[str] = set()
    for ticket in sorted(tdir.glob('*/ticket.md')):
        paths.append(ticket)
        seen.add(ticket.parent.name)
    for f in sorted(tdir.glob('*.md')):
        if f.stem in seen:
            continue
        if re.match(r'^.+-(blueprint|acceptance|plan|decisions|qa|notes)$', f.stem):
            continue
        paths.append(f)
    return paths

def legacy_doc_target(doc_file: str, root: Path = None) -> Path | None:
    safe = Path(doc_file).name
    if not safe.endswith('.md'):
        return None
    tdir = tickets_dir_for(root) if root is not None else TICKETS_DIR
    m = re.match(r'^([A-Za-z]+-[A-Za-z0-9]+)-(.+)\.md$', safe)
    if m and (tdir / m.group(1) / 'ticket.md').is_file():
        return tdir / m.group(1) / f'{m.group(2)}.md'
    return tdir / safe

def _eval_fail_count(ticket: dict) -> int:
    try:
        return int(ticket.get('eval_fail_count') or 0)
    except (TypeError, ValueError):
        return 0

def _type_outcome_stats(tickets: list) -> dict:
    """Per-type {closed, clean} counts over closed tickets. `clean` = eval_fail_count 0/missing."""
    stats: dict = {}
    for t in tickets:
        if t.get('status') != 'closed':
            continue
        ttype = t.get('type')
        if not ttype:
            continue
        entry = stats.setdefault(ttype, {'closed': 0, 'clean': 0})
        entry['closed'] += 1
        if _eval_fail_count(t) == 0:
            entry['clean'] += 1
    return stats

def load_tickets(root: Path = None) -> list:
    tickets = []
    for f in ticket_paths(root):
        try:
            tickets.append(parse_ticket(f))
        except Exception:
            pass
    outcome_stats = _type_outcome_stats(tickets)
    for t in tickets:
        if t.get('status') in ('open', 'in_progress'):
            entry = outcome_stats.get(t.get('type'))
            if entry and entry['closed'] >= 2:
                t['type_outcome'] = entry
    with _HEADLESS_LOCK:
        running_ids = {tid for tid, state in _HEADLESS_RUNS.items() if state.get('status') == 'running'}
    if running_ids:
        for t in tickets:
            if t.get('id') in running_ids:
                t['headless_running'] = True
    return tickets

# ── HANDOFF.md parsing ────────────────────────────────────────────────────

def load_handoff(root: Path = None) -> dict:
    handoff_file = (root / 'HANDOFF.md') if root is not None else HANDOFF_FILE
    if not handoff_file.exists():
        return {'focus': None, 'raw': ''}
    raw = handoff_file.read_text(encoding='utf-8', errors='replace')
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

def load_git(root: Path = None) -> dict:
    cwd = root if root is not None else PROJECT_ROOT
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
    total_commits_raw = run(['git', 'rev-list', '--count', 'HEAD'], cwd)
    total_commits = int(total_commits_raw) if total_commits_raw.isdigit() else None
    return {'branch': branch, 'project': project, 'root': str(cwd), 'modified': modified, 'log': log, 'total_commits': total_commits}

# ── Worktrees (t-cd06) ───────────────────────────────────────────────────

def _valid_branch_name(name: str) -> bool:
    # Reuses _BASE_REF_RE's allow-list (same git-ref-name charset, defined
    # below); additionally rejects a leading '-' (would be read as a flag by
    # `git worktree add`'s argv) and '..' (path traversal once the name is
    # joined into the sibling directory path).
    return bool(name) and bool(_BASE_REF_RE.match(name)) and not name.startswith('-') and '..' not in name

def list_worktrees(ticket_id: str = '', root: Path = None) -> list[dict]:
    """Parse `git worktree list --porcelain` — the single source of truth for
    the cockpit sidebar's WORKTREE section (t-cd06's resolved design): no
    cockpit-owned registry, so a worktree created outside cockpit still shows
    up.

    t-1780: `root` scopes this to the requesting tab's own project — absent
    (older callers) falls back to the shell's own boot-time PROJECT_ROOT.
    Without it, every caller saw the shell's launch project regardless of
    which registered project's tab actually asked."""
    root = root if root is not None else PROJECT_ROOT
    raw = run(['git', 'worktree', 'list', '--porcelain'], root)
    entries: list[dict] = []
    cur: dict = {}
    for line in raw.splitlines():
        if line.startswith('worktree '):
            if cur:
                entries.append(cur)
            cur = {'path': line[len('worktree '):]}
        elif line.startswith('branch '):
            ref = line[len('branch '):]
            cur['branch'] = ref[len('refs/heads/'):] if ref.startswith('refs/heads/') else ref
        elif line.startswith('HEAD '):
            cur['head'] = line[len('HEAD '):]
        elif line == 'detached':
            cur['detached'] = True
    if cur:
        entries.append(cur)
    try:
        main_root = str(root.resolve())
    except Exception:
        main_root = str(root)
    for e in entries:
        try:
            e['is_main'] = str(Path(e['path']).resolve()) == main_root
        except Exception:
            e['is_main'] = False
    # t-e5ff: a git worktree materializes only tracked files, so when `.tickets/`
    # is gitignored a non-main worktree can't see any ticket dir — a sprint
    # started there can't find its own ticket. `git check-ignore .tickets` prints
    # the path (exit 0) when ignored, empty (exit 1, run() -> '') otherwise; a
    # non-git dir also yields '' -> treated as visible so the common
    # single-checkout case is never blocked.
    tickets_ignored = bool(run(['git', 'check-ignore', '.tickets'], root))
    for e in entries:
        e['tickets_visible'] = bool(e.get('is_main')) or not tickets_ignored
    # t-2a1c: ticket-scoped physical presence, mirroring the daemon's own
    # handleStart guard (`stat <cwd>/.tickets/<id>`, must be a dir) so the
    # board can gate the Start button on the EFFECTIVE run cwd, not just the
    # project-level check-ignore signal. Only computed when a ticket id is
    # given; the main checkout is exempt (it physically holds `.tickets/` even
    # when gitignored — same exemption the daemon applies). Absent field when
    # no ticket id is passed, keeping the field backward-compatible.
    if ticket_id:
        for e in entries:
            if e.get('is_main'):
                e['ticket_present'] = True
            else:
                try:
                    e['ticket_present'] = (Path(e['path']) / '.tickets' / ticket_id).is_dir()
                except Exception:
                    e['ticket_present'] = False
    return entries

def _is_canon_runtime_path(path: str) -> bool:
    """True for canon's own per-machine runtime files under .tickets/ that
    churn every session (t-2f53): .tickets/ACTIVE and any .tickets/**/.cockpit-*
    (.cockpit-cwd/.cockpit-agent/.cockpit-session-id). These must not count as
    user 'uncommitted changes' in the worktree carry-over warning. Path is a
    git-porcelain path (repo-root-relative, forward-slashed)."""
    p = path.strip().strip('"').replace('\\', '/')
    if p == '.tickets/ACTIVE':
        return True
    if p.startswith('.tickets/') and p.rsplit('/', 1)[-1].startswith('.cockpit-'):
        return True
    return False

def _main_dirty_ignoring_runtime(root: Path = None) -> bool:
    """main_dirty for the worktree carry-over warning, ignoring canon-owned
    runtime files (t-2f53). --untracked-files=all so a fresh/untracked runtime
    file lists individually (default porcelain collapses a fully-untracked dir
    to '?? dir/', hiding it); a deleted tracked runtime file lists individually
    regardless. A porcelain line is 'XY <path>' (2 status chars + space), so the
    path starts at index 3.

    t-1780: `root` scopes this to the requesting tab's own project."""
    root = root if root is not None else PROJECT_ROOT
    status = run(['git', 'status', '--porcelain', '--untracked-files=all'], root)
    for line in status.splitlines():
        if not line.strip():
            continue
        path = line[3:] if len(line) > 3 else line
        if not _is_canon_runtime_path(path):
            return True
    return False

def worktree_lock_status(ticket_id: str, root: Path = None) -> dict:
    """Advisory-only read of .tickets/<id>/.cockpit-cwd (t-cd06 amendment) — the
    daemon owns writing that file and already ignores a locked ticket's
    requested cwd; this just lets the board warn before the choice is made
    for an in_progress ticket's first resume, since a worktree checkout only
    carries committed history.

    t-1780: `root` scopes this to the requesting tab's own project — absent
    (older callers) falls back to the shell's own boot-time PROJECT_ROOT."""
    root = root if root is not None else PROJECT_ROOT
    cwd_path = tickets_dir_for(root) / ticket_id / '.cockpit-cwd'
    cwd = None
    if cwd_path.is_file():
        cwd = cwd_path.read_text(encoding='utf-8', errors='replace').strip() or None
    dirty = _main_dirty_ignoring_runtime(root)
    return {'locked': cwd is not None, 'cwd': cwd, 'main_dirty': dirty}

def worktree_unlock(ticket_id: str, root: Path = None) -> dict:
    """Clear a ticket's worktree lock (t-fe3c). The daemon reuses the persisted
    cwd for every start of an in_progress ticket and ignores the client's
    request, so clearing it is the only way to redirect a ticket to a different
    worktree (or the main checkout) — e.g. one locked to a worktree that can't
    see .tickets/ (t-e5ff). Advisory + reversible: the files regenerate on the
    next start; a running session is unaffected (the cwd was read at spawn time).

    t-9203: clear BOTH .cockpit-cwd AND .cockpit-session-id. Clearing the cwd
    alone lets the next start re-resolve the directory, but the persisted
    session id would still make claude `--resume` (or pi continue) the prior
    conversation *in the new directory* — exactly the cross-dir reattach the
    daemon's invariant forbids. Dropping the session id too means the next Start
    is a genuinely fresh session in the worktree you pick next.

    Idempotent: unlocking an already-unlocked ticket is ok:true, unlocked:false.
    A real delete failure (permissions, read-only fs) is reported as ok:false
    rather than surfaced as an uncaught 500 (review finding, t-fe3c) — matches
    main.go's explicit error return.

    t-1780: `root` scopes this to the requesting tab's own project — a stale
    global TICKETS_DIR meant unlocking a non-primary project's ticket looked in
    the wrong project's .tickets/ and silently no-op'd."""
    root = root if root is not None else PROJECT_ROOT
    td = tickets_dir_for(root)
    paths = [td / ticket_id / '.cockpit-cwd',
             td / ticket_id / '.cockpit-session-id']
    unlocked = False
    for p in paths:
        if p.is_file():
            try:
                p.unlink()
            except OSError as e:
                return {'ok': False, 'error': str(e)}
            unlocked = True
    return {'ok': True, 'unlocked': unlocked}

def cockpit_docs(ticket_id: str, cwd: str):
    """t-1357: read a cockpit ticket's plan.md / acceptance.md / HANDOFF.md from
    the WORKTREE the session runs in, not the board's main checkout. A worktree
    sprint writes those on its own branch, so the main `.tickets/<id>/` shows
    only the committed `ticket.md`; the cockpit rail should reflect the tree the
    agent is actually editing.

    Returns None (caller -> 400) when `cwd` is not a real registered worktree —
    the board never reads an arbitrary client-supplied directory (same trust
    model as the daemon's resolveSpawnCwd). Read-only; every doc path is
    contained under <cwd>/.tickets (same posture as _safe_ticket_doc). Must stay
    behaviorally identical to main.go's cockpitDocs — see
    tests/sprint-check-api-parity.sh."""
    try:
        cwd_real = Path(cwd).resolve(strict=True)  # strict: a removed-from-disk
        # worktree -> FileNotFoundError -> None (400), matching main.go's
        # filepath.EvalSymlinks failure (parity, t-1357 reviewer finding).
    except (OSError, RuntimeError):
        return None
    # t-1780: run from cwd_real itself, not the global PROJECT_ROOT — `git
    # worktree list` reports every sibling of whichever repo it's run inside,
    # so this self-contained call is correct for any project without needing
    # a separate ?project= lookup.
    worktrees = set()
    for e in list_worktrees(root=cwd_real):
        try:
            worktrees.add(Path(e['path']).resolve())
        except Exception:
            pass
    if cwd_real not in worktrees:
        return None
    tickets = cwd_real / '.tickets'

    def _read(rel: str):
        target = tickets / rel
        try:
            target.resolve().relative_to(tickets.resolve())
        except ValueError:
            return None
        if not target.is_file():
            return None
        return target.read_text(encoding='utf-8', errors='replace')

    if (tickets / ticket_id).is_dir():
        plan = _read(f'{ticket_id}/plan.md')
        acceptance = _read(f'{ticket_id}/acceptance.md')
    else:
        plan = _read(f'{ticket_id}-plan.md')
        acceptance = _read(f'{ticket_id}-acceptance.md')
    handoff_path = cwd_real / 'HANDOFF.md'
    handoff = handoff_path.read_text(encoding='utf-8', errors='replace') if handoff_path.is_file() else None
    return {'plan': plan, 'acceptance': acceptance, 'handoff': handoff}

def _worktreeinclude_patterns(root: Path = None) -> list[str]:
    root = root if root is not None else PROJECT_ROOT
    p = root / '.worktreeinclude'
    if not p.is_file():
        return []
    patterns = []
    for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            patterns.append(line)
    return patterns

def _copy_worktreeinclude_files(dest: Path, root: Path = None) -> list[str]:
    """Copies gitignored files matching `.worktreeinclude` patterns into a
    freshly created worktree — a worktree is a fresh checkout, so a gitignored
    file like `.env` (never committed) is otherwise absent from it. Matches
    Claude Code's and Codex's own `.worktreeinclude` convention: only a file
    that is BOTH pattern-matched AND actually gitignored is copied, so tracked
    files are never duplicated. Simple `fnmatch` glob matching (not a full
    gitignore-pattern engine) — covers the documented use case (bare
    filenames, simple globs) but not every gitignore syntax edge case."""
    root = root if root is not None else PROJECT_ROOT
    patterns = _worktreeinclude_patterns(root)
    if not patterns:
        return []
    ignored_raw = run(['git', 'ls-files', '--others', '--ignored', '--exclude-standard'], root)
    copied = []
    for relpath in ignored_raw.splitlines():
        relpath = relpath.strip()
        if not relpath:
            continue
        if any(fnmatch.fnmatch(relpath, pat) or fnmatch.fnmatch(Path(relpath).name, pat) for pat in patterns):
            src = root / relpath
            dst = dest / relpath
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                copied.append(relpath)
            except OSError:
                pass  # best-effort — a copy failure never blocks worktree creation
    return copied

def _sync_uncommitted_tickets(dest: Path, root: Path = None) -> list[str]:
    """Copies the main checkout's uncommitted `.tickets/` edits (modified
    tracked files + new untracked, non-ignored ones) into a freshly created
    worktree. `git worktree add` materializes only committed content, so a
    ticket flag set in the board but not yet committed (e.g. `demo: true`)
    is otherwise invisible to the sprint that runs in the worktree. Callers
    invoke this only for a brand-new branch: an existing branch's own ticket
    files may be ahead of main's and must not be overwritten."""
    root = root if root is not None else PROJECT_ROOT
    changed = run(['git', '-c', 'core.quotepath=off', 'diff', '--name-only', 'HEAD', '--', '.tickets'], root)
    new = run(['git', '-c', 'core.quotepath=off', 'ls-files', '--others', '--exclude-standard', '--', '.tickets'], root)
    copied = []
    for relpath in (changed + '\n' + new).splitlines():
        relpath = relpath.strip()
        src = root / relpath
        if not relpath or not src.is_file():
            continue  # deleted in main, or blank line
        dst = dest / relpath
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            copied.append(relpath)
        except OSError:
            pass  # best-effort — a copy failure never blocks worktree creation
    return copied

def create_worktree(branch: str, root: Path = None) -> dict:
    """`git worktree add` as a sibling checkout, nebula's own convention:
    `<repo>/../<repo-name>-worktrees/<branch-with-slashes-as-dashes>`. Falls
    back to checking out an existing branch (no `-b`) if it already exists,
    per the ticket's resolved design. Always an argv list, never a shell
    string. Caller (do_POST) validates `branch` against `_valid_branch_name`
    and 400s before this runs — malformed input never reaches here.

    t-1780: `root` scopes this to the requesting tab's own project."""
    root = root if root is not None else PROJECT_ROOT
    sibling_root = root.parent / f'{root.name}-worktrees'
    path = sibling_root / branch.replace('/', '-')
    if path.exists():
        return {'ok': False, 'error': 'path already exists'}
    sibling_root.mkdir(parents=True, exist_ok=True)
    new_branch = True
    try:
        subprocess.run(['git', 'worktree', 'add', str(path), '-b', branch],
                        cwd=root, check=True, capture_output=True, text=True, timeout=15)
    except subprocess.CalledProcessError:
        new_branch = False
        try:
            subprocess.run(['git', 'worktree', 'add', str(path), branch],
                            cwd=root, check=True, capture_output=True, text=True, timeout=15)
        except subprocess.CalledProcessError as e2:
            return {'ok': False, 'error': (e2.stderr or str(e2)).strip()[:500]}
    except Exception as e:
        return {'ok': False, 'error': str(e)[:500]}
    copied = _copy_worktreeinclude_files(path, root)
    tickets_synced = _sync_uncommitted_tickets(path, root) if new_branch else []
    _link_skills_into_worktree(path)
    return {'ok': True, 'path': str(path), 'branch': branch, 'worktreeinclude_copied': copied, 'tickets_synced': tickets_synced}

def _link_skills_into_worktree(path: Path) -> None:
    """t-f99b: create the canon skills link inside a freshly-created worktree so
    it resolves to CURRENT canon. The skill mirror is gitignored (never
    committed), so a git worktree has no mirror otherwise. Inline (not a
    `skills.sh` shell-out) to match sprint-check-go and avoid a `bash`-on-PATH
    dependency on Windows. Best-effort; non-fatal."""
    tools = Path(__file__).resolve().parent.parent   # tools/
    target = tools.parent / 'skills'                  # <canon>/skills
    if not target.exists():
        return
    for rel in ('.agents/skills', '.claude/skills'):
        link = path / rel
        if link.exists():
            # t-9e55: REPLACE a git-tracked committed canon mirror (carries the
            # sprint/SKILL.md marker) so the worktree serves CURRENT canon —
            # `git worktree add` materializes the stale committed copy before this
            # runs, so the old skip served stale skills. Untrack it in the
            # worktree's own index (main untouched; durable cross-checkout fix is
            # the consumer's `skills.sh refresh` + commit). PRESERVE a genuine
            # project-local skills dir / an already-correct link.
            if _is_committed_canon_mirror(path, rel, link):
                subprocess.run(['git', '-C', str(path), 'rm', '-r', '--cached', '--quiet', '--', rel],
                               check=False, capture_output=True)
                shutil.rmtree(link, ignore_errors=True)
            else:
                continue
        link.parent.mkdir(parents=True, exist_ok=True)
        try:
            if os.name == 'nt':
                subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(target)],
                               check=False, capture_output=True)
            else:
                os.symlink(target, link)
        except OSError:
            pass

def _is_committed_canon_mirror(worktree: Path, rel: str, link: Path) -> bool:
    """t-9e55: True iff the materialized mirror path is the git-tracked committed
    canon mirror t-f99b forbids — tracked in the worktree's index AND carrying the
    canon marker (sprint/SKILL.md). A genuine project-local skills dir (untracked,
    or lacking the marker) returns False and is preserved. Parity with
    sprint-check-go's isCommittedCanonMirror and project.sh's link_worktree."""
    out = subprocess.run(['git', '-C', str(worktree), 'ls-files', '--', rel],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return False
    return (link / 'sprint' / 'SKILL.md').exists()

# ── Commit detail ─────────────────────────────────────────────────────────

def load_commit(hash_: str, root: Path = None) -> dict:
    cwd = root if root is not None else PROJECT_ROOT
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

def _ticket_by_id(ticket_id: str, root: Path = None) -> tuple[Path, dict] | None:
    for path in ticket_paths(root):
        try:
            ticket = parse_ticket(path)
        except Exception:
            continue
        if ticket.get('id') == ticket_id:
            return path, ticket
    return None

def _known_ticket_ids(root: Path = None) -> set[str]:
    ids = set()
    for path in ticket_paths(root):
        try:
            ticket_id = str(parse_ticket(path).get('id', ''))
        except Exception:
            continue
        if ticket_id:
            ids.add(ticket_id)
    return ids

def _cap_with_more(items: list, max_n: int) -> tuple[list, int]:
    """Truncate items to max_n, assuming items is already in the desired
    display order (e.g. most-recent-first) — this only truncates, never
    re-sorts. Returns (capped_items, more_count)."""
    if len(items) <= max_n:
        return items, 0
    return items[:max_n], len(items) - max_n

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

def _basename_candidates(basename: str, cwd: Path) -> list[str]:
    out = run(['git', 'log', '--all', '--name-only', '--format='], cwd)
    matches = {line for line in out.splitlines() if line.strip() and Path(line).name == basename}
    return sorted(matches)

def load_why(file_: str, root: Path = None) -> dict:
    target = file_.strip()
    if not target:
        return {'file': '', 'results': [], 'message': 'Enter a file path.'}

    p = Path(target)
    if p.is_absolute() or '..' in p.parts:
        return {'file': target, 'results': [], 'message': 'Use a project-relative file path.'}

    cwd = root if root is not None else PROJECT_ROOT
    query_target = target
    log_subjects = run(['git', 'log', '--follow', '--format=%s', '--', query_target], cwd)
    resolved_path = None
    alternatives = []
    if not log_subjects:
        candidates = _basename_candidates(p.name, cwd) if p.name else []
        if len(candidates) == 1:
            query_target = candidates[0]
            resolved_path = query_target
            log_subjects = run(['git', 'log', '--follow', '--format=%s', '--', query_target], cwd)
        elif len(candidates) > 1:
            # Rank by commit count — most-changed file first
            counted = []
            for c in candidates:
                n = run(['git', 'log', '--oneline', '--', c], cwd)
                counted.append((len(n.splitlines()) if n else 0, c))
            counted.sort(key=lambda x: -x[0])
            query_target = counted[0][1]
            resolved_path = query_target
            alternatives = [c for _, c in counted[1:]][:5]
            log_subjects = run(['git', 'log', '--follow', '--format=%s', '--', query_target], cwd)
    if not log_subjects:
        return {'file': target, 'results': [], 'message': f'No git history found for {target}.'}

    matched_ids: list[str] = []
    def add_unique(ticket_id: str):
        if ticket_id not in matched_ids:
            matched_ids.append(ticket_id)

    known_ids = _known_ticket_ids(root)
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
            for path in ticket_paths(root):
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

    capped_ids, more = _cap_with_more(matched_ids, 10)

    results = []
    for ticket_id in capped_ids:
        found = _ticket_by_id(ticket_id, root)
        if not found:
            continue
        path, ticket = found
        results.append({
            'id': ticket.get('id', ticket_id),
            'status': ticket.get('status', ''),
            'title': ticket.get('title', ''),
            'decision': _plan_decision(path),
        })

    result = {
        'file': target,
        'results': results,
        'more': more,
        'file_exists': (Path(cwd) / query_target).exists(),
        'message': '' if results else f'No tickets found for {target}.',
    }
    if resolved_path:
        result['resolved_path'] = resolved_path
    if alternatives:
        result['alternatives'] = alternatives
    return result

# ── Status write ──────────────────────────────────────────────────────────

def _find_ticket_path(ticket_id: str, root: Path = None) -> Path | None:
    tdir = tickets_dir_for(root) if root is not None else TICKETS_DIR
    if not tdir.is_dir():
        return None
    folder_ticket = tdir / ticket_id / 'ticket.md'
    if folder_ticket.is_file():
        return folder_ticket
    flat_ticket = tdir / f'{ticket_id}.md'
    if flat_ticket.is_file():
        return flat_ticket
    for f in ticket_paths(root):
        try:
            if parse_ticket(f).get('id') == ticket_id:
                return f
        except Exception:
            pass
    return None

def _update_active(canonical_id: str, new_status: str, root: Path = None) -> None:
    """Mirrors tkt's set_active/clear_active_if: in_progress claims ACTIVE,
    any other status clears it if this ticket currently holds it."""
    tdir = tickets_dir_for(root) if root is not None else TICKETS_DIR
    active_file = tdir / 'ACTIVE'
    if new_status == 'in_progress':
        active_file.write_text(canonical_id + '\n', encoding='utf-8')
        return
    if active_file.is_file():
        current = active_file.read_text(encoding='utf-8', errors='replace').strip()
        if current == canonical_id:
            active_file.unlink()

def write_status(ticket_id: str, new_status: str, root: Path = None) -> bool:
    path = _find_ticket_path(ticket_id, root)
    if not path:
        return False
    text = path.read_text(encoding='utf-8', errors='replace')
    updated = re.sub(r'^(status:\s*)(\S+)$', lambda m: m.group(1) + new_status, text, flags=re.MULTILINE)
    if updated == text:
        return False
    path.write_text(updated, encoding='utf-8')
    canonical_id = parse_ticket(path).get('id', ticket_id)
    _update_active(canonical_id, new_status, root)
    return True

def write_demo(ticket_id: str, want: bool, root: Path = None) -> bool:
    """Toggle the boolean `demo` frontmatter field on an existing ticket. ON ensures a
    `demo: true` line (appended as the last frontmatter field); OFF removes any `demo:` line
    (absent = false, matching `tkt demo`). Returns True if the ticket exists (idempotent).
    Kept byte-for-byte identical to main.go's writeDemo — parity-tested (t-64a0)."""
    path = _find_ticket_path(ticket_id, root)
    if not path:
        return False
    text = path.read_text(encoding='utf-8', errors='replace')
    fm_match = _FRONTMATTER.match(text)
    if not fm_match:
        return False
    kept = [ln for ln in fm_match.group(1).split('\n') if not ln.startswith('demo:')]
    if want:
        kept.append('demo: true')
    updated = '---\n' + '\n'.join(kept) + '\n---\n' + text[fm_match.end():]
    if updated != text:
        path.write_text(updated, encoding='utf-8')
    return True

def write_body(ticket_id: str, new_body: str, root: Path = None) -> bool:
    """Replace the body (everything after frontmatter) of a ticket."""
    path = _find_ticket_path(ticket_id, root)
    if not path:
        return False
    text = path.read_text(encoding='utf-8', errors='replace')
    fm_match = _FRONTMATTER.match(text)
    updated = (text[:fm_match.end()] if fm_match else '') + new_body.strip() + '\n'
    path.write_text(updated, encoding='utf-8')
    return True

def read_doc(doc_file: str, root: Path = None) -> str | None:
    """Read a companion doc file safely from TICKETS_DIR."""
    p = _safe_ticket_doc(doc_file, root=root)
    if p is None or not p.is_file():
        p = legacy_doc_target(doc_file, root)
    if p is None or not p.is_file():
        return None
    return p.read_text(encoding='utf-8', errors='replace')

def create_ticket(title: str, type_: str, status: str, priority: int, body: str, ci: bool = False, eval_override: bool = False, gate: str = 'full', demo: bool = False, skills: str = '', worktree_preference: str = '', root: Path = None) -> dict:
    """Create a new canonical ticket folder and return its parsed data."""
    tdir = tickets_dir_for(root) if root is not None else TICKETS_DIR
    tdir.mkdir(exist_ok=True)
    existing = {p.stem for p in ticket_paths(root)} | {p.name for p in tdir.iterdir() if p.is_dir()}
    chars = string.ascii_lowercase + string.digits
    while True:
        ticket_id = 't-' + ''.join(random.choices(chars, k=4))
        if ticket_id not in existing:
            break
    created = date.today().isoformat()
    safe_title = title.replace('\n', ' ').strip()
    fm_lines = [
        '---',
        f'id: {ticket_id}',
        f'title: {safe_title}',
        f'status: {status}',
        f'type: {type_}',
        f'priority: {priority}',
        f'created: {created}',
    ]
    if ci:
        fm_lines.append('ci: true')
    if gate == 'eval':
        # eval-only headless gate; absent line = full (mirrors ci's present/absent convention)
        fm_lines.append('gate: eval')
    if demo:
        # demo close-path; absent line = false (mirrors ci/gate present/absent convention)
        fm_lines.append('demo: true')
    # t-354b: maintenance skills (chore multi-select) — csv, allowlisted to the
    # three repo-hygiene skills so the field can never inject arbitrary frontmatter.
    # Order-preserving dedupe; absent line = none (same present/absent convention).
    _MAINT_SKILLS = ('context-check', 'context-doctor', 'dead-code-cleanup')
    picked = []
    for s in (skills or '').split(','):
        s = s.strip()
        if s in _MAINT_SKILLS and s not in picked:
            picked.append(s)
    if picked:
        fm_lines.append('skills: ' + ','.join(picked))
    # t-644a: a declared worktree preference, applied only later at first
    # Start (see renderCockpitWorktree's pre-fill) -- present/absent
    # convention, same as demo/gate above. Nothing on disk is created yet.
    safe_wt = worktree_preference.strip().replace('\n', ' ')
    if safe_wt:
        fm_lines.append(f'worktree_preference: {safe_wt}')
    fm_lines.append(f'eval_override: {"true" if eval_override else "false"}')
    fm_lines.append('---\n')
    fm = '\n'.join(fm_lines)
    full = fm + '\n' + body.strip() + '\n' if body.strip() else fm
    ticket_dir = tdir / ticket_id
    ticket_dir.mkdir()
    path = ticket_dir / 'ticket.md'
    path.write_text(full, encoding='utf-8')
    return parse_ticket(path)

def write_doc(doc_file: str, content: str, root: Path = None) -> bool:
    """Write a companion doc under TICKETS_DIR."""
    p = _safe_ticket_doc(doc_file, root=root)
    if p is None:
        p = legacy_doc_target(doc_file, root)
    if p is None:
        return False
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content.strip() + '\n', encoding='utf-8')
    return True

# Must stay behaviorally identical to main.go's writeVisual (t-626d) — enforced
# by tests/sprint-check-api-parity.sh, not shared code.
MAX_VISUAL_BYTES = 8 * 1024 * 1024
_SAFE_VISUAL_NAME = re.compile(r'^[A-Za-z0-9_.-]+$')

def _dedupe_visual_name(ticket_id: str, filename: str, root: Path = None) -> str | None:
    """Return a collision-free filename under .tickets/<id>/visuals/, auto-suffixing
    before the extension (never overwrites). None if filename is unsafe."""
    stem, ext = os.path.splitext(filename)
    if not _SAFE_VISUAL_NAME.match(filename) or ext.lower() not in IMAGE_EXTS:
        return None
    candidate = filename
    n = 2
    while True:
        target = _safe_ticket_doc(f'{ticket_id}/visuals/{candidate}', exts=IMAGE_EXTS, root=root)
        if target is None:
            return None
        if not target.is_file():
            return candidate
        candidate = f'{stem}-{n}{ext}'
        n += 1

def write_visual(ticket_id: str, filename: str, data_b64: str, root: Path = None) -> dict:
    """Decode a base64-encoded image and write it to .tickets/<id>/visuals/,
    auto-suffixing on filename collision. {'ok': False} on any validation failure."""
    try:
        raw = base64.b64decode(data_b64, validate=True)
    except Exception:
        return {'ok': False}
    if not raw or len(raw) > MAX_VISUAL_BYTES:
        return {'ok': False}
    name = _dedupe_visual_name(ticket_id, filename, root)
    if name is None:
        return {'ok': False}
    target = _safe_ticket_doc(f'{ticket_id}/visuals/{name}', exts=IMAGE_EXTS, root=root)
    if target is None:
        return {'ok': False}
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw)
    return {'ok': True, 'filename': name}

# ── Headless grading runs (t-200b) ──────────────────────────────────────────
# tools/sprint-headless is referenced by a path relative to this file's own
# location, never via $PATH — the server process's own location is always
# known, regardless of the invoking user's shell setup (t-9737/t-d351/t-af61
# class of PATH-resolution problems doesn't apply here).
#
# SPRINT_HEADLESS_BIN/SPRINT_HEADLESS_EVAL_BIN override (tests point at a
# stub); mirrors COCKPIT_DAEMON_BIN (t-1781) — the real corruption mechanism
# this override replaces was a test harness overwriting the real on-disk
# script in place, restored via a same-process finally/trap that can't
# survive an uncatchable kill mid-test (see research.md).

SPRINT_HEADLESS = Path(os.environ.get('SPRINT_HEADLESS_BIN')
                        or Path(__file__).resolve().parent.parent / 'sprint-headless')
SPRINT_HEADLESS_EVAL = Path(os.environ.get('SPRINT_HEADLESS_EVAL_BIN')
                             or Path(__file__).resolve().parent.parent / 'sprint-headless-eval')
CANON_GATE_TEMPLATE = Path(__file__).resolve().parent.parent / 'canon-gate-template.yml'
SKILLS_SH = Path(os.environ.get('SKILLS_SH_BIN') or Path(__file__).resolve().parent.parent / 'skills.sh')
# t-96c3: the Cockpit only registers the two "important" onboarding skills from a
# card. A fixed server-side allowlist keeps the trust boundary a constant even
# though the client now chooses WHICH of the two — no arbitrary skill reaches the
# shell-out.
REGISTERABLE_SKILLS = ('sprint', 'efficiency')

def register_skill(root: Path, skill: str = 'sprint') -> dict:
    """t-7485/t-96c3: register a canon skill into `root` by shelling out to
    skills.sh (argv list, non-interactive, timeout-bounded). `skill` must be in
    the fixed REGISTERABLE_SKILLS allowlist — never an arbitrary client value —
    and the dir is registry-resolved. Degrades to {ok:False, unsupported:True,
    cmd:<hint>} where bash or skills.sh isn't available."""
    if skill not in REGISTERABLE_SKILLS:
        return {'ok': False, 'error': f'only {" / ".join(REGISTERABLE_SKILLS)} can be registered from the Cockpit'}
    hint = f'{SKILLS_SH} add {skill} {root}'
    bash = shutil.which('bash')
    if not bash or not SKILLS_SH.exists():
        return {'ok': False, 'unsupported': True, 'cmd': hint}
    try:
        # t-b47a: stdin=DEVNULL alone does NOT make skills.sh's setup prompts
        # non-interactive — they read from /dev/tty directly, a POSIX facility
        # independent of stdin, so a long-lived server subprocess still finds
        # its launch terminal's controlling tty and prompts there, unanswered.
        # SKILLS_SH_ASSUME_YES tells the three project-scoped prompts (AGENTS.md
        # bridge, model-tiers note, subagent-log.sh permission) to apply their
        # recommended default immediately instead of waiting on that prompt.
        env = {**os.environ, 'SKILLS_SH_ASSUME_YES': '1'}
        p = subprocess.run([bash, str(SKILLS_SH), 'add', skill, str(root)],
                           cwd=str(root), stdin=subprocess.DEVNULL, env=env,
                           capture_output=True, text=True, timeout=60)
    except Exception as e:
        return {'ok': False, 'unsupported': True, 'cmd': hint, 'error': str(e)[:200]}
    if p.returncode != 0:
        return {'ok': False, 'error': (p.stderr or p.stdout or 'skills.sh failed').strip()[:400], 'cmd': hint}
    return {'ok': True, 'skills': registered_skills(root)}


# ── Cockpit daemon integration (t-ddc8) ─────────────────────────────────────
# The board never owns a PTY (t-1262 lesson): it discovers/launches the shipped
# cockpit-daemon (which owns the PTY) and the frontend iframes its /cockpit page.
# The board reads only the daemon's addr from the 0600 daemon.json; the token
# stays daemon-side. The spawn argv is fixed — no board/user input is
# interpolated. Kept behaviorally identical to main.go's cockpit* helpers —
# parity-tested by tests/sprint-check-api-parity.sh.
import tempfile
import urllib.request

def _resolve_cockpit_daemon(os_name: str = os.name) -> str:
    """COCKPIT_DAEMON_BIN overrides (tests point at a stub); otherwise the first
    existing of the platform candidates. On Windows the shipped, git-tracked
    tools/cockpit-daemon-win.exe (built by scripts/build-zip.sh, mirroring the
    sprint-check-win.exe convention) comes first, then the dev build
    tools/cockpit-daemon/cockpit-daemon.exe. On Unix it is the built
    tools/cockpit-daemon/cockpit-daemon. Parity with sprint-check-go's
    resolveCockpitDaemon/cockpitDaemonCandidates. os_name is a parameter (not read
    inline) so the Windows branch is testable on any host."""
    override = os.environ.get('COCKPIT_DAEMON_BIN')
    if override:
        return override
    tools = Path(__file__).resolve().parent.parent
    if os_name == 'nt':
        candidates = [
            tools / 'cockpit-daemon-win.exe',                       # shipped prebuilt first
            tools / 'cockpit-daemon' / 'cockpit-daemon.exe',        # dev build fallback
        ]
    else:
        candidates = [tools / 'cockpit-daemon' / 'cockpit-daemon']
    for c in candidates:
        if c.exists():
            return str(c)
    return str(candidates[0])

def board_version() -> dict:
    """t-99fa/t-5c20: build identity of this board + the resolved cockpit-daemon.
    Shape (parity with sprint-check-go's /api/version): {version, commit, daemon}.
    `version` = the repo-root VERSION file semver (the human identifier);
    `commit` = short SHA of the last commit touching server.py (provenance, may
    differ from the Go binary's stamped commit — build-time vs runtime, t-99fa);
    `daemon` = the cockpit-daemon's `--version` string (best-effort, "" if
    unbuilt). Fallbacks: "dev"."""
    server_dir = Path(__file__).resolve().parent
    # t-5c20: the semantic version is the repo-root VERSION file (the human id);
    # the SHA is provenance only.
    try:
        semver = (Path(__file__).resolve().parents[2] / 'VERSION').read_text(encoding='utf-8').strip() or 'dev'
    except Exception:
        semver = 'dev'
    commit = run(['git', 'log', '-1', '--format=%h', '--', 'server.py'], server_dir) or 'dev'
    daemon = run([_resolve_cockpit_daemon(), '--version'], server_dir)
    return {'version': semver, 'commit': commit, 'daemon': daemon}

def _resolve_cockpit_sprint_bin() -> str:
    """Passes through an explicit COCKPIT_SPRINT_BIN override (e.g. a test
    stub); otherwise empty, so the daemon's own default ("claude", t-842b)
    applies — never the bash sprint CLI, which doesn't understand claude's
    --settings flag (t-7bdd)."""
    return os.environ.get('COCKPIT_SPRINT_BIN', '')

COCKPIT_DAEMON_BIN = _resolve_cockpit_daemon()
COCKPIT_SPRINT_BIN = _resolve_cockpit_sprint_bin()

def _cockpit_state_dir() -> str:
    return os.environ.get('COCKPIT_STATE_DIR') or os.path.join(tempfile.gettempdir(), 'canon-cockpit-board')

def _cockpit_healthy(addr: str) -> bool:
    if not addr:
        return False
    try:
        with urllib.request.urlopen(f'http://{addr}/healthz', timeout=0.4) as r:
            return r.status == 200
    except Exception:
        return False

def _discover_cockpit_addr() -> tuple[str, bool]:
    """Read the daemon addr (only the addr, never the token) from daemon.json
    and report whether that daemon answers /healthz."""
    try:
        raw = Path(_cockpit_state_dir(), 'daemon.json').read_text(encoding='utf-8')
        addr = str(json.loads(raw).get('addr', ''))
    except Exception:
        return '', False
    return addr, _cockpit_healthy(addr)

def cockpit_discover() -> dict:
    addr, ok = _discover_cockpit_addr()
    out = {'running': ok, 'addr': addr or None,
           'shell_uptime_secs': int(time.time() - SHELL_START_TIME)}
    if ok:
        out.update(_cockpit_build_status(addr))
    return out

def cockpit_sessions() -> list:
    """t-391a: proxy the daemon's unauthenticated /sessions — the active cockpit
    sessions across EVERY project the one daemon serves (nebula's model). Addr-only
    discovery, no token (mirrors cockpit_discover / the /version reads). Returns []
    when no healthy daemon or on any error, so the board renders an empty panel."""
    addr, ok = _discover_cockpit_addr()
    if not ok:
        return []
    try:
        with urllib.request.urlopen(f'http://{addr}/sessions', timeout=0.6) as r:
            data = json.loads(r.read().decode('utf-8'))
        return data if isinstance(data, list) else []
    except Exception:
        return []

def _read_daemon_pid():
    """t-44d9: the daemon's own pid from daemon.json (written by the daemon), so
    the board can force-restart it without holding the boot token (t-ddc8)."""
    try:
        raw = Path(_cockpit_state_dir(), 'daemon.json').read_text(encoding='utf-8')
        pid = json.loads(raw).get('pid')
        return int(pid) if pid else None
    except Exception:
        return None

def _kill_daemon_pid(pid: int) -> None:
    """Cross-platform pid-kill shared by cockpit_restart/cockpit_stop (t-44d9/t-a30c):
    unix SIGTERM (the daemon's graceful handler reaps agent children); Windows
    `taskkill /T` (tree-kill reaps children directly). Waits for it to exit
    (its handler clears daemon.json / stops answering). OS process control
    only, never the boot token (t-ddc8 preserved)."""
    try:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.run(['kill', '-TERM', str(pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    for _ in range(50):
        _, ok = _discover_cockpit_addr()
        if not ok:
            break
        time.sleep(0.1)

def cockpit_restart(force: bool = False) -> dict:
    """t-44d9: force-restart the cockpit daemon. Warns (busy) when sessions are
    live unless force, then pid-kills (_kill_daemon_pid) and relaunches via
    ensure_cockpit."""
    n = len(cockpit_sessions())
    if n > 0 and not force:
        return {'ok': False, 'busy': True, 'sessions': n}
    pid = _read_daemon_pid()
    if pid:
        _kill_daemon_pid(pid)
    # ensure_cockpit clears any stale daemon.json and launches a fresh daemon.
    out = ensure_cockpit()
    # Honest signal: only "restarted" if a NEW daemon was actually launched — if
    # the kill didn't take and ensure_cockpit reused the live one, say so (reviewer t-44d9).
    out['restarted'] = bool(out.get('launched'))
    return out

def cockpit_stop(force: bool = False) -> dict:
    """t-a30c: stop the cockpit daemon WITHOUT relaunching it — saves a manual
    Ctrl-C in the terminal it was started from. Same busy-confirm gate and
    pid-kill as cockpit_restart, minus the ensure_cockpit() relaunch. The
    daemon still comes back on demand next time a cockpit tab is opened
    (ensure_cockpit), so this is not a permanent kill switch. Never touches
    the daemon's token-gated /shutdown — OS process control only (t-ddc8)."""
    n = len(cockpit_sessions())
    if n > 0 and not force:
        return {'ok': False, 'busy': True, 'sessions': n}
    pid = _read_daemon_pid()
    if not pid:
        return {'ok': True, 'stopped': False, 'running': False}
    _kill_daemon_pid(pid)
    _, running = _discover_cockpit_addr()
    return {'ok': True, 'stopped': not running, 'running': running}

# t-74d6: detect a version-drifted (stale) running daemon. The board reuses a
# detached daemon by liveness alone (see ensure_cockpit), so after the binary is
# rebuilt the old daemon keeps serving until restarted. The board never holds
# the daemon token, but /version is unauthenticated — so the board CAN read the
# running build and compare it to the on-disk binary. The signal is the
# executable's mtime, NOT the version string: local `dev` builds all share one
# string, so a string compare could never flag a rebuilt-in-place daemon.
def _cockpit_binary_mtime() -> int:
    try:
        return int(os.path.getmtime(COCKPIT_DAEMON_BIN))
    except Exception:
        return 0

def _cockpit_running_build(addr: str) -> dict | None:
    """The RUNNING daemon's /version (unauthenticated JSON: version + exe_mtime).
    None if unreachable or not JSON (a daemon predating this build)."""
    if not addr:
        return None
    try:
        with urllib.request.urlopen(f'http://{addr}/version', timeout=0.4) as r:
            data = json.loads(r.read().decode('utf-8'))
        return {'version': str(data.get('version', '')),
                'exe_mtime': int(data.get('exe_mtime', 0)),
                'uptime_secs': int(data.get('uptime_secs', 0)),
                'debug_enabled': bool(data.get('debug_enabled', False))}
    except Exception:
        return None

def cockpit_set_debug(enabled: bool) -> dict:
    """t-ffb9: forward the Admin panel's debug-logging toggle to the daemon's
    POST /admin/debug. Token-free like cockpit_sessions/_cockpit_running_build
    above (the board never holds the daemon's token, t-ddc8) -- the daemon's
    own loopback-only bind is what gates this, not per-request auth."""
    addr, ok = _discover_cockpit_addr()
    if not ok:
        return {'ok': False, 'error': 'daemon unavailable'}
    try:
        req = urllib.request.Request(
            f'http://{addr}/admin/debug', method='POST',
            data=json.dumps({'enabled': enabled}).encode('utf-8'),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=0.6) as r:
            data = json.loads(r.read().decode('utf-8'))
        return {'ok': True, 'enabled': bool(data.get('enabled', enabled))}
    except Exception as e:
        return {'ok': False, 'error': str(e)}

def _cockpit_build_status(addr: str) -> dict:
    """{stale, running_build, latest_build} for a healthy daemon at addr. Stale
    when the running exec-mtime differs from the on-disk binary's, or when the
    running daemon exposes no JSON /version (too old to report the signal)."""
    latest_mtime = _cockpit_binary_mtime()
    latest = {'exe_mtime': latest_mtime}
    running = _cockpit_running_build(addr)
    if running is None:
        return {'stale': True, 'running_build': None, 'latest_build': latest}
    stale = latest_mtime != 0 and running.get('exe_mtime', 0) != latest_mtime
    return {'stale': stale, 'running_build': running, 'latest_build': latest}

def ensure_cockpit() -> dict:
    """Return a running daemon's addr, launching one on demand if none is
    healthy. The spawn argv is fixed; project root + sprint bin go via env."""
    addr, ok = _discover_cockpit_addr()
    if ok:
        return {'running': True, 'addr': addr, 'launched': False, **_cockpit_build_status(addr)}
    if not (COCKPIT_DAEMON_BIN and os.path.exists(COCKPIT_DAEMON_BIN)):
        return {'running': False, 'addr': None, 'error': 'cockpit daemon binary not found'}
    state_dir = _cockpit_state_dir()
    os.makedirs(state_dir, exist_ok=True)
    try:
        os.remove(os.path.join(state_dir, 'daemon.json'))  # clear any stale addr
    except FileNotFoundError:
        pass
    env = dict(os.environ, COCKPIT_STATE_DIR=state_dir, COCKPIT_PROJECT_ROOT=str(PROJECT_ROOT))
    if COCKPIT_SPRINT_BIN:
        env['COCKPIT_SPRINT_BIN'] = COCKPIT_SPRINT_BIN
    try:
        # start_new_session detaches: the daemon outlives the board (agent
        # survives the browser tab, nebula's model).
        subprocess.Popen(
            [COCKPIT_DAEMON_BIN, '-addr', '127.0.0.1:0'], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception as e:
        return {'running': False, 'addr': None, 'error': str(e)}
    for _ in range(50):
        addr, ok = _discover_cockpit_addr()
        if ok:
            return {'running': True, 'addr': addr, 'launched': True, **_cockpit_build_status(addr)}
        time.sleep(0.1)
    return {'running': False, 'addr': None, 'error': 'daemon did not become ready'}

def write_ci_workflow() -> dict:
    """Copy the shipped canon-gate workflow template to the project's
    .github/workflows/canon-gate.yml. Fixed target path (no traversal);
    refuses rather than clobbering an existing workflow."""
    rel = '.github/workflows/canon-gate.yml'
    dest = PROJECT_ROOT / '.github' / 'workflows' / 'canon-gate.yml'
    if dest.exists():
        return {'ok': False, 'reason': 'exists', 'path': rel}
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(CANON_GATE_TEMPLATE.read_text(encoding='utf-8'), encoding='utf-8')
    except Exception as e:
        return {'ok': False, 'reason': str(e), 'path': rel}
    return {'ok': True, 'path': rel}

_BASE_REF_RE = re.compile(r'^[A-Za-z0-9._/-]+$')

def _ticket_gate(ticket_id: str) -> str:
    """Read a ticket's headless gate mode ('eval' or 'full') from frontmatter.
    Absent = 'full' (the default 3-gate pipeline), mirroring the ci convention."""
    p = TICKETS_DIR / ticket_id / 'ticket.md'
    try:
        m = _FRONTMATTER.match(p.read_text(encoding='utf-8', errors='replace'))
        if m:
            for fm in _FIELD.finditer(m.group(1)):
                if fm.group(1) == 'gate':
                    return 'eval' if _unquote_yaml_scalar(fm.group(2).strip()) == 'eval' else 'full'
    except Exception:
        pass
    return 'full'

_HEADLESS_RUNS: dict[str, dict] = {}
_HEADLESS_LOCK = threading.Lock()

def _run_headless(ticket_id: str, base_ref: str) -> None:
    """Runs in a background thread; updates _HEADLESS_RUNS[ticket_id] on completion.
    Picks the eval-only tool (sprint-headless-eval) when the ticket's gate is 'eval',
    else the full sprint-headless pipeline."""
    tool = SPRINT_HEADLESS_EVAL if _ticket_gate(ticket_id) == 'eval' else SPRINT_HEADLESS
    try:
        proc = subprocess.Popen(
            [str(tool), ticket_id, '--base-ref', base_ref],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=PROJECT_ROOT,
        )
        output, _ = proc.communicate()
        exit_code = proc.returncode
    except Exception as e:
        output = f'Error: could not start sprint-headless: {e}'
        exit_code = 1
    with _HEADLESS_LOCK:
        state = _HEADLESS_RUNS.setdefault(ticket_id, {})
        state['status'] = 'done'
        state['output'] = output
        state['exit_code'] = exit_code

def start_headless_run(ticket_id: str, base_ref: str) -> dict:
    """Starts a background run unless one is already in progress for this
    ticket (double-spawn guard) — either way returns the current state.
    Never calls get_headless_run_state() while _HEADLESS_LOCK is held —
    threading.Lock is not reentrant, that would deadlock (live-reproduced)."""
    already_running = False
    with _HEADLESS_LOCK:
        existing = _HEADLESS_RUNS.get(ticket_id)
        if existing and existing.get('status') == 'running':
            already_running = True
        else:
            _HEADLESS_RUNS[ticket_id] = {'status': 'running', 'output': '', 'exit_code': None, 'started_at': time.time()}
    if not already_running:
        threading.Thread(target=_run_headless, args=(ticket_id, base_ref), daemon=True).start()
    return get_headless_run_state(ticket_id)

def get_headless_run_state(ticket_id: str) -> dict:
    with _HEADLESS_LOCK:
        state = _HEADLESS_RUNS.get(ticket_id)
        if not state:
            return {'status': 'idle'}
        result = {'status': state['status'], 'output': state.get('output', ''), 'exit_code': state.get('exit_code')}
        if state['status'] == 'running':
            result['elapsed'] = time.time() - state['started_at']
    return result

# ── Upkeep (t-7ae6): headless, read-only per-project report runner ─────────
# Mirrors the _HEADLESS_RUNS thread+subprocess+dict shape above exactly, keyed
# by (root, skill) instead of ticket id — the only background-job pattern in
# this codebase, reused rather than inventing a second one.
UPKEEP_SKILLS = ('context-check', 'context-doctor', 'dead-code-cleanup', 'promote-learnings')
# Reaches `claude --model`. Ported to tools/upkeep-run and sprint-check-go; tests/fixtures/model-id-cases.json locks all three.
_MODEL_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,63}')

def _resolve_upkeep_run_bin(os_name: str) -> Path:
    """t-1776: upkeep-run is a bash script with no Windows-native entry point.
    subprocess.Popen on Windows calls CreateProcess directly on an explicit
    path -- unlike a bare command name typed at a cmd.exe prompt, it does NOT
    search PATHEXT for a runnable extension, so launching the bare script
    fails outright (no shebang interpretation on Windows either). Prefer the
    Git-for-Windows-locating tools/upkeep-run.cmd wrapper (mirrors
    sprint.cmd's exact pattern) when present; env override always wins first.
    os_name is a parameter (not read inline) so the Windows branch is
    testable on any host -- same shape as _resolve_cockpit_daemon_bin above."""
    override = os.environ.get('UPKEEP_RUN_BIN')
    if override:
        return Path(override)
    tools = Path(__file__).resolve().parent.parent
    bash_script = tools / 'upkeep-run'
    if os_name == 'nt':
        cmd_wrapper = tools / 'upkeep-run.cmd'
        if cmd_wrapper.exists():
            return cmd_wrapper
    return bash_script

UPKEEP_RUN_BIN = _resolve_upkeep_run_bin(os.name)
_UPKEEP_RUNS: dict[tuple, dict] = {}
_UPKEEP_LOCK = threading.Lock()

def _upkeep_state_path(root: Path) -> Path:
    return root / '.reports' / 'upkeepRuns.json'

def _upkeep_state_load(root: Path) -> dict:
    try:
        return json.loads(_upkeep_state_path(root).read_text(encoding='utf-8'))
    except Exception:
        return {}

def _upkeep_state_save(root: Path, skill: str, entry: dict) -> None:
    p = _upkeep_state_path(root)
    p.parent.mkdir(parents=True, exist_ok=True)
    state = _upkeep_state_load(root)
    state[skill] = entry
    try:
        p.write_text(json.dumps(state, indent=2), encoding='utf-8')
    except Exception:
        pass  # best-effort — the in-memory _UPKEEP_RUNS state is authoritative for this process

def _run_upkeep(root: Path, skill: str, model: str) -> None:
    """Runs in a background thread; updates _UPKEEP_RUNS[(root, skill)] and the
    persisted .reports/upkeepRuns.json on completion. Never touches any file
    but the one report upkeep-run itself writes — destructive actions (delete,
    generic Bash) are tool-blocked via that script's own --allowedTools, but
    the single-report-file constraint itself is prompt-enforced only (Claude
    Code's --allowedTools has no path-glob form for Write)."""
    key = (str(root), skill)
    try:
        proc = subprocess.Popen(
            [str(UPKEEP_RUN_BIN), skill, '--root', str(root), '--model', model],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=root,
        )
        output, _ = proc.communicate()
        exit_code = proc.returncode
    except Exception as e:
        output = f'Error: could not start upkeep-run: {e}'
        exit_code = 1
    report_path = ''
    m = re.search(r'^UPKEEP_REPORT: (.+)$', output, re.MULTILINE)
    if m:
        report_path = m.group(1).strip()
    finished_at = time.time()
    with _UPKEEP_LOCK:
        state = _UPKEEP_RUNS.setdefault(key, {})
        state['status'] = 'done' if (exit_code == 0 and report_path) else 'error'
        state['output'] = output
        state['exit_code'] = exit_code
        state['report_path'] = report_path
        state['finished_at'] = finished_at
    # t-1776: bound the persisted tail (not the full capture) so a future
    # failure is self-diagnosing from upkeepRuns.json alone, without
    # inflating it unboundedly across repeated runs — one entry per skill,
    # overwritten each run, same 2KB budget as the in-memory capture's
    # useful tail (a real crash/launch-failure message is short).
    output_tail = output[-2048:] if output else ''
    _upkeep_state_save(root, skill, {
        'status': state['status'], 'report_path': report_path,
        'finished_at': finished_at, 'model': model, 'output': output_tail,
    })

def start_upkeep_run(root: Path, skill: str, model: str) -> dict:
    """Starts a background Upkeep run unless one is already in progress for
    this (root, skill) pair — double-spawn guard, same shape as
    start_headless_run. Never calls get_upkeep_run_state while _UPKEEP_LOCK is
    held (threading.Lock is not reentrant)."""
    if skill not in UPKEEP_SKILLS:
        return {'ok': False, 'error': f'unknown skill {skill!r}'}
    if not _MODEL_RE.fullmatch(model):
        return {'ok': False, 'error': 'model must be a plain model id (letters, digits, . _ : [ ] -)'}
    key = (str(root), skill)
    already_running = False
    with _UPKEEP_LOCK:
        existing = _UPKEEP_RUNS.get(key)
        if existing and existing.get('status') == 'running':
            already_running = True
        else:
            _UPKEEP_RUNS[key] = {'status': 'running', 'output': '', 'exit_code': None, 'started_at': time.time()}
    if already_running:
        return {'ok': False, 'busy': True, **get_upkeep_run_state(root, skill)}
    threading.Thread(target=_run_upkeep, args=(root, skill, model), daemon=True).start()
    return {'ok': True, **get_upkeep_run_state(root, skill)}

def get_upkeep_run_state(root: Path, skill: str) -> dict:
    """In-memory state if this process has ever run `skill` for `root`,
    else falls back to the persisted .reports/upkeepRuns.json entry (survives
    a board restart), else 'idle' (never run)."""
    key = (str(root), skill)
    with _UPKEEP_LOCK:
        state = _UPKEEP_RUNS.get(key)
        if state:
            result = {'status': state['status'], 'exit_code': state.get('exit_code'),
                       'report_path': state.get('report_path', ''), 'finished_at': state.get('finished_at'),
                       # t-1776: surface the same bounded tail the persisted entry gets, so a
                       # failure is diagnosable from the dashboard, not just upkeepRuns.json.
                       'output': state.get('output', '')[-2048:]}
            if state['status'] == 'running':
                result['elapsed'] = time.time() - state['started_at']
            return result
    persisted = _upkeep_state_load(root).get(skill)
    if persisted:
        return {'status': persisted.get('status', 'idle'), 'exit_code': None,
                'report_path': persisted.get('report_path', ''), 'finished_at': persisted.get('finished_at'),
                'model': persisted.get('model'), 'output': persisted.get('output', '')}
    return {'status': 'idle', 'report_path': ''}

def get_upkeep_report(root: Path, skill: str) -> dict:
    """Serves the current report's raw markdown for `skill`, read fresh from
    disk every call (never cached) — the report file itself is the source of
    truth, this just resolves which one is 'current' for the (root, skill)."""
    state = get_upkeep_run_state(root, skill)
    report_path = state.get('report_path', '')
    if not report_path:
        return {'ok': False, 'error': 'no report yet'}
    p = Path(report_path)
    # Containment: the report must live under this root's own .reports/ dir —
    # never trust a path merely because it round-tripped through our own state.
    try:
        p.resolve().relative_to((root / '.reports').resolve())
    except (ValueError, OSError):
        return {'ok': False, 'error': 'report path outside .reports/'}
    try:
        return {'ok': True, 'path': report_path, 'content': p.read_text(encoding='utf-8', errors='replace')}
    except Exception as e:
        return {'ok': False, 'error': str(e)}

# ── Skill Eval (t-23d8): check + plugin eval for a user-picked skill folder ──
# Stage 1/2 (tools/skill-check) are free and synchronous; stage 3 (`claude plugin
# eval`, via tools/plugin-eval-gen --skill-dir) spends money, so it is async, needs
# an explicit confirm_cost, and re-runs every check server-side — the UI's earlier
# check is advisory only. Same thread+dict job shape as Upkeep above.
TOOLS_DIR = Path(__file__).resolve().parent.parent
CANON_ROOT = TOOLS_DIR.parent
SKILL_CHECK_BIN = TOOLS_DIR / 'skill-check'
PLUGIN_EVAL_GEN_BIN = TOOLS_DIR / 'plugin-eval-gen'
SKILL_EVAL_CACHE = CANON_ROOT / '.canon-cache' / 'skill-eval'
SKILL_EVAL_DEFAULT_MODEL = 'claude-haiku-4-5-20251001'
_SKILL_NAME_RE = re.compile(r'[a-z0-9][a-z0-9-]*')
# _MODEL_RE (the model-id rule) lives with the Upkeep constants above; Skill Eval reuses it.
_SKILL_EVAL_RUNS: dict[tuple, dict] = {}
_SKILL_EVAL_LOCK = threading.Lock()

def validate_skill_dir(root: Path, raw: str):
    """(resolved Path, None) or (None, error). The one path gate for check, run,
    status and report: symlinks are resolved first, the folder must sit inside the
    selected project's root (never a raw client path), must not be canon's own
    (checked internally, not here), and its name must be a legal skill name."""
    try:
        p = Path(str(raw)).expanduser().resolve(strict=True)
        proot = root.resolve()
    except (OSError, RuntimeError, ValueError):
        return None, 'skill folder not found'
    if not p.is_dir():
        return None, 'not a folder'
    if proot not in p.parents:
        return None, 'skill folder must be inside the selected project'
    if p == CANON_ROOT or CANON_ROOT in p.parents:
        return None, "canon's own skills are checked internally, not here"
    if not _SKILL_NAME_RE.fullmatch(p.name):
        return None, 'folder name must match [a-z0-9][a-z0-9-]*'
    # A link inside the folder could point at files outside the project (evals.json is read into
    # eval prompts), so any symlink refuses the folder. os.walk does not follow links, but lists them.
    seen = 0
    for dirpath, dirs, files in os.walk(p):
        for n in dirs + files:
            seen += 1
            if os.path.islink(os.path.join(dirpath, n)) or seen > 20000:
                return None, 'skill folder contains a symbolic link (or is too large); remove it and retry'
    return p, None

def skill_eval_check(root: Path, raw: str) -> dict:
    p, err = validate_skill_dir(root, raw)
    if err:
        return {'ok': False, 'error': err}
    try:
        r = subprocess.run([sys.executable or 'python3', str(SKILL_CHECK_BIN), str(p)],
                           capture_output=True, text=True, timeout=30)
        data = json.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        return {'ok': False, 'error': f'skill-check failed: {e}'}
    return {'ok': True, 'skill_dir': str(p), **data}

def _skill_eval_blocker(checks: list, allow_trust: bool) -> str:
    fails = [c['id'] for c in checks if c.get('status') == 'fail']
    if fails:
        return 'fix failing check(s) first: ' + ', '.join(fails)
    trust = [c['id'] for c in checks if str(c.get('id', '')).startswith('trust-') and c.get('status') == 'warn']
    if trust and not allow_trust:
        return 'skill runs code outside the sandbox (' + ', '.join(trust) + '); review it and pass allow_trust to run anyway'
    return ''

def _skill_eval_state_path(root: Path) -> Path:
    return root / '.reports' / 'skillEvalRuns.json'

def _skill_eval_state_load(root: Path) -> dict:
    try:
        d = json.loads(_skill_eval_state_path(root).read_text(encoding='utf-8'))
    except Exception:
        return {}
    return d if isinstance(d, dict) else {}

def _skill_eval_state_save(root: Path, key: str, entry: dict) -> None:
    p = _skill_eval_state_path(root)
    try:
        if p.parent.is_symlink() or (p.parent.exists() and p.parent.resolve().parent != root.resolve()):
            return  # a project-controlled .reports link must not redirect this write outside the project
        p.parent.mkdir(parents=True, exist_ok=True)
        state = _skill_eval_state_load(root)
        state[key] = entry
        p.write_text(json.dumps(state, indent=2), encoding='utf-8')
    except Exception:
        pass  # best-effort — the in-memory state is authoritative for this process

def _skill_eval_key(root: Path, skill_dir: Path) -> tuple:
    return (str(root.resolve()), str(skill_dir))  # resolved: a symlinked spelling of the project must not dodge the busy guard


def _skill_eval_tag(root: Path, skill_dir: Path) -> str:
    return hashlib.sha1(f'{root.resolve()}|{skill_dir}'.encode()).hexdigest()[:12]  # resolved: one dir per project however its path is spelled

def _skill_eval_summary(result_path: Path) -> dict:
    try:
        d = json.loads(result_path.read_text(encoding='utf-8'))
    except Exception:
        return {}
    agg = d.get('aggregates') or {}
    keep = {k: agg[k] for k in ('casesTotal', 'casesPassed', 'overallScore', 'meanDelta') if k in agg}
    for k in ('costUsd', 'partial', 'partialReason'):
        if k in d:
            keep[k] = d[k]

    def mean(arm):
        sc = [r['score'] for r in (arm or []) if isinstance(r, dict) and isinstance(r.get('score'), (int, float))]
        return sum(sc) / len(sc) if sc else None
    keep['cases'] = [{'name': c.get('name') or c.get('id'),
                      'with': mean((c.get('arms') or {}).get('with')),
                      'without': mean((c.get('arms') or {}).get('without'))}
                     for c in (d.get('cases') or []) if isinstance(c, dict) and isinstance(c.get('arms') or {}, dict)]
    return keep

def _run_skill_eval(root: Path, skill_dir: Path, model: str, max_cost: float) -> None:
    key = _skill_eval_key(root, skill_dir)
    tag = _skill_eval_tag(root, skill_dir)
    rel = f'.canon-cache/skill-eval/{tag}'
    plugin = CANON_ROOT / rel
    result_path = plugin / 'last-run.json'
    output, status, report_path = '', 'error', ''
    try:
        gen = subprocess.run([str(PLUGIN_EVAL_GEN_BIN), '--skill-dir', str(skill_dir), '--plugin-dir', rel],
                             capture_output=True, text=True, timeout=60)
        output = (gen.stdout + gen.stderr)
        if gen.returncode == 0:
            result_path.unlink(missing_ok=True)
            shutil.rmtree(plugin / 'evals' / 'results', ignore_errors=True)  # a previous run's report must not be served for this one
            # No --allow-tools / --allow-real-servers: read-only tools, no real MCP servers.
            proc = subprocess.run(
                [os.environ.get('SKILL_EVAL_CLAUDE_BIN', 'claude'), 'plugin', 'eval', str(plugin), '--trust-plugin',
                 '--runs', '2', '--max-cost-usd', str(max_cost), '--model', model, '--no-publish',
                 '--json', str(result_path)],
                capture_output=True, text=True, timeout=1800, cwd=plugin)
            output += proc.stdout + proc.stderr
            reports = sorted((plugin / 'evals' / 'results').glob('*/report.html'))
            report_path = str(reports[-1]) if reports else ''
            status = 'done' if (proc.returncode in (0, 1) and result_path.is_file()) else 'error'
    except Exception as e:
        output += f'\nError: {e}'
    summary = _skill_eval_summary(result_path) if status == 'done' else {}
    finished_at = time.time()
    with _SKILL_EVAL_LOCK:
        st = _SKILL_EVAL_RUNS.setdefault(key, {})
        st.update({'status': status, 'output': output, 'summary': summary,
                   'report_path': report_path, 'finished_at': finished_at})
    _skill_eval_state_save(root, str(skill_dir), {
        'status': status, 'summary': summary, 'report_path': report_path,
        'finished_at': finished_at, 'model': model, 'output': output[-2048:]})

def start_skill_eval_run(root: Path, raw: str, model: str, confirm_cost: bool,
                         allow_trust: bool, max_cost) -> dict:
    """Refuses unless the user confirmed the cost, every stage 1/2 check has no
    fail, and (unless allow_trust) no trust warning. Re-validates server-side."""
    if confirm_cost is not True:
        return {'ok': False, 'error': 'confirm_cost required: this run spends model usage'}
    if model and not _MODEL_RE.fullmatch(model):
        return {'ok': False, 'error': 'model must be a plain model id (letters, digits, . _ : [ ] -)'}
    chk = skill_eval_check(root, raw)
    if not chk.get('ok'):
        return chk
    blocker = _skill_eval_blocker(chk.get('checks', []), allow_trust is True)
    if blocker:
        return {'ok': False, 'error': blocker}
    if not (shutil.which('jq') and shutil.which('bash')):
        return {'ok': False, 'error': 'jq and bash are required to generate the eval plugin'}
    try:
        max_cost = float(max_cost)
    except (TypeError, ValueError, OverflowError):
        max_cost = 3.0
    if not math.isfinite(max_cost):  # NaN passes min/max clamps and would leave the cap unenforced
        max_cost = 3.0
    max_cost = min(max(max_cost, 0.5), 10.0)
    skill_dir = Path(chk['skill_dir'])
    key = _skill_eval_key(root, skill_dir)
    with _SKILL_EVAL_LOCK:
        if (_SKILL_EVAL_RUNS.get(key) or {}).get('status') == 'running':
            return {'ok': False, 'busy': True, 'status': 'running'}
        _SKILL_EVAL_RUNS[key] = {'status': 'running', 'output': '', 'summary': {}, 'report_path': '',
                                 'started_at': time.time()}
    threading.Thread(target=_run_skill_eval, args=(root, skill_dir, model or SKILL_EVAL_DEFAULT_MODEL, max_cost),
                     daemon=True).start()
    return {'ok': True, 'status': 'running', 'max_cost_usd': max_cost}

def get_skill_eval_state(root: Path, raw: str) -> dict:
    p, err = validate_skill_dir(root, raw)
    if err:
        return {'ok': False, 'error': err}
    with _SKILL_EVAL_LOCK:
        live = _SKILL_EVAL_RUNS.get(_skill_eval_key(root, p))
        if live:
            return {'ok': True, **{k: v for k, v in live.items() if k != 'output'}}
    persisted = _skill_eval_state_load(root).get(str(p))
    if isinstance(persisted, dict) and persisted:
        return {'ok': True, **{k: v for k, v in persisted.items() if k != 'output'}}
    return {'ok': True, 'status': 'never'}

def get_skill_eval_report(root: Path, raw: str) -> dict:
    st = get_skill_eval_state(root, raw)
    if not st.get('ok'):
        return st
    report = st.get('report_path', '')
    if not isinstance(report, str) or not report:
        return {'ok': False, 'error': 'no report yet'}
    p, _ = validate_skill_dir(root, raw)
    try:  # only this run's own cache dir: a hand-edited state file must not serve another run's report
        Path(report).resolve().relative_to((SKILL_EVAL_CACHE / _skill_eval_tag(root, p)).resolve())
    except (ValueError, OSError):
        return {'ok': False, 'error': 'report path outside this run\'s cache dir'}
    return {'ok': True, 'summary': st.get('summary', {}), 'report_path': report}

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
        self.send_header('Cache-Control', 'no-store')  # t-07c8: always serve fresh (local dev tool)
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def send_image(self, path: Path):
        mime = IMAGE_MIME.get(path.suffix.lower(), 'application/octet-stream')
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
        elif path == '/cockpit':
            # Canon Cockpit shell landing (t-9917). Falls back to the board if
            # the landing file is absent, so an older checkout still serves.
            self.send_html(COCKPIT_HTML if COCKPIT_HTML.exists() else APP_HTML)
        elif path == '/api/projects':
            self.send_json(registry_list())
        elif re.match(r'^/meta/screenshots/[a-zA-Z0-9_-]+\.(png|gif|jpg|jpeg|webp)$', path):
            img = PROJECT_ROOT / path.lstrip('/')
            self.send_image(img); return
        elif path == '/api/tickets':
            try:
                eroot = effective_root(parse_qs(parsed.query))
            except UnknownProject:
                self.send_error(400); return
            tickets = load_tickets(eroot)
            if 'all=1' not in parsed.query:
                tickets = [t for t in tickets if t.get('status') != 'archived']
            self.send_json(tickets)
        elif path == '/api/handoff':
            try:
                self.send_json(load_handoff(effective_root(parse_qs(parsed.query))))
            except UnknownProject:
                self.send_error(400)
        elif path == '/api/git':
            try:
                self.send_json(load_git(effective_root(parse_qs(parsed.query))))
            except UnknownProject:
                self.send_error(400)
        elif path == '/api/why':
            q = parse_qs(parsed.query)
            file_ = q.get('file', [''])[0]
            try:
                self.send_json(load_why(file_, effective_root(q)))
            except UnknownProject:
                self.send_error(400)
        elif path == '/api/project-stats':
            try:
                eroot = effective_root(parse_qs(parsed.query))
            except UnknownProject:
                self.send_error(400); return
            self.send_json(project_stats(eroot))
        elif path == '/api/browse-dirs':
            # t-1b88/t-340d: read-only dir listing for the Add-Project Browse picker.
            _q = parse_qs(parsed.query)
            _hidden = (_q.get('hidden', [''])[0] or '').lower() in ('1', 'true')
            self.send_json(browse_dirs(_q.get('path', [''])[0], _hidden))
        elif path == '/api/cockpit':
            self.send_json(cockpit_discover())
        elif path == '/api/cockpit-sessions':
            self.send_json(cockpit_sessions())
        elif path == '/api/version':
            self.send_json(board_version())
        elif path == '/api/worktrees':
            wt_ticket = parse_qs(parsed.query).get('ticket', [''])[0]
            # re.fullmatch (not re.match with $) so a trailing newline is
            # rejected — Python's `$` matches before a final \n but Go RE2's
            # does not, so `?ticket=t-abcd\n` would otherwise diverge (server.py
            # would compute ticket_present, main.go would omit it). t-2a1c.
            if not re.fullmatch(r't-[a-z0-9]{4}', wt_ticket):
                wt_ticket = ''
            try:
                eroot = effective_root(parse_qs(parsed.query))
            except UnknownProject:
                self.send_error(400); return
            self.send_json(list_worktrees(wt_ticket, root=eroot))
        else:
            m = re.match(r'^/api/commit/([0-9a-f]{4,40})$', path)
            if m:
                try:
                    eroot = effective_root(parse_qs(parsed.query))
                except UnknownProject:
                    self.send_error(400); return
                self.send_json(load_commit(m.group(1), eroot)); return
            m = re.match(r'^/api/doc/(.+)$', path)
            if m:
                try:
                    eroot = effective_root(parse_qs(parsed.query))
                except UnknownProject:
                    self.send_error(400); return
                content = read_doc(unquote(m.group(1)), eroot)
                if content is None:
                    self.send_error(404); return
                self.send_json({'content': content})
                return
            m = re.match(r'^/api/ticket-image/(t-[a-z0-9]{4})/(.+)$', path)
            if m:
                ticket_id, relpath = m.group(1), unquote(m.group(2))
                img = _safe_ticket_doc(f'{ticket_id}/{relpath}', exts=IMAGE_EXTS)
                if img is None or not img.is_file():
                    self.send_error(404); return
                self.send_image(img); return
            m = re.match(r'^/api/ticket-feature/(t-[a-z0-9]{4})/(.+)$', path)
            if m:
                ticket_id, relpath = m.group(1), unquote(m.group(2))
                feat = _safe_ticket_doc(f'{ticket_id}/{relpath}', exts=('.feature',))
                if feat is None or not feat.is_file():
                    self.send_error(404); return
                self.send_json({'content': feat.read_text(encoding='utf-8', errors='replace')})
                return
            m = re.match(r'^/api/ticket/(t-[a-z0-9]{4})/headless-run$', path)
            if m:
                self.send_json(get_headless_run_state(m.group(1))); return
            if path == '/api/upkeep/status':
                q = parse_qs(parsed.query)
                skill = q.get('skill', [''])[0]
                if skill not in UPKEEP_SKILLS:
                    self.send_error(400); return
                try:
                    eroot = effective_root(q)
                except UnknownProject:
                    self.send_error(400); return
                self.send_json(get_upkeep_run_state(eroot, skill)); return
            if path == '/api/upkeep/report':
                q = parse_qs(parsed.query)
                skill = q.get('skill', [''])[0]
                if skill not in UPKEEP_SKILLS:
                    self.send_error(400); return
                try:
                    eroot = effective_root(q)
                except UnknownProject:
                    self.send_error(400); return
                self.send_json(get_upkeep_report(eroot, skill)); return
            if path == '/api/skill-eval/report.html':
                q = parse_qs(parsed.query)
                try:
                    eroot = effective_root(q)
                except UnknownProject:
                    self.send_error(400); return
                rep = get_skill_eval_report(eroot, q.get('skill_dir', [''])[0])
                try:
                    body = Path(rep['report_path']).read_bytes() if rep.get('ok') else None
                except OSError:
                    body = None
                if body is None:
                    self.send_error(404); return
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', len(body))
                # The report is generated from a user-picked skill's content: render it in an
                # opaque origin (sandbox without allow-same-origin) so it cannot reach this API.
                self.send_header('Content-Security-Policy', "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:")
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body); return
            if path == '/api/skill-eval/status':
                q = parse_qs(parsed.query)
                try:
                    eroot = effective_root(q)
                except UnknownProject:
                    self.send_error(400); return
                self.send_json(get_skill_eval_state(eroot, q.get('skill_dir', [''])[0])); return
            if path == '/api/skill-eval/report':
                q = parse_qs(parsed.query)
                try:
                    eroot = effective_root(q)
                except UnknownProject:
                    self.send_error(400); return
                self.send_json(get_skill_eval_report(eroot, q.get('skill_dir', [''])[0])); return
            m = re.match(r'^/api/worktree-lock/(t-[a-z0-9]{4})$', path)
            if m:
                try:
                    eroot = effective_root(parse_qs(parsed.query))
                except UnknownProject:
                    self.send_error(400); return
                self.send_json(worktree_lock_status(m.group(1), root=eroot)); return
            m = re.match(r'^/api/cockpit-docs/(t-[a-z0-9]{4})$', path)
            if m:
                cwd = parse_qs(parsed.query).get('cwd', [''])[0]
                if not cwd:
                    self.send_error(400); return
                docs = cockpit_docs(m.group(1), cwd)
                if docs is None:
                    self.send_error(400); return
                self.send_json(docs); return
            self.send_error(404)

    def do_POST(self):
        if not self._host_ok():
            self.send_error(403); return
        parsed = urlparse(self.path)
        path = parsed.path
        origin = self.headers.get('Origin', '')
        if origin and not origin.startswith('http://127.0.0.1') and not origin.startswith('http://localhost'):
            self.send_error(403); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            payload = json.loads(self.rfile.read(length))
        except Exception:
            self.send_error(400); return
        if not isinstance(payload, dict):
            self.send_error(400); return  # every POST route reads its fields with payload.get

        # t-8485: project-scoped writes — resolve ?project once (400 on unknown id;
        # absent → process default). Passed to the editable-tab write fns below.
        try:
            eroot = effective_root(parse_qs(parsed.query))
        except UnknownProject:
            self.send_error(400); return

        if path == '/api/projects':
            result = registry_add(str(payload.get('path', '')), str(payload.get('description', '')))
            self.send_json(result, status=200 if result.get('ok') else 400); return

        # t-7485/t-96c3: register a canon skill into the tab's project. The target
        # dir is the registry-resolved eroot (never a raw client path; unknown id
        # already 400'd above). The skill comes from the client but is validated in
        # register_skill against the fixed REGISTERABLE_SKILLS allowlist.
        if path == '/api/register-skill':
            skill = (parse_qs(parsed.query).get('skill', [''])[0] or str(payload.get('skill', '')) or 'sprint')
            self.send_json(register_skill(eroot, skill)); return

        m = re.match(r'^/api/ticket/([^/]+)/status$', path)
        if m:
            ok = write_status(m.group(1), str(payload.get('status', '')), eroot)
            self.send_json({'ok': ok}); return

        m = re.match(r'^/api/ticket/([^/]+)/body$', path)
        if m:
            ok = write_body(m.group(1), str(payload.get('body', '')), eroot)
            self.send_json({'ok': ok}); return

        m = re.match(r'^/api/ticket/(t-[a-z0-9]{4})/visual$', path)
        if m:
            self.send_json(write_visual(m.group(1), str(payload.get('filename', '')), str(payload.get('data', '')), eroot)); return

        m = re.match(r'^/api/ticket/(t-[a-z0-9]{4})/demo$', path)
        if m:
            ok = write_demo(m.group(1), bool(payload.get('demo', False)), eroot)
            self.send_json({'ok': ok}); return

        m = re.match(r'^/api/doc/(.+)$', path)
        if m:
            ok = write_doc(unquote(m.group(1)), str(payload.get('content', '')), eroot)
            self.send_json({'ok': ok}); return

        m = re.match(r'^/api/ticket/(t-[a-z0-9]{4})/headless-run$', path)
        if m:
            base_ref = str(payload.get('base_ref', ''))
            if not _BASE_REF_RE.match(base_ref):
                self.send_error(400); return
            self.send_json(start_headless_run(m.group(1), base_ref)); return

        if path == '/api/upkeep/run':
            skill = str(payload.get('skill', ''))
            if skill not in UPKEEP_SKILLS:
                self.send_error(400); return
            model = str(payload.get('model', '')) or 'claude-haiku-4-5-20251001'
            self.send_json(start_upkeep_run(eroot, skill, model)); return

        if path == '/api/skill-eval/check':
            self.send_json(skill_eval_check(eroot, str(payload.get('skill_dir', '')))); return

        if path == '/api/skill-eval/run':
            self.send_json(start_skill_eval_run(
                eroot, str(payload.get('skill_dir', '')), str(payload.get('model', '')),
                payload.get('confirm_cost'), payload.get('allow_trust'), payload.get('max_cost_usd', 3.0))); return

        if path == '/api/ci-workflow':
            self.send_json(write_ci_workflow()); return

        if path == '/api/cockpit':
            self.send_json(ensure_cockpit()); return
        if path == '/api/cockpit-restart':
            self.send_json(cockpit_restart(bool(payload.get('force', False)))); return
        if path == '/api/cockpit-stop':
            self.send_json(cockpit_stop(bool(payload.get('force', False)))); return
        if path == '/api/cockpit-debug':
            self.send_json(cockpit_set_debug(bool(payload.get('enabled', False)))); return

        if path == '/api/worktrees':
            branch = str(payload.get('branch', ''))
            if not _valid_branch_name(branch):
                self.send_error(400); return
            self.send_json(create_worktree(branch, root=eroot)); return

        m = re.match(r'^/api/worktree-unlock/([^/]+)$', path)
        if m:
            tid = m.group(1)
            if not re.match(r'^t-[a-z0-9]{4}$', tid):
                self.send_error(400); return
            self.send_json(worktree_unlock(tid, root=eroot)); return

        if path == '/api/tickets':
            t = create_ticket(
                title    = str(payload.get('title', 'Untitled')),
                type_    = str(payload.get('type', 'task')),
                status   = str(payload.get('status', 'open')),
                priority = int(payload.get('priority', 2)),
                body     = str(payload.get('body', '')),
                ci       = bool(payload.get('ci', False)),
                eval_override = bool(payload.get('eval_override', False)),
                gate     = 'eval' if str(payload.get('gate', '')).lower() == 'eval' else 'full',
                demo     = bool(payload.get('demo', False)),
                skills   = str(payload.get('skills', '')),
                worktree_preference = str(payload.get('worktree_preference', '')),
                root     = eroot,
            )
            self.send_json(t); return

        self.send_error(404)

    def do_DELETE(self):
        if not self._host_ok():
            self.send_error(403); return
        path = urlparse(self.path).path
        origin = self.headers.get('Origin', '')
        if origin and not origin.startswith('http://127.0.0.1') and not origin.startswith('http://localhost'):
            self.send_error(403); return
        m = re.match(r'^/api/projects/([0-9a-f]{12})$', path)
        if m:
            self.send_json(registry_remove(m.group(1))); return
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

    # t-6693: no http:// scheme (some terminals auto-linkify it into a false,
    # competing link next to the launcher's real .../cockpit one), and labeled
    # "Canon Cockpit" not "sprint-check" — post-t-4700 every supported launcher
    # funnels into the one shared instance; there's no standalone board mode left.
    print(f'Canon Cockpit  listening on localhost:{port}  (project: {PROJECT_ROOT.name})', file=sys.stderr)
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
