'use strict';

// t-7e36: seeded fallback in case /api/admin/model-tiers hasn't loaded yet (or is
// unreachable) — refreshModelTierOptions() below replaces this with the live
// Admin-owned registry's ids. This seeded fallback lists only Anthropic: the
// dropdown feeds parseGateModel/withGateModel below, whose session-level consumers
// (interactive sprint complete, sprint-headless) are Claude-Code-only — see
// DECISIONS.md 2026-07-27 (t-4003). t-ef27: once the registry loads, its OpenAI entries
// are appended as `openai:<id>` — a per-ticket pick that runs the close gates under
// Copilot CLI only (never the session), so the value carries the provider without a
// registry lookup.
let MODEL_TIER_OPTIONS = ['default', 'fable', 'opus', 'sonnet', 'haiku'];
let MODEL_TIER_LABELS = {};
(async () => {
  try {
    const r = await fetch('/api/admin/model-tiers');
    const reg = await r.json();
    // Gate model: persists the short alias (fable/opus/sonnet/haiku), not the
    // full API id — matches the value `claude -p --model` has always been
    // passed (DECISIONS.md t-4003) and every ticket's already-saved plan.md.
    const models = (reg.models && reg.models.anthropic) || [];
    const aliased = models.filter(m => m.alias);
    if (aliased.length) {
      MODEL_TIER_OPTIONS = ['default', ...aliased.map(m => m.alias)];
      MODEL_TIER_LABELS = Object.fromEntries(aliased.map(m => [m.alias, m.name]));
    }
    // Same charset rule as the resolvers (tools/gate-model.sh): a registry id that
    // wouldn't survive them is never offered, so the dropdown can't write an invalid value.
    const openai = ((reg.models && reg.models.openai) || []).filter(m => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(m.id || ''));
    for (const m of openai) {
      const v = 'openai:' + m.id.toLowerCase();
      MODEL_TIER_OPTIONS = [...MODEL_TIER_OPTIONS, v];
      MODEL_TIER_LABELS[v] = `${m.name || m.id} (OpenAI · Copilot gates only)`;
    }
  } catch { /* keep fallback */ }
})();
const SIGNOFF_TIER_OPTIONS = ['normal', 'bugfix', 'high-risk'];
const SIGNOFF_TIER_LABELS = { normal: 'Normal', bugfix: 'Bugfix', 'high-risk': 'High-risk' };

function parseGateModel(content) {
  const signoff = sectionContent(content, 'Sign-off');
  const tierLine = signoff.match(/^Tier:.*$/m);
  if (!tierLine) return { filled: false, value: null };
  const gateMatch = tierLine[0].match(/\|\s*Gate model:\s*(.+?)\s*$/i);
  return { filled: true, value: gateMatch ? gateMatch[1].trim() : null };
}

