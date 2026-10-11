import { docSlug, state } from './board-core.js';
import { readiness } from './board-render.js';

// ── Helpers ───────────────────────────────────────────────────────────────

export function esc(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
// esc() leaves `"` alone, so text going inside an attribute needs this one (t-6328 lesson).
export function escAttr(s) {
  return esc(s).replace(/"/g, '&quot;');
}

export function displayTicketId(t) {
  return String(t?.id ?? '').replace(/^(['"])(.*)\1$/, '$2');
}

export function normalizeTicketLineId(value) {
  return String(value ?? '')
    .trim()
    .replace(/^`(.*)`$/, '$1')
    .replace(/^(['"])(.*)\1$/, '$2');
}

export function titleCase(s) {
  return String(s ?? '').replace(/\b\w/g, c => c.toUpperCase());
}

export function normalizeSearch(s) {
  return String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function searchableText(t) {
  const r = readiness(t);
  return normalizeSearch([
    t.id,
    t.title,
    t.status,
    t.type,
    `p${t.priority ?? 2}`,
    t.body,
    r.label,
    r.ready ? 'ready' : '',
    r.acceptanceIncomplete ? 'acceptance incomplete incomplete' : '',
    r.acceptanceUnchecked ? 'unchecked items incomplete' : '',
    r.planIncomplete ? 'plan incomplete incomplete' : '',
    ...(t.docs || []).flatMap(d => [d.name, docSlug(t, d.file)]),
    ...(t.models_used || []),
  ].join(' '));
}

function primarySearchText(t) {
  const r = readiness(t);
  return normalizeSearch([
    t.id,
    t.title,
    t.status,
    t.type,
    `p${t.priority ?? 2}`,
    t.body,
    r.label,
    r.ready ? 'ready' : '',
    r.acceptanceIncomplete ? 'acceptance incomplete incomplete' : '',
    r.acceptanceUnchecked ? 'unchecked items incomplete' : '',
    r.planIncomplete ? 'plan incomplete incomplete' : '',
  ].join(' '));
}

export function ticketMatchesQuery(t) {
  const q = normalizeSearch(state.query);
  if (state.queryMode !== 'search') return true;
  if (!q) return true;
  // Direct field queries — bypass prose search entirely (zero false positives)
  if (q === 'is ci') return !!t.ci;
  if (q === 'is override') return !!t.eval_override;
  const primary = primarySearchText(t);
  const readinessQueries = new Set(['ready', 'incomplete', 'acceptance incomplete', 'plan incomplete', 'needs plan', 'needs acc', 'unchecked items']);
  if (readinessQueries.has(q)) return primary.includes(q);
  if (primary.includes(q)) return true;
  const terms = q.split(/\s+/);
  if (terms.length > 1) return terms.every(term => primary.includes(term));
  return searchableText(t).includes(q);
}

export function whyQueryFromInput(value) {
  const raw = String(value ?? '').trim();
  const prefixed = raw.match(/^why(?::|\s+)(.+)$/i);
  return (prefixed ? prefixed[1] : raw).trim();
}

export function age(iso) {
  if (!iso) return '';
  // t-19d1: a legacy date-only `created` has no time of day — report whole days, never a made-up
  // hour count ("10h ago" for a ticket created minutes ago).
  if (!iso.includes('T')) {
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const days = Math.round((today - new Date(iso + 'T00:00:00')) / 86400000);
    if (days <= 0) return 'today';
    if (days < 30) return `${days}d ago`;
    return `${Math.floor(days / 30)}mo ago`;
  }
  const date = new Date(iso);
  const m = Math.floor((Date.now() - date) / 60000);
  if (m < 2)   return 'just now';
  if (m < 60)  return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24)  return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 30)  return `${d}d ago`;
  return `${Math.floor(d/30)}mo ago`;
}

export function typeBadge(type) {
  const t = type || 'task';
  return `<span class="type-badge type-${esc(t)}">${esc(t)}</span>`;
}

export function outcomeRatio(type, tickets) {
  const withOutcome = tickets.find(x => x.type === type && x.type_outcome);
  const o = withOutcome && withOutcome.type_outcome;
  if (!o || !o.closed) return '';
  const good = o.clean / o.closed > 0.5;
  const detail = `${o.clean} of ${o.closed} past ${esc(type || 'task')} tickets closed without eval rework`;
  return `<span class="outcome-dot ${good ? 'outcome-good' : 'outcome-mixed'}" tabindex="0" role="img" aria-label="${detail}" data-tooltip="${detail}"></span>`;
}

export function ciBadge(t) {
  if (String(t.ci) !== 'true') return '';
  return `<span class="ci-badge" title="CI-eligible — headless grading (tools/sprint-headless) can run against this ticket. Set with: tkt ci ${esc(t.id)} off">CI</span>`;
}

export function demoBadge(t) {
  if (String(t.demo) !== 'true') return '';
  return `<span class="demo-badge" title="Demo/Docs/UX light-close — for live demos or docs/research/UX-mockup work: sprint complete runs the reduced close-path (security-review + the binding evaluator only, forced Haiku), skipping the advisory reviewer + rest of wrapup. Never drops below the evaluator. Set with: tkt demo ${esc(t.id)} off">DEMO/UX</span>`;
}

// t-6328: `branch_divergence` ({branch,status,where,merged}) is sent only when this ticket's
// status differs on a live worktree / unmerged branch. Returns null when absent.
export function divergenceInfo(t) {
  const d = t && t.branch_divergence;
  if (!d || !d.branch || !d.status) return null;
  // t-8be2: a bound ticket shows its worktree's own status, so a divergence that says the same thing warns of nothing
  // (the field still carries dirty/merged for whoever needs them).
  if (t.docs_from && d.status === t.status) return null;
  const where = d.where === 'worktree' ? `in worktree ${d.branch}` : `on ${d.branch}`;
  // t-2241: uncommitted work in the worktree is never "merged", whatever merge-base
  // says about its commits (the VM case: a sprint's unsaved plan edits read as merged).
  const merge = d.where === 'worktree' && d.dirty ? ', uncommitted changes in worktree'
    : d.where === 'worktree' && d.merged ? ' (branch merged)' : ', not merged';
  return {
    short: `${d.status} ${where}`,
    // t-e78b: a live ticket's docs above are the worktree's, so only the STATUS is this checkout's.
    long: `${t.docs_from ? 'Status from this checkout' : "Showing this checkout's copy"} (${t.status}) — ${d.status} ${where}${merge}.`,
  };
}

// t-19d1: where a ticket really is. An `open` ticket that's `in_progress` in a live worktree (the
// sprint started there; .tickets/ is tracked, so only the worktree's copy changed) counts as in
// progress for lanes, counts and Start/Resume. Display only — main's ticket.md is never written.
export function worktreeRun(t) {
  const d = t && t.branch_divergence;
  return (t && t.status === 'open' && d && d.where === 'worktree' && d.status === 'in_progress' && d.branch) ? d : null;
}
export function effectiveStatus(t) {
  return worktreeRun(t) ? 'in_progress' : (t ? t.status : '');
}

export function divergenceLine(t) {
  const info = divergenceInfo(t);
  return info ? `<div class="card-diverge" title="${escAttr(info.long)}">${esc(info.short)}</div>` : '';
}

// t-19d1: New Ticket's "Main checkout" choice is saved as this sentinel, not a branch name (the main
// checkout's branch varies: main, master, …), so the rail can preselect Main and the card can say so.
export const WT_PREF_MAIN = 'main-checkout';

// t-15ee: the branch chosen in New Ticket (`worktree_preference`), while the ticket is still open —
// nothing is created until the sprint starts, so without this the choice looks dropped.
export function openWorktreePreference(t) {
  return t && t.status === 'open' && t.worktree_preference ? String(t.worktree_preference) : '';
}

export function worktreePrefLine(t) {
  const pref = openWorktreePreference(t);
  if (!pref) return '';
  if (pref === WT_PREF_MAIN) return `<div class="card-wt-pref" title="Chosen at New Ticket — the sprint runs in the main checkout.">Worktree: Main checkout</div>`;
  return `<div class="card-wt-pref" title="${escAttr(`Chosen at New Ticket — the worktree "${pref}" is created when you start the sprint.`)}">Worktree: ${esc(pref)}</div>`;
}

function sortChecklistRuns(text) {
  const lines = text.split('\n');
  const out = [];
  for (let i = 0; i < lines.length;) {
    if (!/^- \[[ xX]\] /.test(lines[i])) {
      out.push(lines[i]);
      i++;
      continue;
    }
    const run = [];
    while (i < lines.length && /^- \[[ xX]\] /.test(lines[i])) {
      run.push(lines[i]);
      i++;
    }
    out.push(...run.filter(line => /^- \[ \] /.test(line)));
    out.push(...run.filter(line => !/^- \[ \] /.test(line)));
  }
  return out.join('\n');
}

// Resolve a markdown image src against the open ticket's own folder via the
// /api/ticket-image route — absolute/protocol-relative URLs pass through untouched.
export function resolveMockupSrc(src, ticketId) {
  if (/^(https?:)?\/\//.test(src) || src.startsWith('/')) return src;
  const relpath = src.split('/').map(encodeURIComponent).join('/');
  // An <img> is loaded by the browser directly, so the fetch wrapper (t-a55a) never sees it —
  // scope it here or a Cockpit project tab reads the server's default project (t-7d83).
  const proj = window.__canonProject ? `?project=${encodeURIComponent(window.__canonProject)}` : '';
  return `/api/ticket-image/${encodeURIComponent(ticketId)}/${relpath}${proj}`;
}

// Render a fenced Gherkin block as a styled scenario panel. Keyword-highlights
// Gherkin lines and escapes all text — raw doc content is never interpolated into
// HTML (esc() is applied to every fragment), so a scenario cannot inject markup.
const GHERKIN_KW = /^(\s*)(Scenario Outline|Scenario|Feature|Background|Examples|Rule|Given|When|Then|And|But|\*)/;
function renderGherkinFence(fence) {
  const indent = (fence && fence.indent) || '';
  const html = String(fence && fence.body != null ? fence.body : '').split('\n').map(rawLine => {
    const line = indent && rawLine.startsWith(indent) ? rawLine.slice(indent.length) : rawLine;
    if (/^\s*#/.test(line)) return `<span class="doc-scenario-comment">${esc(line)}</span>`;
    const m = line.match(GHERKIN_KW);
    if (m) {
      const lead = m[1], kw = m[2], rest = line.slice(lead.length + kw.length);
      return `${esc(lead)}<span class="doc-scenario-kw">${esc(kw)}</span>${esc(rest)}`;
    }
    return esc(line);
  }).join('\n');
  return `<div class="doc-scenario">${html}</div>`;
}

// A ```gherkin-file reference points at a ticket-local .feature path, and MAY carry
// an optional `runner: <cmd>` line naming the command that validates it. md() emits
// this placeholder synchronously; hydrateFeatureRefs() fetches + fills it after render.

// Split a ```gherkin-file body into { src, runner }: exactly one .feature path line
// plus an optional `runner:` line, order-independent, blank lines ignored. The first
// non-runner line is the path candidate (validated by the caller).
export function parseFeatureRefBody(body) {
  const runnerLine = /^runner:\s*(.*)$/i;
  let src = '', runner = '';
  String(body == null ? '' : body).split('\n').forEach(raw => {
    const line = raw.trim();
    if (!line) return;
    const m = line.match(runnerLine);
    if (m) { runner = m[1].trim(); return; }
    if (!src) src = line;
  });
  return { src, runner };
}

// Non-executable display of the runner command a scenario-backed criterion names.
// The board never runs this — the fresh evaluator executes `<runner> <feature>` at
// sprint complete (see skills/sprint/reference/eval.md). Every fragment is esc()'d and
// the value never reaches a shell, subprocess, or eval on any board code path.
export function renderRunnerLabel(runner, src) {
  const cmd = String(runner == null ? '' : runner).trim();
  if (!cmd) return '';
  const full = src ? `${cmd} ${src}` : cmd;
  return `<div class="doc-scenario-runner"><span class="doc-scenario-runner-label">Runner</span><code>${esc(full)}</code></div>`;
}

export function renderFeatureRefPlaceholder(body) {
  const featureRefRe = /^features\/[A-Za-z0-9._\-\/]+\.feature$/;
  const { src, runner } = parseFeatureRefBody(body);
  const raw = String(src == null ? '' : src).trim();
  if (!featureRefRe.test(raw) || raw.includes('..')) {
    return `<div class="doc-scenario doc-scenario-ref doc-scenario-error">Invalid feature reference: ${esc(raw)} (expected features/&lt;name&gt;.feature)</div>`;
  }
  const attr = esc(raw).replace(/"/g, '&quot;');
  const runnerAttr = esc(runner).replace(/"/g, '&quot;');
  return `<div class="doc-scenario doc-scenario-ref" data-feature-src="${attr}" data-runner="${runnerAttr}">Loading ${esc(raw)}…</div>`;
}

// Fetch each referenced ticket-local .feature and replace its placeholder with a
// rendered scenario panel (or a legible error state). Server-side _safe_ticket_doc /
// safeTicketDoc is the real trust boundary; this only reads .feature under the ticket.
export function hydrateFeatureRefs(container, ticketId) {
  if (!container || !ticketId) return;
  container.querySelectorAll('.doc-scenario-ref[data-feature-src]').forEach(el => {
    const src = el.getAttribute('data-feature-src') || '';
    const runner = el.getAttribute('data-runner') || '';
    const url = `/api/ticket-feature/${encodeURIComponent(ticketId)}/` +
      src.split('/').map(encodeURIComponent).join('/');
    fetch(url)
      .then(r => r.ok ? r.json() : Promise.reject(new Error('not-found')))
      .then(d => {
        const content = ((d && d.content) || '').replace(/\s+$/, '');
        if (!content.trim()) {
          el.className = 'doc-scenario doc-scenario-ref doc-scenario-error';
          el.textContent = `Empty feature file: ${src}`;
          return;
        }
        el.outerHTML = renderGherkinFence({ body: content }) + renderRunnerLabel(runner, src);
      })
      .catch(() => {
        el.className = 'doc-scenario doc-scenario-ref doc-scenario-error';
        el.textContent = `Could not load ${src}`;
      });
  });
}

// Minimal markdown: headers, bold, inline code, checklist items, bullet lists, images
export function md(raw, ticketId) {
  if (!raw) return '';
  // Pre-stamp each checkbox line with its source position using a null-byte
  // marker that survives esc() and sortChecklistRuns(), so the rendered index
  // matches the source file regardless of sort order.
  let srcIdx = 0;
  const stamped = raw.replace(/<!--[\s\S]*?-->/g, '').replace(/\n{3,}/g, '\n\n').trim()
    .replace(/^(- \[[ xX]\] )/gm, m => m + `\x00${srcIdx++}\x00`);

  // Extract ```gherkin-file references (body = a ticket-local .feature path) first —
  // these render asynchronously: md() emits a placeholder that hydrateFeatureRefs()
  // fetches and fills after the HTML is in the DOM (md() itself is synchronous).
  const featureRefs = [];
  const deRef = stamped.replace(
    /^([ \t]*)```[ \t]*gherkin-file[ \t]*\n([\s\S]*?)\n[ \t]*```[ \t]*$/gim,
    (_m, _indent, body) => { featureRefs.push(body.trim()); return `\x03${featureRefs.length - 1}\x03`; }
  );

  // Extract fenced Gherkin blocks (```gherkin / ```feature) before escaping or any
  // other transform, so their content renders as a scenario panel and is never
  // reinterpreted as markdown. Non-gherkin fences are left untouched (behavior unchanged).
  const fences = [];
  const deFenced = deRef.replace(
    /^([ \t]*)```[ \t]*(?:gherkin|feature)[ \t]*\n([\s\S]*?)\n[ \t]*```[ \t]*$/gim,
    (_m, indent, body) => {
      fences.push({ body, indent });
      return `\x02${fences.length - 1}\x02`;
    }
  );

  // Protect inline-code spans before any other syntax transform sees them —
  // otherwise markdown shown *as a code example* (e.g. `![alt](src)` or
  // `**bold**`) gets reinterpreted as real syntax instead of staying literal.
  const codeSpans = [];
  const withCodePlaceholders = sortChecklistRuns(esc(deFenced)).replace(/`((?:\\`|[^`\n])+)`/g, (_, code) => {
    codeSpans.push(code.replace(/\\`/g, '`'));
    return `\x01${codeSpans.length - 1}\x01`;
  });

  return withCodePlaceholders
    .replace(/^# (.+)$/gm,  '<strong class="doc-heading-1">$1</strong>')
    .replace(/^## (.+)$/gm, '<strong class="doc-heading-2">$1</strong>')
    .replace(/^### (.+)$/gm,'<strong class="doc-heading-3">$1</strong>')
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_, alt, src) => {
      const url = (ticketId ? resolveMockupSrc(src, ticketId) : src).replace(/"/g, '&quot;');
      return `<img class="doc-visual-img" src="${url}" alt="${alt.replace(/"/g, '&quot;')}" loading="lazy">`;
    })
    .replace(/\*\*(.+?)\*\*/g,'<strong style="color:var(--text)">$1</strong>')
    .replace(/^\*\*([^*\n][^\n]*)$/gm,'<strong style="color:var(--text)">$1</strong>')
    .replace(/^- \[([ xX])\] \x00(\d+)\x00(.+)$/gm, (_, checked, si, text) => {
      const done = checked.toLowerCase() === 'x';
      return `<span class="doc-bullet${done ? '' : ' doc-check-open'}" data-src-idx="${si}"><span class="doc-check-marker${done ? '' : ' open'}">${done ? '✓' : ''}</span><span>${text}</span></span>`;
    })
    .replace(/^- (.+)$/gm,  '<span class="doc-bullet"><span class="doc-bullet-marker">·</span><span>$1</span></span>')
    // Blank lines between table rows are a common LLM-markdown quirk — swallow
    // them with \n+ so the block still groups as one table; row extraction
    // below already filters blank lines out via `.filter(r => r.trim())`.
    .replace(/((?:\|[^\n]+(?:\n+|$))+)/g, block => {
      const rows = block.trim().split('\n').filter(r => r.trim());
      if (rows.length < 2) return block;
      const [headerRow, sepRow, ...bodyRows] = rows;
      if (!/^\|[\s|:-]+\|$/.test(sepRow?.trim() || '')) return block;
      const cells = row => row.trim().split(/(?<!\\)\|/).slice(1, -1)
          .map(c => c.trim().replace(/\\\|/g, '|'));
      const thead = '<thead><tr>' + cells(headerRow).map(c => `<th>${c}</th>`).join('') + '</tr></thead>';
      const STATUS_CLASSES = { pass: 'status-pass', fail: 'status-fail', partial: 'status-partial', 'not-run': 'status-not-run' };
      const tbody = bodyRows.length
        ? '<tbody>' + bodyRows.map(r => '<tr>' + cells(r).map(c => {
            const cls = STATUS_CLASSES[c.trim().toLowerCase()];
            return `<td${cls ? ` class="${cls}"` : ''}>${c}</td>`;
          }).join('') + '</tr>').join('') + '</tbody>'
        : '';
      return `<div class="doc-table-wrap"><table class="doc-table">${thead}${tbody}</table></div>`;
    })
    // Restore protected code spans last, after every other transform has run,
    // so backtick-wrapped text is never reinterpreted as image/bold/table/etc.
    .replace(/\x01(\d+)\x01/g, (_, i) => `<code class="doc-code">${codeSpans[+i]}</code>`)
    // Restore fenced Gherkin blocks as styled scenario panels.
    .replace(/\x02(\d+)\x02/g, (_, i) => renderGherkinFence(fences[+i]))
    // Restore ```gherkin-file references as async placeholders (hydrated post-render).
    .replace(/\x03(\d+)\x03/g, (_, i) => renderFeatureRefPlaceholder(featureRefs[+i]));
}
