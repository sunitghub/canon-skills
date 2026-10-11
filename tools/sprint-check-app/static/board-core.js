import { displayTicketId } from './board-helpers.js';
import { render } from './board-render.js';

// ── Config ───────────────────────────────────────────────────────────────

export const COLUMNS = [
  { status: 'open',        label: 'Open',        cls: 'col-open',      dotVar: '--col-open'       },
  { status: 'in_progress', label: 'In Progress',  cls: 'col-progress',  dotVar: '--col-progress'   },
  { status: 'closed',      label: 'Done',         cls: 'col-done',      dotVar: '--col-done'       },
  { status: 'cancelled',   label: 'Discarded',    cls: 'col-discarded', dotVar: '--col-discarded'  },
];
const STATUS_ORDER = COLUMNS.map(c => c.status);

// ── Mock data (fallback when server not running) ──────────────────────────

const MOCK = {
  tickets: [
    { id:'t-ialk', status:'in_progress', type:'feature', priority:1,
      title:'Build sprint-check GUI — kanban app.html + Python server',
      created: ago(1), body:'## Goal\nSelf-contained HTML kanban board served by Python stdlib HTTP server.\n\n## Columns\n- Open\n- In Progress\n- Done\n- Discarded\n\n## Sidebar\nHANDOFF Current Focus + recent git log + ticket summary.' },
    { id:'t-sc02', status:'open', type:'task', priority:2,
      title:'Wire server.py to read real .tickets/ files',
      created: ago(0.5), body:'Connect GET /api/tickets to actual ticket files.\nParse YAML frontmatter and return JSON.' },
    { id:'t-sc03', status:'open', type:'task', priority:2,
      title:'Add POST endpoint for status changes',
      created: ago(0.3), body:'POST /api/ticket/:id/status updates the YAML status field in place without corrupting the markdown body.' },
    { id:'t-sc04', status:'open', type:'chore', priority:3,
      title:'Register sprint-check in skills.sh + CATALOG',
      created: ago(0.1), body:'Add skill doc (sprint-check.md), register with skills.sh, update CATALOG.md.' },
    { id:'t-sc05', status:'closed', type:'task', priority:2,
      title:'Design folder structure under tools/',
      created: ago(2), body:'Decision: tools/sprint-check/ for server.py + app.html. Launcher at tools/sprint-check.sh.' },
    { id:'t-sc06', status:'closed', type:'task', priority:1,
      title:'Research cross-platform GUI framework',
      created: ago(3), body:'Evaluated Electrobun, Zero Native (Vercel Labs), Neutralinojs, Python tkinter.\n\nDecision: Python http.server + browser — zero install, works on macOS / Linux / WSL.' },
    { id:'t-sc07', status:'cancelled', type:'feature', priority:3,
      title:'Native window via Electrobun',
      created: ago(4), body:'Dropped — macOS only, requires Bun runtime. Python + browser covers all targets.' },
  ],
  handoff: {
    focus: 'Building sprint-check — local kanban dashboard for canon projects. Sprinting the GUI (app.html) now.',
  },
  git: {
    project: 'canon',
    branch:  'main',
    modified: 3,
    log: [
      { hash:'f9078a1', message:'feat: add changes summary table to wrapup' },
      { hash:'8344b7b', message:'feat: silent-pass for all-LOW impact' },
      { hash:'fbddcff', message:'chore: expand sprint skills list summary' },
      { hash:'a1f41d7', message:'feat: add impact-analysis sub-skill' },
      { hash:'1a33da2', message:'docs: update setup guide' },
    ],
  },
};

function ago(days) {
  return new Date(Date.now() - days * 86400000).toISOString();
}

// ── State ────────────────────────────────────────────────────────────────

export const COLLAPSE_STATUSES = new Set(['closed', 'cancelled']);
export const COL_LIMIT = 5;
export const DEBUG = new URLSearchParams(location.search).has('debug');
// t-67ab: the token the Canon Cockpit gave this tab's iframe; echoed on every message to the
// shell so it knows which tab sent it (Safari reports the shell itself as event.source).
export const SHELL_TAB = new URLSearchParams(location.search).get('tab') || '';
function debugLog(...args) {
  if (DEBUG) console.log('[sprint-check]', ...args);
}

// ── Ticket creation ───────────────────────────────────────────────────────

export const TICKET_TYPES = ['feature', 'task', 'bug', 'chore', 'epic'];

export const TYPE_TEMPLATES = {
  feature: `## Description\nWhat should be built?\n`,
  task:    `## Description\nWhat should be done?\n`,
  bug:     `## Description\nWhat is broken?\n\n## Expected\n\n## Actual\n`,
  chore:   `## Description\nWhat maintenance work is needed?\n`,
  epic:    `## Description\nWhat larger outcome should this track?\n`,
};