function withGateModel(content, newValue) {
  // Scope the rewrite to the Sign-off section only (same boundary logic as
  // sectionContent) — a global replace could otherwise match a "Tier:"-looking
  // line in an unrelated section (e.g. Approach prose).
  const heading = /^##\s+Sign-off\s*$/m;
  const headingMatch = heading.exec(content);
  if (!headingMatch) return content;
  const start = headingMatch.index + headingMatch[0].length;
  const rest = content.slice(start);
  const nextHeadingOffset = rest.search(/^##\s+/m);
  const end = nextHeadingOffset === -1 ? content.length : start + nextHeadingOffset;
  const section = content.slice(start, end).replace(
    /^(Tier:.*?)(\s*\|\s*Gate model:\s*.+?)?[ \t]*$/im,
    (m, base) => newValue === 'default' ? base : `${base} | Gate model: ${newValue}`
  );
  return content.slice(0, start) + section + content.slice(end);
}

// Parses the base (Tier + Risk) portion of the Sign-off line, independent of
// whatever Gate model suffix parseGateModel handles — mirrors its own logic
// with base and suffix swapped.
function parseSignoffBase(content) {
  const signoff = sectionContent(content, 'Sign-off');
  const tierLine = signoff.match(/^Tier:.*$/m);
  if (!tierLine) return { exists: false, parseable: true, tier: 'normal', risk: '' };
  const base = tierLine[0].replace(/\s*\|\s*Gate model:\s*.+?\s*$/i, '');
  const m = base.match(/^Tier:\s*(.+?)\s*\|\s*Risk:\s*(.*)$/i);
  const tier = m ? m[1].trim().toLowerCase() : '';
  if (!m || !SIGNOFF_TIER_OPTIONS.includes(tier)) return { exists: true, parseable: false };
  return { exists: true, parseable: true, tier, risk: m[2].trim() };
}

function withSignoffBase(content, tier, risk) {
  const heading = /^##\s+Sign-off\s*$/m;
  const headingMatch = heading.exec(content);
  if (!headingMatch) return content;
  const start = headingMatch.index + headingMatch[0].length;
  const rest = content.slice(start);
  const nextHeadingOffset = rest.search(/^##\s+/m);
  const end = nextHeadingOffset === -1 ? content.length : start + nextHeadingOffset;
  const section = content.slice(start, end);
  const newLine = `Tier: ${tier} | Risk: ${risk}`;
  const updatedSection = /^Tier:.*$/m.test(section)
    ? section.replace(
        /^(Tier:.*?)(\s*\|\s*Gate model:\s*.+?)?[ \t]*$/im,
        (m, base, suffix) => `${newLine}${suffix || ''}`
      )
    : '\n' + newLine + '\n' + section.replace(/^\n+/, '');
  return content.slice(0, start) + updatedSection + content.slice(end);
}

function injectSignoffControls(container, content, t) {
  let bar = container.parentNode.querySelector('.section-jumps');
  if (!bar) {   // t-e946: the link row no longer creates the bar; the sign-off controls own it
    bar = document.createElement('div');
    bar.className = 'section-jumps';
    container.parentNode.insertBefore(bar, container);
  }
  bar.querySelectorAll('.signoff-controls').forEach(el => el.remove());   // t-8c73: never two control sets in one bar

  // t-e78b: a live worktree plan.md is owned by the sprint session; these controls write plan.md.
  const locked = t.status === 'closed' || t.status === 'cancelled';
  const lockedTip = 'Ticket is closed — no further edits.';
  const wrap = document.createElement('span');
  wrap.className = 'signoff-controls';

  // ── Tier / Risk ──────────────────────────────────────────────────────
  const base = parseSignoffBase(content);
  if (base.parseable) {
    const tierSelect = document.createElement('select');
    tierSelect.className = 'signoff-tier-select';
    tierSelect.disabled = locked;
    tierSelect.title = locked ? lockedTip : 'Sprint tier.';
    SIGNOFF_TIER_OPTIONS.forEach(opt => {
      const o = document.createElement('option');
      o.value = opt;
      o.textContent = SIGNOFF_TIER_LABELS[opt] || opt;
      tierSelect.appendChild(o);
    });
    tierSelect.value = base.tier;

    const riskInput = document.createElement('input');
    riskInput.type = 'text';
    riskInput.className = 'signoff-risk-input';
    riskInput.placeholder = 'Risk: blast radius / key risks, one line';
    riskInput.value = base.risk;
    riskInput.disabled = locked;
    riskInput.title = locked ? lockedTip : base.risk;
    riskInput.addEventListener('input', () => { riskInput.title = riskInput.value; });

    const riskWarning = document.createElement('span');
    riskWarning.className = 'signoff-risk-warning';
    riskWarning.textContent = 'Type a Risk summary to save';
    riskWarning.style.display = 'none';

    const commitBase = async () => {
      const risk = riskInput.value.trim();
      if (!risk) {
        // never persist an empty Risk — surface it instead of silently no-op'ing,
        // since a Tier change with no Risk typed would otherwise vanish on reload
        // with no indication anything went wrong.
        riskInput.classList.add('signoff-risk-input--needs-value');
        riskWarning.style.display = '';
        return;
      }
      riskInput.classList.remove('signoff-risk-input--needs-value');
      riskWarning.style.display = 'none';
      tierSelect.disabled = true; riskInput.disabled = true;
      try {
        await updateDoc(modalState.activeDoc, content => withSignoffBase(content, tierSelect.value, risk), 'save the Sign-off tier/risk');
      } catch { /* the re-render below shows the saved value */ } finally {
        const cur = state.tickets.find(tk => tk.id === state.selectedId);
        if (cur) renderModalBody(cur);
      }
    };
    tierSelect.addEventListener('change', commitBase);
    riskInput.addEventListener('blur', commitBase);
    riskInput.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); riskInput.blur(); } });

    wrap.appendChild(signoffField('Tier', tierSelect));
    wrap.appendChild(signoffField('Risk', riskInput, 'signoff-field-risk'));
    wrap.appendChild(riskWarning);
  }

  // ── Model tier ───────────────────────────────────────────────────────
  const { filled, value } = parseGateModel(content);
  const currentLower = value ? value.toLowerCase() : 'default';
  const recognized = MODEL_TIER_OPTIONS.includes(currentLower);

  let disabledReason = '';
  if (locked) disabledReason = lockedTip;
  else if (!filled) disabledReason = 'Fill in Tier/Risk on Sign-off first.';
  else if (!recognized) disabledReason = `Custom override set by hand-edit: \`${value}\` — edit plan.md directly to change.`;

  const select = document.createElement('select');
  select.className = 'model-tier-select';
  select.title = disabledReason || 'Model used for this ticket’s sprint-close reviewer/evaluator gates.';
  select.disabled = Boolean(disabledReason);
  MODEL_TIER_OPTIONS.forEach(opt => {
    const o = document.createElement('option');
    o.value = opt;
    o.textContent = opt === 'default' ? 'Default' : (MODEL_TIER_LABELS[opt] || opt[0].toUpperCase() + opt.slice(1));
    select.appendChild(o);
  });
  select.value = recognized ? currentLower : 'default';
  select.addEventListener('change', async () => {
    select.disabled = true;
    try {
      await updateDoc(modalState.activeDoc, content => withGateModel(content, select.value), 'save the Gate model');
    } catch { /* the re-render below shows the saved value */ } finally {
      const cur = state.tickets.find(tk => tk.id === state.selectedId);
      if (cur) renderModalBody(cur);
    }
  });
  wrap.appendChild(signoffField('Gate model', select));

  // t-ef27: an explicit Gate model beats demo mode's forced-Haiku evaluator (complete.md
  // precedence), so say so — a demo ticket with a costlier pick is deliberate, not a surprise.
  if (String(t.demo) === 'true' && recognized && currentLower !== 'default' && currentLower !== 'haiku') {
    const hint = document.createElement('span');
    hint.className = 'model-tier-note model-tier-demo-hint';
    hint.textContent = 'Overrides Demo/UX’s Haiku';   // short: this row is already tight (full text in the title)
    hint.style.whiteSpace = 'nowrap';
    hint.title = 'Demo/UX is on, which normally forces a Haiku evaluator. An explicit Gate model overrides that, so this ticket’s gate runs on the model you picked.'
      + (currentLower.startsWith('openai:') ? ' An OpenAI pick only applies under Copilot CLI; elsewhere the gate falls back to Haiku.' : '');
    wrap.appendChild(hint);
  }

  bar.appendChild(wrap);
}

