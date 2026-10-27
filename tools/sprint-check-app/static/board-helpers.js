import { docSlug, state } from './board-core.js';
import { readiness } from './board-render.js';
import { esc, escAttr, resolveMockupSrc, parseFeatureRefBody, renderRunnerLabel, renderFeatureRefPlaceholder, renderGherkinFence, md } from './markdown.js';

export { esc, escAttr, resolveMockupSrc, parseFeatureRefBody, renderRunnerLabel, renderFeatureRefPlaceholder, md };

// ── Helpers ───────────────────────────────────────────────────────────────

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

// t-37e8: a ticket's tags as a lowercase list (the frontmatter value is a comma string, absent = none).
export function ticketTags(t) {
  return String((t && t.tags) ?? '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
}

function searchableText(t) {
  const r = readiness(t);
  return normalizeSearch([
    t.id,
    t.title,
    t.status,
    t.type,
    ticketTags(t).join(' '),
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
    ticketTags(t).join(' '),
    `p${t.priority ?? 2}`,
    t.body,
    r.label,
    r.ready ? 'ready' : '',
    r.acceptanceIncomplete ? 'acceptance incomplete incomplete' : '',
    r.acceptanceUnchecked ? 'unchecked items incomplete' : '',
    r.planIncomplete ? 'plan incomplete incomplete' : '',
  ].join(' '));
}

// t-a5c9: several ticket ids at once. `69f6 1ae4 f066` (an optional `t-` and commas allowed) is an ID LIST when it has two or more
// terms, each two to four characters of [0-9a-z], and each is part of at least one loaded ticket's id: the board then shows every
// ticket whose id contains ANY term, in addition to whatever the ordinary search finds for the same words (a real word spelled with a-f
// letters, like `add bad`, is also an id list: the union keeps its old results). A word in no id, a term longer than an id, or a single
// term is the ordinary search alone. Returns the terms, or null.
export function idQueryTerms(raw, tickets) {
  const split = idQuerySplit(raw, tickets);
  return split ? split.terms : null;
}

// t-b198: when EVERY term is written as a full id (`t-` then 2 to 4 of [0-9a-z]), a term that is part of no loaded ticket's id is
// dropped and the rest are the list: `t-43a2 t-1212` shows t-43a2. Only that spelling: a bare short word is part of some id almost
// always (`to do`), so bare terms keep the strict all-or-nothing rule above. Returns { terms, dropped } or null.
function idQuerySplit(raw, tickets) {
  const words = String(raw ?? '').toLowerCase().split(/[\s,]+/).filter(Boolean);
  const terms = words.map(x => x.replace(/^t-/, ''));
  if (terms.length < 2 || !terms.every(x => /^[0-9a-z]{2,4}$/.test(x))) return null;
  const ids = (tickets || []).map(t => String(t.id ?? '').toLowerCase().replace(/^t-/, ''));
  const known = x => ids.some(id => id.includes(x));
  if (terms.every(known)) return { terms, dropped: [] };
  if (!words.every(w => w.startsWith('t-'))) return null;
  const kept = terms.filter(known);
  return kept.length ? { terms: kept, dropped: terms.filter(x => !known(x)) } : null;
}

let idQueryMemo = { raw: null, list: null, len: -1, split: null };
function idSplitFor(raw) {
  // the filter runs once per ticket: work the terms out once per query and per loaded list (a reload assigns a new array)
  const q = String(raw ?? '');
  if (idQueryMemo.raw !== q || idQueryMemo.list !== state.tickets || idQueryMemo.len !== state.tickets.length) {
    idQueryMemo = { raw: q, list: state.tickets, len: state.tickets.length, split: idQuerySplit(q, state.tickets) };
  }
  return idQueryMemo.split;
}
function idTermsFor(raw) { const s = idSplitFor(raw); return s ? s.terms : null; }
// The ids the search ignored for this query, as typed (`t-1212`); empty when none, or when the query is not an id list.
export function idQueryDropped(raw) { const s = idSplitFor(raw); return s ? s.dropped.map(x => 't-' + x) : []; }

export function ticketMatchesQuery(t) {
  const q = normalizeSearch(state.query);
  if (state.queryMode !== 'search') return true;
  if (!q) return true;
  // t-37e8: `tag:github` (any case, spaces allowed after the colon) matches the tickets that carry that tag. From 3 characters on
  // the text only has to be part of a tag (`tag:git` finds github); shorter text must be the whole tag (`tag:go` is not `golang`).
  const tagQuery = /^\s*tag\s*:\s*(.*?)\s*$/i.exec(String(state.query ?? ''));
  if (tagQuery) {
    const want = tagQuery[1].toLowerCase();
    return ticketTags(t).some(x => want.length >= 3 ? x.includes(want) : x === want);
  }
  const idTerms = idTermsFor(state.query);
  if (idTerms) { const id = String(t.id ?? '').toLowerCase().replace(/^t-/, ''); if (idTerms.some(x => id.includes(x))) return true; }   // else the ordinary search below: nothing it found before is lost
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

// t-0aa7: the browser runs on the board's own machine, so its platform is the board's. The Terminal cannot run a cloud session on Windows yet.
export function isWindowsBrowser() { return /^win/i.test((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || ''); }

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
  const detail = `${esc(o.clean)} of ${esc(o.closed)} past ${esc(type || 'task')} tickets closed without eval rework`;
  return `<span class="outcome-dot ${good ? 'outcome-good' : 'outcome-mixed'}" tabindex="0" role="img" aria-label="${detail}" data-tooltip="${detail}"></span>`;
}

export function ciBadge(t) {
  if (String(t.ci) !== 'true') return '';
  return `<span class="ci-badge" title="CI-eligible — headless grading (tools/sprint-headless) can run against this ticket. Set with: tkt ci ${esc(t.id)} off">CI</span>`;
}

// t-be64: the badge, the switch, the New-ticket pill and the model hint name the reason (demo, docs, UX work), not the
// effect. The ticket flag stays `demo: true` (CLI, route, docs); only this text is "Lite".
export const LITE_LABEL = 'Lite';
export const LITE_TIP = 'Lite close — for live demos or docs/research/UX-mockup work: sprint complete runs security-review + the binding evaluator only (forced Haiku), skipping the advisory reviewer + rest of wrapup. Never drops below the evaluator.';

export function liteBadge(t) {
  if (String(t.demo) !== 'true') return '';
  return `<span class="lite-badge" title="${escAttr(LITE_TIP)} Set with: tkt demo ${esc(t.id)} off">${esc(LITE_LABEL.toUpperCase())}</span>`;
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
  if (t && t.status === 'open' && t.runs === 'github' && t.github && !t.merged) return 'in_progress';   // t-718b: out on GitHub (status stays open); github: alone is just a link
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
