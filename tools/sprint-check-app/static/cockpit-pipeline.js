// t-3a58: the Cockpit's Factory > Pipeline tab. It lists one project's sprint pipeline (GET /api/pipeline, which runs tools/pipeline.sh,
// the one reader) and changes it (POST /api/pipeline): switch an optional node off, move a wrapup gate with its arrows, Reset. The
// page never builds the file: it sends an op and the board writes canon-config/pipeline.yaml from the ids the reader listed.
// Declarations only; initPipeline() is run by cockpit-main.js with the other modules' load-time code.
import { esc, escAttr, toast } from './cockpit-core.js';
import { getProjects } from './cockpit-projects.js';
import { showView } from './cockpit-views.js';
import { TAG, MODES, label, progressCardHtml, skippedBy } from './sprint-progress-card.js';

const INLINE = new Set(['code-simplifier', 'code-reviewer', 'security-review', 'doc-audit']);   // run in your session, on its model
const FILE = 'canon-config/pipeline.yaml';
let pipePid = '', pipeData = null, pipeBusy = false, pipeGen = 0, focusAfter = '';
// t-51c6: "Preview a ticket": what a ticket's Lite or Manual option skips, read from each node's skip_on / only (pipeline.yaml, the one list).
// Display only: nothing here is saved or sent, and a project-level switch-off keeps its own wording.
let pipePrev = 'normal';
const PREVIEWS = MODES;
const prevManual = () => pipePrev === 'manual' || pipePrev === 'both';

const $ = id => document.getElementById(id);

// the dropdown follows the Factory page's project (the GitHub tab's select is the other half; both hold the same value)
function pipePick() {
  const sel = $('fac-pipe-project'), gh = $('fac-gh-project'), projects = getProjects();
  const want = sel.value || (gh && gh.value) || (projects[0] && projects[0].id) || '';
  sel.innerHTML = projects.map(p => `<option value="${escAttr(p.id)}">${esc(p.name)}</option>`).join('');
  if (projects.some(p => p.id === want)) sel.value = want;
  const p = projects.find(x => x.id === sel.value);
  $('fac-pipe-proj').innerHTML = p
    ? `Project <b>${esc(p.name)}</b> · <code>${esc(p.path)}</code><span class="fac-proj-note">Any change to canon's defaults is saved in canon-config/ at the project root.</span>`
    : 'No projects yet. Add one from the Projects page.';
  if (gh && sel.value && gh.value !== sel.value) gh.value = sel.value;
  return sel.value;
}

// the GitHub tab changed project: this tab follows (its next load reads the new value)
export function syncPipelineProject(pid) {
  const sel = $('fac-pipe-project');
  if (sel && pid && [...sel.options].some(o => o.value === pid)) sel.value = pid;
}

export async function loadPipeline(force) {
  const pid = pipePick();
  if (!pid) { renderEmpty(); return; }
  if (!force && pid === pipePid && pipeData) { render(pipeData); return; }
  pipePid = pid; const gen = ++pipeGen;
  let data;
  try {
    const r = await fetch('/api/pipeline?project=' + encodeURIComponent(pid));
    data = r.ok ? await r.json() : { ok: false, error: 'The board answered ' + r.status + '.' };
  } catch (e) { data = { ok: false, error: 'Could not reach the board: ' + String(e.message || e) }; }
  if (gen !== pipeGen) return;   // the project changed while this was loading
  pipeData = data; render(data);
}

function renderEmpty() {
  pipeData = null;
  $('fac-pipe-rows').innerHTML = '';
  $('fac-pipe-src').innerHTML = '';
  $('fac-pipe-reset').disabled = true;
  $('fac-pipe-yaml').textContent = '';
}