// t-bb97: a small inline label in front of a sign-off control.
function signoffField(text, control, cls = '') {
  const f = document.createElement('label');
  f.className = 'signoff-field' + (cls ? ' ' + cls : '');
  const l = document.createElement('span');
  l.className = 'signoff-field-label';
  l.textContent = text;
  f.append(l, control);
  return f;
}

function renderModalBody(t) {
  const bodyEl  = document.getElementById('m-body');
  document.getElementById('m-editor-toolbar').classList.remove('open');
  setEditAreaVisible(false);
  bodyEl.style.display = '';
  bodyEl.parentNode.querySelectorAll('.section-jumps').forEach(el => el.remove());
  // t-8c73: a newer render supersedes this one. Without this a slow doc fetch from an older
  // render lands after a newer one and injects a second bar (two .model-tier-select) or
  // overwrites the doc the user has since switched to.
  const seq = ++modalState.renderSeq;

  if (modalState.ghost) { renderGhostPane(t); return; }

  if (!modalState.activeDoc) {
    const content = (t.body || '').trim();
    if (!content) {
      bodyEl.innerHTML = '<span class="modal-empty">Empty ticket.</span>';
      return;
    }
    bodyEl.innerHTML = md(content, t.id);
    markDocHeadings(bodyEl, content);
    hydrateFeatureRefs(bodyEl, t.id);
    return;
  }

  if (modalState.activeDoc) {
    bodyEl.innerHTML = '<span class="modal-empty">Loading…</span>';
    fetchModalDoc(modalState.activeDoc)
      .then(r => r.ok ? r.json() : Promise.reject())
      .then(d => {
        if (seq !== modalState.renderSeq) return;   // t-8c73: superseded by a newer render
        if (!d.content) { bodyEl.innerHTML = '<span class="modal-empty">Empty doc.</span>'; return; }
        const slug = modalState.activeDoc ? docSlug(t, modalState.activeDoc) : '';
        let warning = '';
        if (slug === 'acceptance') {
          const missing = [];
          if (!hasFilledCheckbox(sectionContent(d.content, 'Criteria')))  missing.push('## Criteria');
          if (!hasFilledCheckbox(sectionContent(d.content, 'Test Plan'))) missing.push('## Test Plan');
          if (missing.length) {
            warning = `<div class="acceptance-warning">⚠ ${missing.join(' and ')} ${missing.length > 1 ? 'need' : 'needs'} checklist items — sprint complete will block</div>`;
          } else if (hasUncheckedBox(d.content)) {
            warning = `<div class="acceptance-warning">⚠ An unchecked item remains (Criteria, Test Plan, or QA) — sprint complete will block</div>`;
          }
        } else if (slug === 'plan') {
          if (!hasUsefulSectionText(sectionContent(d.content, 'Approach'), ['How will we implement it?'])) {
            warning = '<div class="acceptance-warning">⚠ ## Approach needs real notes — add the minimal plan before building</div>';
          }
        } else if (slug === 'eval-report') {
          const runIdMatch = d.content.match(/^evaluator-run-id:\s*(\S+)/m);
          if (runIdMatch) {
            warning = `<div class="eval-run-id"><span class="eval-run-id-label">evaluator-run-id</span>${esc(runIdMatch[1])}</div>`;
            d.content = d.content.replace(/^evaluator-run-id:[^\n]*\n?/m, '');
          } else {
            warning = '<div class="acceptance-warning">⚠ evaluator-run-id missing — sprint complete will block</div>';
          }
        }
        bodyEl.innerHTML = warning + md(d.content, t.id);
        tagCheckboxes(bodyEl);   // t-26f9: a live worktree doc's checkboxes toggle too (guarded by the etag)
        markDocHeadings(bodyEl, d.content);
        hydrateFeatureRefs(bodyEl, t.id);
        if (slug === 'plan') injectSignoffControls(bodyEl, d.content, t);
      })
      .catch(() => { if (seq === modalState.renderSeq) bodyEl.innerHTML = '<span class="modal-empty">Could not load doc.</span>'; });
  }
}