export function detectTicketType(title) {
  const t = title.toLowerCase();
  if (/\b(fix|bug|error|crash|broken|regression|failing|cannot|can'?t)\b/.test(t))
    return { type: 'bug',     reason: 'looks like a bug fix' };
  if (/\b(epic|initiative|milestone|programme|program)\b/.test(t))
    return { type: 'epic',    reason: 'looks like an epic' };
  if (/\b(chore|cleanup|clean up|remove|delete|deprecat|upgrade|bump|renovate)\b/.test(t))
    return { type: 'chore',   reason: 'looks like maintenance' };
  if (/\b(add|build|implement|create|introduce|new|design|support)\b/.test(t))
    return { type: 'feature', reason: 'looks like a new feature' };
  return   { type: 'task',    reason: 'general task' };
}

export const DOC_TYPES = [
  {
    name: 'Acceptance',  slug: 'acceptance',
    hint: 'Criteria and Test Plan sections both need checklist items — sprint complete blocks without them.',
    suggestedFor: ['open', 'in_progress'],
    template:
`# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: \`<id>\`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [ ]

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ]

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally
`,
  },
  {
    name: 'Plan',        slug: 'plan',
    hint: 'Capture the approach and record decisions before source edits begin.',
    suggestedFor: ['open', 'in_progress'],
    template:
`# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: \`<id>\`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->

- [ ] Plan approved — proceed to implementation

## Approach
How will we implement it?
<!-- Add or edit approach notes below. Keep this heading unchanged. -->

## Files
<!-- List files to create or modify. -->

## Decisions
<!-- Record choices made during the sprint. Keep this heading unchanged. -->

### [Decision title]
- **Choice**:
- **Why**:
- **Alternatives considered**:
`,
  },
  {
    name: 'Research',    slug: 'research',
    hint: 'Objective compression of truth — what the system does, which files matter, constraints, and unknowns. No implementation planning here.',
    suggestedFor: ['open', 'in_progress'],
    template:
`# Research

<!-- Keep the Ticket line below unchanged. -->
Ticket: \`<id>\`

## Objective
One sentence: what system behavior was researched.

## Relevant Files
| File | Why relevant | Evidence |
|---|---|---|
| \`path/file.ext:42\` | Entry point for X | Function Y calls Z |

## System Model
- Fact about how the subsystem works.
- Fact about data flow or control flow.

## Constraints
- Non-obvious constraint and its source.

## Unknowns
- Question that must be resolved before planning, or "None".

## Not In Scope
- Relevant-looking files intentionally excluded and why.
`,
  },
];

export function docSlug(t, file) {
  if (file.includes('/')) return file.split('/').pop().replace('.md', '');
  return file.replace(`${displayTicketId(t)}-`, '').replace('.md', '');
}

export function docFileFor(t, slug) {
  const id = displayTicketId(t);
  return t.layout === 'folder' ? `${id}/${slug}.md` : `${id}-${slug}.md`;
}

// t-26f9: the docs the server will write in a worktree (acceptance.md, plan.md, research.md)
export const LIVE_EDITABLE_SLUGS = ['acceptance', 'plan', 'research'];
export function availableDocTypes(t) {
  const existingSlugs = (t.docs || []).map(d => docSlug(t, d.file));
  // t-26f9: in a worktree the board writes only acceptance.md, plan.md and research.md
  const writable = dt => !t.docs_from || LIVE_EDITABLE_SLUGS.includes(dt.slug);
  return DOC_TYPES.filter(dt => !existingSlugs.includes(dt.slug) && writable(dt));
}

export const state = {
  tickets:[], handoff:null, git:null, selectedId:null, expandedCols: new Set(),
  boardFirstRender: true, query: '', queryMode: 'search', why: null,
  cockpitRows: new Map(), cockpitRowsKey: '',   // t-28ec: this project's live sessions by ticket id
  scratch: new Map(),                           // t-47f1: open scratch sessions (s-xxxx) — no ticket behind them
};

// ── Data layer ───────────────────────────────────────────────────────────

export async function loadData() {
  setDot('loading');
  try {
    const [tr, hr, gr] = await Promise.all([
      fetch('/api/tickets?all=1'),
      fetch('/api/handoff'),
      fetch('/api/git'),
    ]);
    if (!tr.ok) throw new Error();
    state.tickets = await tr.json();
    state.handoff = await hr.json();
    state.git     = await gr.json();
    setDot('live');
  } catch {
    state.tickets = MOCK.tickets;
    state.handoff = MOCK.handoff;
    state.git     = MOCK.git;
    setDot('mock');
  }
  render();
}

function setDot(s) {
  const el = document.getElementById('refresh-dot');
  el.className = 'refresh-dot' + (s !== 'live' ? ' ' + s : '');
}

// t-99fa/t-5c20: header shows the human semantic version (canon vX.Y.Z); the
// per-component build details (board commit, cockpit-daemon build) live in the
// "?" tour panel's Versions section, not a cramped tooltip.
export async function fetchVersion() {
  try {
    const r = await fetch('/api/version');
    if (!r.ok) return;
    const d = await r.json();
    const semver = (d && d.version) ? d.version : 'dev';
    const el = document.getElementById('h-version');
    if (el) { el.textContent = 'canon v' + semver; el.removeAttribute('title'); }
    const canonEl = document.getElementById('tv-canon');
    if (canonEl) canonEl.textContent = 'v' + semver + (d && d.commit && d.commit !== 'dev' ? ' (' + d.commit + ')' : '');
    const boardEl = document.getElementById('tv-board');
    if (boardEl) boardEl.textContent = (d && d.commit) ? d.commit : '—';
    const dmnEl = document.getElementById('tv-daemon');
    if (dmnEl) dmnEl.textContent = (d && d.daemon) ? d.daemon : 'not built';
  } catch {}
}

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initCore() {
  // ── Canon Cockpit project scoping (t-a55a) ────────────────────────────────
  // When the board is embedded in a Cockpit tab it is loaded as /?project=<id>.
  // Thread that id onto the board's READ /api/ calls so every panel shows the
  // tab's project. One fetch wrapper covers all ~44 call sites (pre-mortem #1:
  // missing one would leak another project's data). Only READ endpoints are
  // scoped — writes stay on the server's default project this phase (read-only
  // tab), matching the backend (Phase 2b scopes writes). Absent param → no-op,
  // so the standalone single-project board is byte-unchanged.
  (function(){
    const _project = new URLSearchParams(location.search).get('project') || '';
    if (!_project) return; // standalone board — leave fetch untouched
    // t-6a74 (Phase 3): mark the embedded project-tab context so shell-provided
    // chrome (version/daemon/theme/help) can be hidden and the breadcrumb swapped
    // to the folder path. Distinct from the t-ddc8 `body.embed` agent-terminal mode.
    document.documentElement.classList.add('canon-proj-embed');
    // Read endpoints that resolve via effective_root on the server. t-1780:
    // worktrees/worktree-lock now scope too — a shared multi-project instance
    // otherwise showed the shell's launch-time project's worktrees under any tab.
    // (`ticket-image` is deliberately absent: it's only ever an <img> src the browser loads directly, so
    // resolveMockupSrc scopes it itself — t-7d83.)
    const READ_RE = /^\/api\/(tickets|handoff|git|why|doc\/|commit\/|project-stats|worktrees|worktree-lock\/|ticket-feature\/|ticket-commit\/|cockpit-changes$)/;
    // t-8485: editable-tab WRITE endpoints that also take ?project (POST). Scope
    // these so drag-status / create / edit-body / edit-doc / demo / visual / worktree
    // create/unlock done inside a project tab target THAT project. Deliberately
    // EXCLUDES the OUT set (cockpit / cockpit-restart / version / ci-workflow /
    // headless-run) and /api/projects (registry add) — those stay unscoped.
    // t-d254: ticket-commit/ (GET plan + POST commit) — unscoped, a tab would classify
    // and COMMIT in the board's default project instead of the tab's (live-caught, VM).
    const WRITE_RE = /^\/api\/(tickets$|ticket\/[^/]+\/(status|body|demo|visual)|doc\/|worktrees$|worktree-unlock\/|ticket-commit\/)/;
    const _fetch = window.fetch.bind(window);
    window.fetch = function(input, init){
      try {
        const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        let url = typeof input === 'string' ? input : (input && input.url);
        if (typeof url === 'string') {
          // Match on the pathname (WRITE_RE anchors like `tickets$`, so compare path only).
          const path = url.split('?')[0];
          const isRead  = method === 'GET' && READ_RE.test(path);
          const isWrite = (method === 'POST' || method === 'PUT') && WRITE_RE.test(path);
          if (isRead || isWrite) {
            const u = new URL(url, location.origin);
            if (!u.searchParams.has('project')) {
              u.searchParams.set('project', _project);
              url = u.pathname + u.search;
              if (typeof input === 'string') input = url;
              else input = new Request(url, input);
            }
          }
        }
      } catch (e) { /* fall through to unmodified fetch */ }
      return _fetch(input, init);
    };
    // expose for the shell/debug
    window.__canonProject = _project;
  })();
}