function rowHtml(n, group) {
  const gi = group.indexOf(n.id);
  const tag = `<span class="pl-k ${n.kind === 'you' ? 'you' : n.kind === 'agent' ? 'agent' : ''}">${esc(TAG[n.kind] || n.kind)}</span>`;
  const mv = n.group === 'wrapup'
    ? `<span class="pl-mvs"><button type="button" class="pl-mv" data-pl-mv="${escAttr(n.id)}:-1" aria-label="Move ${escAttr(label(n.id))} up"${gi === 0 ? ' disabled' : ''}>&uarr;</button> <button type="button" class="pl-mv" data-pl-mv="${escAttr(n.id)}:1" aria-label="Move ${escAttr(label(n.id))} down"${gi === group.length - 1 ? ' disabled' : ''}>&darr;</button></span>`
    : '<span></span>';
  const sw = n.locked
    ? `<span class="pl-lock" tabindex="0" title="${escAttr(n.reason)}" aria-label="${escAttr(label(n.id))} is locked: ${escAttr(n.reason)}">locked &middot; why</span>`
    : `<button type="button" class="pl-sw" role="switch" data-pl-tg="${escAttr(n.id)}" aria-checked="${n.on}" aria-label="${escAttr(label(n.id))} runs"></button>`;
  const why = n.locked ? n.reason : (n.when ? 'Runs only when: ' + n.when : '');
  const sb = skippedBy(n, pipePrev), idle = n.only === 'manual' && !prevManual(), ro = n.id === 'eval' && prevManual();
  const chips = (sb ? `<span class="pl-sk${sb === 'Manual' ? ' mn' : ''}">skipped &middot; ${esc(sb)}</span>` : '')
    + (idle ? '<span class="pl-sk mn">Manual tickets only</span>' : '')
    + (ro ? '<span class="pl-sk mn">read-only audit &middot; Manual</span>' : '');
  const skipNote = n.skip_on && !sb ? `<span class="pl-w">Skipped on ${n.skip_on.split(',').map(o => o === 'lite' ? 'Lite' : 'Manual').join(' and ')} tickets</span>` : '';
  const evalNote = n.id === 'eval' ? `<span class="pl-w">${ro ? 'On a Manual ticket it runs nothing and writes no tests: it checks your record is fresh, has no failing step, and matches the diff and the acceptance.' : 'On a Manual ticket it becomes a read-only audit of your record.'}</span>` : '';
  const model = n.model
    ? `<span class="pl-w"><span class="pl-md" title="${escAttr(n.model.source)}" tabindex="0">model &middot; ${esc(n.model.name)}</span> ${esc(n.model.source)};${n.id === 'eval' ? ' a Lite ticket runs it on Haiku, and' : ''} a ticket's <code>Gate model:</code> wins &middot; <button type="button" class="pl-link" data-pl-admin>change in Admin</button></span>`
    : INLINE.has(n.id) ? '<span class="pl-w">runs in your session &middot; session model</span>' : '';
  const swShown = sb && !n.locked ? `<button type="button" class="pl-sw" role="switch" aria-checked="false" disabled aria-label="${escAttr(label(n.id))} is skipped on this ticket"></button>` : sw;
  return `<div class="pl-row${n.on ? '' : ' off'}${n.group === 'wrapup' ? ' sub' : ''}${sb ? ' skp' : ''}${idle ? ' idle' : ''}" data-pl-row="${escAttr(n.id)}"><span>${tag}</span><div><span class="pl-n">${esc(label(n.id))}</span>${chips}${why ? `<span class="pl-w">${esc(why)}</span>` : ''}${skipNote}${evalNote}${model}</div>${mv}${swShown}</div>`;
}

function render(d) {
  const rows = $('fac-pipe-rows'), src = $('fac-pipe-src'), reset = $('fac-pipe-reset'), yaml = $('fac-pipe-yaml'), sum = $('fac-pipe-file-sum');
  reset.disabled = !(d.can_reset && (d.changed || !d.ok));
  if (d.exists && !d.ok) reset.disabled = !d.can_reset;
  yaml.textContent = d.exists && d.text ? d.text : 'extends: canon-default\n# a change adds only what differs, for example:\n# off: [mutation-test]\n# wrapup-order: [doc-audit, code-reviewer, code-simplifier]\n';
  sum.textContent = d.exists ? 'The file in canon-config/' : 'The file a first change would write';
  if (!d.ok) {
    src.innerHTML = d.exists ? `Using: <b>${FILE}</b> (not readable)` : '';
    rows.innerHTML = `<div class="pl-row pl-err"><span></span><div><span class="pl-n">${esc(d.error || 'The pipeline could not be read.')}</span><span class="pl-w">Fix or remove ${FILE}, or press Reset to rewrite it as canon's default.</span></div><span></span><span></span></div>`;
    return;
  }
  src.innerHTML = 'Using: ' + (d.exists ? `<b>${FILE}</b> (${d.changed ? 'your changes' : 'canon\'s default, no changes'})` : '<b>canon\'s default</b> (no project file)');
  const group = d.nodes.filter(n => n.group === 'wrapup').map(n => n.id);
  rows.innerHTML = d.nodes.map(n => rowHtml(n, group)).join('');
  $('fac-pipe-cardprev').innerHTML = progressCardHtml(d.nodes, pipePrev);   // t-2755: the same nodes, drawn as a ticket's Sprint progress card
  if (focusAfter) {
    const el = rows.querySelector(focusAfter);
    // an arrow that has reached the end is disabled now: keep focus in the row's other arrow, or the row itself
    (el && !el.disabled ? el : rows.querySelector('[data-pl-row] button:not(:disabled)'))?.focus();
    focusAfter = '';
  }
}