// t-a205: one answer to "may the board edit the active doc?" for the hint, double-click, the E key and enterEditMode.
function docEditable(t) {
  if (!t || t.status === 'closed' || t.status === 'cancelled' || modalState.ghost) return false;   // a ghost's pane (nothing to edit yet) owns the pane while it is open
  if (modalState.docOverride[modalState.activeDoc] != null) return false;   // t-6254: the worktree's copy, shown read-only
  const liveBranch = t.docs_from && t.docs_from.branch;
  if (liveBranch && modalState.activeDoc && !LIVE_EDITABLE_SLUGS.includes(docSlug(t, modalState.activeDoc))) return false;
  return true;
}

function setEditAreaVisible(on) {
  document.getElementById('m-editor-card').style.display = on ? 'flex' : 'none';
}

// Line-number gutter: one number per logical line, each as tall as that line renders once wrapped. A hidden mirror
// div measures the lines at the textarea's text width. Programmatic `.value =` writes fire no `input` event, so
// load, paste replacement and snippet insert call this directly.
const EDITOR_LINES_KEY = 'sprint-check-editor-lines';
function editorLinesOn() {
  try { return localStorage.getItem(EDITOR_LINES_KEY) !== '0'; } catch { return true; }
}
function refreshEditorGutter() {
  const card = document.getElementById('m-editor-card');
  const gut = document.getElementById('m-gutter');
  const ta = document.getElementById('m-edit-area');
  const on = editorLinesOn();
  gut.hidden = !on;
  document.getElementById('btn-editor-lines').setAttribute('aria-pressed', String(on));
  if (!on || card.style.display === 'none') return;
  let m = document.getElementById('m-gutter-mirror');
  if (!m) {
    m = document.createElement('div');
    m.id = 'm-gutter-mirror';
    m.className = 'editor-mirror';
    card.appendChild(m);
  }
  const cs = getComputedStyle(ta);
  m.style.width = Math.max(0, ta.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)) + 'px';
  m.innerHTML = ta.value.split('\n').map(l => `<div>${esc(l) || '&#8203;'}</div>`).join('');
  gut.innerHTML = Array.from(m.children, (c, i) => `<div style="height:${c.getBoundingClientRect().height}px">${i + 1}</div>`).join('');
  gut.scrollTop = ta.scrollTop;
}

function enterEditMode(t) {
  if (modalState.editMode) return;
  document.getElementById('stale-edit-notice')?.remove();
  if (!docEditable(t)) return;
  modalState.editMode = true;
  renderModalDocs(t);
  document.getElementById('m-docs').classList.add('editing');
  const bodyEl = document.getElementById('m-body');
  const editEl = document.getElementById('m-edit-area');

  if (modalState.activeDoc) {
    fetch(`/api/doc/${encodeURIComponent(modalState.activeDoc)}`)
      .then(r => r.ok ? r.json() : { content: '' })
      .then(d => {
        modalState.docEtag = (d && d.etag) || '';   // t-26f9: what Save must echo as base_hash
        editEl.value = ensureDocGuideComments(t, d.content || '');
        refreshEditorGutter();
        // On opening the Acceptance doc, drop the caret at the end of the last ## Criteria line so
        // authoring (and the Scenario button) starts under Criteria, not Test Plan. Runs after the
        // value is set, so it wins over the synchronous focus() below.
        if (docSlug(t, modalState.activeDoc) === 'acceptance') {
          const pos = criteriaCursorOffset(editEl.value);
          if (pos != null) { editEl.focus(); editEl.setSelectionRange(pos, pos); }
        }
      });
  } else {
    editEl.value = (t.body || '').trim();
  }

  bodyEl.style.display = 'none';
  bodyEl.parentNode.querySelectorAll('.section-jumps').forEach(el => el.remove());
  document.getElementById('m-editor-toolbar').classList.add('open');
  setEditAreaVisible(true);
  refreshEditorGutter();
  document.getElementById('m-kb-hint').style.display = '';
  editEl.focus();

  document.getElementById('m-actions').innerHTML = '';
  document.getElementById('m-kbd').style.display = 'none';
}

function exitEditMode(t) {
  modalState.editMode = false;
  document.getElementById('m-docs').classList.remove('editing');
  document.getElementById('m-editor-toolbar').classList.remove('open');
  document.getElementById('m-kb-hint').style.display = 'none';
  setText('m-title', t.title);
  renderModalDocs(t);
  renderModalBody(t);
  refreshModalActions(t);
  document.getElementById('m-kbd').style.display = '';
  renderBoard();
}

async function saveEdit(t) {
  let content = normalizeDocTitle(t, document.getElementById('m-edit-area').value);
  // For the Acceptance doc, seed the Test Plan runner placeholder before validating/saving, so a
  // first Save of a scenario-bearing doc both passes the Test Plan check and persists the
  // placeholder (guarded/idempotent — no-op when there's no scenario or a real command already).
  if (modalState.activeDoc && docSlug(t, modalState.activeDoc) === 'acceptance') {
    content = seedTestPlanRunnerPlaceholder(content);
  }
  const validationError = validateDocStructure(t, content);
  if (validationError) {
    alert(validationError);
    return;
  }
  if (modalState.activeDoc) {
    const res = await postWrite(`/api/doc/${encodeURIComponent(modalState.activeDoc)}`, { content, base_hash: modalState.docEtag || '' }, 'save this doc', { quietStale: true });
    if (res.stale) { showStaleEditNotice(t); return; }   // t-26f9: keep the text, let the person choose
    if (!res.ok) return; // stay in edit mode with the text intact
    if (modalState.ghost) {   // t-bb97: the ghost's first Save created the file
      const dt = DOC_TYPES.find(d => d.slug === modalState.ghost);
      t.docs = t.docs || [];
      if (!t.docs.some(d => d.file === modalState.activeDoc)) t.docs.push({ name: dt.name, file: modalState.activeDoc });
      modalState.docEtag = (res.data && res.data.etag) || '';
      modalState.ghost = '';
      modalState.seen.add(modalState.activeDoc);
    }
  } else {
    const res = await postWrite(`/api/ticket/${t.id}/body`, { body: content, base_hash: t.ticket_etag || '' }, 'save the description', { quietStale: true });
    if (res.stale) { showStaleEditNotice(t); return; }   // t-8be2: keep the text, let the person choose
    if (!res.ok) return;
    t.body = content;
    const etag = res.data && res.data.etag;
    if (etag) { t.ticket_etag = etag; const cur = findTicketById(t.id); if (cur) cur.ticket_etag = etag; }
    const headingMatch = content.match(/^#\s+(.+)$/m);
    if (headingMatch) t.title = headingMatch[1].trim();
  }
  exitEditMode(t);
}

function normalizeDocTitle(t, content) {
  if (!modalState.activeDoc) return content;

  const slug = docSlug(t, modalState.activeDoc);
  const titleBySlug = {
    acceptance: 'Acceptance',
    plan: 'Plan',
  };
  const title = titleBySlug[slug];
  if (!title) return ensureDocTicketLine(t, content);

  let next = content;
  if (/^#\s+.+$/m.test(content)) {
    next = content.replace(/^#\s+.+$/m, `# ${title}`);
  } else {
    next = `# ${title}\n\n${content}`;
  }
  return ensureDocTicketLine(t, next);
}

function ensureDocTicketLine(t, content) {
  if (/^Ticket:\s*.+?\s*$/m.test(content)) return content;
  const ticketBlock = `<!-- Keep the Ticket line below unchanged. -->\nTicket: \`${displayTicketId(t)}\``;
  if (/^#\s+.+$/m.test(content)) {
    return content.replace(/^(#\s+.+\n*)/m, `$1\n${ticketBlock}\n`);
  }
  return `${ticketBlock}\n\n${content}`;
}

function validateDocStructure(t, content) {
  if (!modalState.activeDoc) return '';

  const expectedTicket = `Ticket: \`${displayTicketId(t)}\``;
  const ticketLine = content.match(/^Ticket:\s*(.+?)\s*$/m);
  const actualTicketId = ticketLine ? normalizeTicketLineId(ticketLine[1]) : '';
  if (actualTicketId !== displayTicketId(t)) {
    return `Keep the ticket line unchanged: ${expectedTicket}`;
  }

  const slug = docSlug(t, modalState.activeDoc);
  const requiredBySlug = {
    acceptance: ['## Criteria', '## Test Plan', '## QA'],
    plan: ['## Sign-off', '## Approach', '## Decisions'],
  };
  const required = requiredBySlug[slug] || [];
  const missing = required.filter(h => !content.includes(h));
  if (missing.length > 0) {
    return `Keep these heading labels unchanged: ${missing.join(', ')}`;
  }

  const contentError = validateDocContent(slug, content);
  if (contentError) return contentError;

  return '';
}

function sectionContent(content, heading) {
  const re = new RegExp(`^##\\s+${heading}\\s*$`, 'm');
  const match = re.exec(content);
  if (!match) return '';
  const start = match.index + match[0].length;
  const rest = content.slice(start);
  const next = rest.search(/^##\s+/m);
  return (next === -1 ? rest : rest.slice(0, next)).trim();
}

function withoutGuidance(text) {
  return text
    .replace(/<!--[\s\S]*?-->/g, '')
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .filter(line => !line.startsWith('The checklist of behavior'))
    .filter(line => !line.startsWith('The commands or checks'))
    .filter(line => !line.startsWith('The approved sprint brief'))
    .join('\n')
    .trim();
}

function hasFilledCheckbox(text) {
  return /^- \[[ xX]\]\s+\S/m.test(withoutGuidance(text));
}

function hasUncheckedBox(text) {
  return /^\s*[-*]\s+\[ \]\s+\S/m.test(withoutGuidance(text));
}

function hasUsefulSectionText(text, placeholders = []) {
  const cleaned = withoutGuidance(text);
  if (!cleaned) return false;
  return !placeholders.some(p => cleaned === p);
}

// Slim structural validation for fenced Gherkin blocks (```gherkin / ```feature).
// Catches: a step before any Scenario, a Scenario with no steps, an unrecognized
// keyword among steps, an unclosed fence, and a block with no Scenario. This is a
// structural check, not a full Gherkin parser — free-text description lines (under
// Feature, or before a scenario's first step) are allowed to avoid false positives.
function validateGherkinBlocks(content) {
  const lines = String(content ?? '').split('\n');
  const OPEN  = /^[ \t]*```[ \t]*(?:gherkin|feature)[ \t]*$/i;
  const CLOSE = /^[ \t]*```[ \t]*$/;
  const STEP     = /^(?:Given|When|Then|And|But|\*)\b/;
  const SCENARIO = /^Scenario(?: Outline)?\b/;

  let inBlock = false, blockLine = 0, inDocstring = false;
  let sawScenario = false, ctxOpen = false, ctxIsScenario = false, ctxHasStep = false, ctxName = '';
  const scenarioNeedsSteps = () =>
    (ctxOpen && ctxIsScenario && !ctxHasStep)
      ? `Gherkin scenario "${ctxName}" has no Given/When/Then steps.`
      : '';

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!inBlock) {
      if (OPEN.test(line)) {
        inBlock = true; blockLine = i + 1; inDocstring = false;
        sawScenario = false; ctxOpen = false; ctxIsScenario = false; ctxHasStep = false; ctxName = '';
      }
      continue;
    }
    if (/^[ \t]*"""/.test(line)) { inDocstring = !inDocstring; continue; }
    if (inDocstring) continue;
    if (CLOSE.test(line)) {
      const e = scenarioNeedsSteps();
      if (e) return e;
      if (!sawScenario) return `Gherkin block (line ${blockLine}) has no Scenario — add a "Scenario:" line.`;
      inBlock = false; ctxOpen = false; continue;
    }
    const t = line.trim();
    if (!t || t.startsWith('#') || t.startsWith('@') || t.startsWith('|')) continue;
    if (SCENARIO.test(t)) {
      const e = scenarioNeedsSteps();
      if (e) return e;
      sawScenario = true; ctxOpen = true; ctxIsScenario = true; ctxHasStep = false;
      ctxName = t.replace(/^Scenario(?: Outline)?:?\s*/, '').trim() || '(unnamed)';
    } else if (/^Background\b/.test(t)) {
      const e = scenarioNeedsSteps();
      if (e) return e;
      ctxOpen = true; ctxIsScenario = false; ctxHasStep = false;
    } else if (STEP.test(t)) {
      if (!ctxOpen) return `Gherkin step "${t.split(/\s+/)[0]}" appears before any Scenario (line ${i + 1}).`;
      ctxHasStep = true;
    } else if (/^(?:Feature|Rule|Examples)\b/.test(t)) {
      if (/^Examples\b/.test(t)) { const e = scenarioNeedsSteps(); if (e) return e; ctxOpen = false; }
    } else if (ctxOpen && ctxIsScenario && ctxHasStep) {
      // A stray line once steps have started is a likely typo'd keyword. Description
      // lines (before the first step) are intentionally not flagged.
      return `Unrecognized Gherkin keyword "${t.split(/\s+/)[0]}" (line ${i + 1}). Expected Given/When/Then/And/But or a new Scenario.`;
    }
  }
  if (inBlock) return `Unclosed \`\`\`gherkin block (opened at line ${blockLine}). Add a closing \`\`\`.`;
  return '';
}

function validateDocContent(slug, content) {
  const gherkinError = validateGherkinBlocks(content);
  if (gherkinError) return gherkinError;

  if (slug === 'acceptance') {
    if (!hasFilledCheckbox(sectionContent(content, 'Criteria'))) {
      return 'Add at least one filled checklist item under ## Criteria before saving.';
    }
    if (!hasFilledCheckbox(sectionContent(content, 'Test Plan'))) {
      return 'Add at least one test command or check under ## Test Plan before saving.';
    }
  } else if (slug === 'plan') {
    if (!hasUsefulSectionText(sectionContent(content, 'Approach'), ['How will we implement it?'])) {
      return 'Add approach notes under ## Approach before saving.';
    }
  }
  return '';
}

// t-bb97: a doc that does not exist yet is a ghost node. Selecting it explains the doc and offers "+ <Doc>", which opens the
// template in the editor as an uncreated draft: Save writes the file (base_hash 'absent'), Cancel writes nothing.
function activateGhost(t, slug) {
  const dt = DOC_TYPES.find(d => d.slug === slug);
  if (!dt) return;
  modalState.ghost = slug;
  modalState.activeDoc = docFileFor(t, slug);
  renderModalDocs(t);
  renderModalBody(t);
  refreshModalActions(t);
  document.getElementById('m-kbd').style.display = '';
}

function renderGhostPane(t) {
  const dt = DOC_TYPES.find(d => d.slug === modalState.ghost);
  const bodyEl = document.getElementById('m-body');
  if (!dt) { bodyEl.innerHTML = ''; return; }
  bodyEl.innerHTML = `<div class="doc-ghost-pane"><h3>No ${esc(dt.name)} yet</h3><p>${esc(dt.hint)}</p><button type="button" class="btn btn-primary" id="btn-ghost-add">+ ${esc(dt.name)}</button></div>`;
  document.getElementById('btn-ghost-add').addEventListener('click', () => startGhostEdit(t, dt.slug));
}

function startGhostEdit(t, slug) {
  const dt = DOC_TYPES.find(d => d.slug === slug);
  if (!dt || modalState.editMode) return;
  const template = dt.template.replaceAll('<id>', t.id);
  modalState.editMode = true;
  modalState.docEtag = 'absent';
  renderModalDocs(t);
  document.getElementById('m-docs').classList.add('editing');
  const editEl = document.getElementById('m-edit-area');
  document.getElementById('m-body').style.display = 'none';
  document.getElementById('m-editor-toolbar').classList.add('open');
  editEl.value = template;
  setEditAreaVisible(true);
  refreshEditorGutter();
  document.getElementById('m-kb-hint').style.display = '';
  editEl.focus();
  if (slug === 'acceptance') {
    const pos = criteriaCursorOffset(editEl.value);
    if (pos != null) editEl.setSelectionRange(pos, pos);
  }
  document.getElementById('m-actions').innerHTML = '';
  document.getElementById('m-kbd').style.display = 'none';
}

function linePrefixForTextarea(textarea, prefix) {
  const start = textarea.selectionStart;
  const needsNewline = start > 0 && textarea.value[start - 1] !== '\n';
  return (needsNewline ? '\n' : '') + prefix;
}

function insertEditorSnippet(kind, textarea = document.getElementById('m-edit-area')) {
  textarea.focus();

  const start = textarea.selectionStart;
  const end = textarea.selectionEnd;
  const selected = textarea.value.slice(start, end);
  let before = '';
  let after = '';
  let cursorOffset = 0;

  if (kind === 'checkbox') {
    before = linePrefixForTextarea(textarea, '- [ ] ');
  } else if (kind === 'checked') {
    before = linePrefixForTextarea(textarea, '- [x] ');
  } else if (kind === 'bullet') {
    before = linePrefixForTextarea(textarea, '- ');
  } else if (kind === 'number') {
    before = linePrefixForTextarea(textarea, '1. ');
  } else if (kind === 'heading') {
    before = linePrefixForTextarea(textarea, '## ');
  } else if (kind === 'code') {
    before = '`';
    after = '`';
  } else if (kind === 'scenario') {
    before = linePrefixForTextarea(textarea, '- [ ] **Scenario name**\n```gherkin\nScenario: Scenario name\n  Given \n  And \n  When \n  Then \n  And \n```\n');
    after = '';
  } else if (kind === 'scenario-file') {
    before = linePrefixForTextarea(textarea, '- [ ] **Scenario name**\n```gherkin-file\nfeatures/name.feature\nrunner: python dsl_runner.py\n```\n');
    after = '';
  } else if (kind === 'bold') {
    before = '**';
    after = '**';
  }

  textarea.setSelectionRange(start, end);
  document.execCommand('insertText', false, before + selected + after);
  if (!selected && after) {
    cursorOffset = start + before.length;
    textarea.setSelectionRange(cursorOffset, cursorOffset);
  }

  // Inserting a scenario into the Acceptance editor should immediately seed the Test Plan runner
  // placeholder (so it shows up in-session and the first Save passes the Test Plan validation).
  // The seeded line lands under ## Test Plan, below the Criteria cursor, so prior offsets stay valid.
  if ((kind === 'scenario' || kind === 'scenario-file') && textarea.id === 'm-edit-area') {
    const seeded = seedTestPlanRunnerPlaceholder(textarea.value);
    if (seeded !== textarea.value) {
      const s = textarea.selectionStart, e = textarea.selectionEnd;
      textarea.value = seeded;
      textarea.setSelectionRange(s, e);
    }
  }
  if (textarea.id === 'm-edit-area') refreshEditorGutter();
}

function ensureTicketLineComment(content) {
  if (!/^Ticket:\s*`[^`]+`/m.test(content)) return content;
  if (content.includes('Keep the Ticket line below unchanged.')) return content;
  return content.replace(/^Ticket:\s*`[^`]+`/m, '<!-- Keep the Ticket line below unchanged. -->\n$&');
}

function ensureHeadingComment(content, heading, comment) {
  if (content.includes(comment)) return content;
  const re = new RegExp(`(^##\\s+${heading}\\s*$)`, 'm');
  return content.replace(re, `$1\n${comment}`);
}

// Does this doc contain a Gherkin scenario? (a fenced gherkin/gherkin-file block or a Scenario: line)
function hasGherkinScenario(content) {
  const s = String(content ?? '');
  return /```[ \t]*gherkin(?:-file)?\b/i.test(s) || /^[ \t]*Scenario:/m.test(s);
}

// Standard Test Plan runner placeholder — the *agent* writes the real command after building the
// runner (it chose the name/path/language); the board never hardcodes one. See DECISIONS t-a2f0.
// Kept function-local (not a module-level const) so the vm-sandbox unit test can load these hoisted
// functions without a TDZ on a partially-initialized script (t-6f8e lesson).

// When an Acceptance doc has a Gherkin scenario, seed the Test Plan placeholder — but only when
// `## Test Plan` has no real command yet, and never twice (idempotent). Pure: content -> content.
// Unit-tested in tests/sprint-check-seed.js.
function seedTestPlanRunnerPlaceholder(content) {
  const PLACEHOLDER = '- [ ] <the agent writes the runner command here after building the runner>';
  const s = String(content ?? '');
  if (!hasGherkinScenario(s)) return s;
  const lines = s.split('\n');
  const hIdx = lines.findIndex((l) => /^##[ \t]+Test Plan[ \t]*$/.test(l));
  if (hIdx === -1) return s;
  let end = lines.length;
  for (let i = hIdx + 1; i < lines.length; i++) { if (/^##[ \t]+/.test(lines[i])) { end = i; break; } }
  // Idempotent: already seeded.
  for (let i = hIdx + 1; i < end; i++) { if (lines[i].includes(PLACEHOLDER)) return s; }
  // A real command is already there (a checkbox with non-comment content) → never clobber.
  for (let i = hIdx + 1; i < end; i++) {
    const m = lines[i].match(/^[ \t]*-[ \t]*\[[ xX]\][ \t]*(.*)$/);
    if (m) { const body = m[1].trim(); if (body && !body.startsWith('<!--')) return s; }
  }
  // Prefer reusing an empty checkbox slot; otherwise insert after the heading + any guide comments.
  for (let i = hIdx + 1; i < end; i++) {
    const m = lines[i].match(/^([ \t]*)-[ \t]*\[[ xX]\][ \t]*$/);
    if (m) { lines[i] = m[1] + PLACEHOLDER; return lines.join('\n'); }
  }
  let insertAt = hIdx + 1;
  while (insertAt < end && /^[ \t]*<!--/.test(lines[insertAt])) insertAt++;
  lines.splice(insertAt, 0, PLACEHOLDER);
  return lines.join('\n');
}

// Offset of the end of the last content line in the `## Criteria` section, so the editor can drop
// the caret there on open (authoring + the Scenario button then land under Criteria, not Test Plan).
// Returns null when there is no `## Criteria` heading. Pure; unit-tested in tests/sprint-check-seed.js.
function criteriaCursorOffset(content) {
  const s = String(content ?? '');
  const lines = s.split('\n');
  const hIdx = lines.findIndex((l) => /^##[ \t]+Criteria[ \t]*$/.test(l));
  if (hIdx === -1) return null;
  let end = lines.length;
  for (let i = hIdx + 1; i < lines.length; i++) { if (/^##[ \t]+/.test(lines[i])) { end = i; break; } }
  // Last non-blank, non-comment line in the section (normally the last checkbox); else the heading.
  let target = hIdx;
  for (let i = hIdx + 1; i < end; i++) {
    const t = lines[i].trim();
    if (!t || t.startsWith('<!--')) continue;
    target = i;
  }
  let off = 0;
  for (let i = 0; i < target; i++) off += lines[i].length + 1; // + newline
  return off + lines[target].length; // end of the target line (before its trailing newline)
}

function ensureDocGuideComments(t, content) {
  let next = ensureTicketLineComment(content);
  const slug = modalState.activeDoc ? docSlug(t, modalState.activeDoc) : '';
  if (slug === 'acceptance') {
    next = ensureHeadingComment(next, 'Criteria', '<!-- Add or edit checklist items below. Keep this heading unchanged. -->');
    next = ensureHeadingComment(next, 'Test Plan', '<!-- Add or edit test commands below. Keep this heading unchanged. -->');
    next = ensureHeadingComment(next, 'QA', '<!-- Add sign-off items below. Keep this heading unchanged. -->');
    next = seedTestPlanRunnerPlaceholder(next);
  } else if (slug === 'plan') {
    next = ensureHeadingComment(next, 'Approach', '<!-- Add or edit approach notes below. Keep this heading unchanged. -->');
    next = ensureHeadingComment(next, 'Decisions', '<!-- Record choices made during the sprint. Keep this heading unchanged. -->');
  }
  return next;
}

function closeModal() {
  if (modalState.editMode) return; // don't close while editing
  document.getElementById('modal-overlay').classList.remove('open');
  modalState.ghost = '';
  modalState.docOverride = {};
  state.selectedId = null;
  stopHeadlessPoll();
  renderBoard();
}

function refreshModalActions(t) {
  const dv = document.getElementById('m-diverge');
  const info = divergenceInfo(t);
  dv.textContent = info ? info.long : '';
  dv.hidden = !info;
  const locked = t.status === 'closed' || t.status === 'cancelled';
  document.getElementById('m-actions').innerHTML = locked ? '' : `
    <button class="btn btn-danger" id="act-discard" title="Move this ticket to Discarded when the work is abandoned or no longer needed.">Discard ticket ✕</button>
  `;
  document.getElementById('act-discard')?.addEventListener('click', () => {
    if (confirm('Discard this ticket? Use Discard only when the work is abandoned or no longer needed.')) {
      moveCard(t, 'cancelled');
    }
  });
}

async function moveCard(t, newStatus) {
  // t-1940: only a confirmed save moves the card — a refused one used to look moved until refresh.
  const res = await postWrite(`/api/ticket/${t.id}/status`, { status: newStatus }, `move ${t.id}`);
  if (!res.ok) { renderBoard(); return; }
  t.status = newStatus;
  adoptTicketWrite(t.id, res.data);   // t-8be2: a bound ticket's own write moved its etag (and says what its text is)
  renderHeader();
  renderSidebar();
  const modalOpen = document.getElementById('modal-overlay').classList.contains('open');
  if (modalOpen) closeModal(); else renderBoard();
}