async function send(body, okMsg, focusSel) {
  if (pipeBusy || !pipePid) return;
  pipeBusy = true; $('fac-pipe-card').classList.add('pl-busy'); focusAfter = focusSel || '';
  const pid = pipePid;
  let res = null;
  try {
    const r = await fetch('/api/pipeline?project=' + encodeURIComponent(pid), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    res = await r.json().catch(() => null);
    if (!res) res = { ok: false, error: 'The board answered ' + r.status + '.' };
  } catch (e) { res = { ok: false, error: 'Could not reach the board: ' + String(e.message || e) }; }
  pipeBusy = false; $('fac-pipe-card').classList.remove('pl-busy');
  if (pid !== pipePid) return;   // the project changed meanwhile
  if (res.ok) {
    pipeData = res; render(res); toast(okMsg);
    if (res.created) showSaved();
  } else {
    toast(res.error || 'The change was refused.');
    focusAfter = ''; loadPipeline(true);   // show what is really on disk
  }
}

function showSaved() { $('pipe-saved').classList.add('show'); $('pipe-saved-ok').focus(); }
function hideSaved() {
  const s = $('pipe-saved'); if (!s.classList.contains('show')) return false;
  s.classList.remove('show');
  const back = $('fac-pipe-rows').querySelector('[data-pl-tg], [data-pl-mv]:not(:disabled)'); if (back) back.focus();
  return true;
}

export function initPipeline() {
  document.addEventListener('DOMContentLoaded', () => {
    $('fac-pipe-project').addEventListener('change', () => loadPipeline(false));
    $('fac-pipe-reset').addEventListener('click', () => send({ op: 'reset' }, "Reset: canon-config/pipeline.yaml now holds canon's default."));
    $('pipe-saved-ok').addEventListener('click', hideSaved);
    $('fac-pipe-prev').innerHTML = '<span class="pl-prev-k">Preview a ticket</span><span class="pl-prev-seg">'
      + PREVIEWS.map(([k, v]) => `<button type="button" data-pl-prev="${k}" aria-pressed="${k === pipePrev}">${v}</button>`).join('')
      + '</span><span class="pl-prev-h">Lite and Manual are set per ticket (New Ticket, Options). They only skip optional gates: a gate this project switched off stays off, and locked rows always run. Nothing here saves the preview.</span>';
    $('fac-pipe-prev').addEventListener('click', e => {
      const b = e.target.closest('[data-pl-prev]'); if (!b) return;
      pipePrev = b.dataset.plPrev;
      $('fac-pipe-prev').querySelectorAll('[data-pl-prev]').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
      if (pipeData && pipeData.ok) render(pipeData);
    });
    $('pipe-saved').addEventListener('click', e => { if (e.target === $('pipe-saved')) hideSaved(); });
    document.addEventListener('keydown', e => { if (e.key === 'Escape' && hideSaved()) e.stopPropagation(); }, true);
    $('fac-pipe-rows').addEventListener('click', e => {
      if (e.target.closest('[data-pl-admin]')) { showView('admin'); return; }   // the models are Admin's: this page only shows them
      const tg = e.target.closest('[data-pl-tg]');
      if (tg && pipeData && pipeData.nodes) {
        const id = tg.dataset.plTg, n = pipeData.nodes.find(x => x.id === id);
        if (n) send({ op: 'toggle', id, on: !n.on }, n.on ? `${label(id)} removed: saved in ${FILE}.` : `${label(id)} runs again: saved in ${FILE}.`, `[data-pl-tg="${CSS.escape(id)}"]`);
        return;
      }
      const mv = e.target.closest('[data-pl-mv]');
      if (mv && pipeData && pipeData.nodes) {
        const [id, dir] = mv.dataset.plMv.split(':'), ids = pipeData.nodes.filter(n => n.group === 'wrapup').map(n => n.id), i = ids.indexOf(id), j = i + Number(dir);
        if (i < 0 || j < 0 || j >= ids.length) return;
        [ids[i], ids[j]] = [ids[j], ids[i]];
        send({ op: 'order', wrapup: ids }, `Wrapup order saved in ${FILE}.`, `[data-pl-mv="${CSS.escape(id)}:${dir}"]`);
      }
    });
  });
}
