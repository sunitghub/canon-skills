import { TICKET_TYPES, TYPE_TEMPLATES, detectTicketType, state } from './board-core.js';
import { WT_PREF_MAIN, esc, escAttr, titleCase } from './board-helpers.js';
import { editScratchTitle, newScratchId, openScratch, postWrite, renderBoard, startPromote } from './board-render.js';
import { blobToBase64, insertPlainText, nextPasteVisualIndex, readClipboardImages, resetPanelDrag, resetPanelResize, uploadVisual } from './board-panels.js';

// ── Create ticket ─────────────────────────────────────────────────────────

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initCreate() {
  (function initCreate() {
    const overlay  = document.getElementById('create-overlay');
    const titleEl  = document.getElementById('c-title');
    const detectEl = document.getElementById('c-detect');
    const typesEl  = document.getElementById('c-types');
    const priEl    = document.getElementById('c-priorities');
    const wtRow    = document.getElementById('c-worktree-row');
    const wtEl     = document.getElementById('c-worktree-pills');
    const bodyEl   = document.getElementById('c-body');
    const queueEl  = document.getElementById('c-queue');

    let selectedType = 'task';
    let selectedPri  = 2;
    let ciEnabled = false;
    let gateEval = false;
    let demoEnabled = false;
    let templateUntouched = true;
    let stagedVisuals = [];

    bodyEl.addEventListener('paste', e => {
      const images = readClipboardImages(e);
      if (!images.length) return;
      e.preventDefault();
      images.forEach(img => {
        const index = nextPasteVisualIndex();
        insertPlainText(bodyEl, `![pasted-${index}](pending:${index})`);
        stagedVisuals.push({ index, filename: `pasted-${index}.${img.ext}`, promise: blobToBase64(img.blob) });
      });
    });

    const ciBtn = document.getElementById('c-ci');
    const gateBtn = document.getElementById('c-gate-eval');
    const demoBtn = document.getElementById('c-demo');

    // Eval-only is only meaningful when CI is on; keep it disabled + reset otherwise.
    function syncGate() {
      gateBtn.disabled = !ciEnabled;
      gateBtn.style.opacity = ciEnabled ? '' : '0.4';
      if (!ciEnabled) { gateEval = false; gateBtn.classList.remove('active'); }
    }

    ciBtn.addEventListener('click', () => { ciEnabled = !ciEnabled; ciBtn.classList.toggle('active', ciEnabled); syncGate(); });
    gateBtn.addEventListener('click', () => { if (!ciEnabled) return; gateEval = !gateEval; gateBtn.classList.toggle('active', gateEval); });
    // Demo is independent of CI (no gate coupling).
    demoBtn.addEventListener('click', () => { demoEnabled = !demoEnabled; demoBtn.classList.toggle('active', demoEnabled); });

    // t-644a: a declared preference only, applied later at first Start (see
    // renderCockpitWorktree's pre-fill) -- nothing is created on disk from this
    // modal. wtMode is 'main' | an existing branch name | 'new'; worktreePreference()
    // derives the actual string sent on submit ('' = no line, present/absent
    // convention matching demo/ci/gate).
    let wtMode = 'main';
    let wtNewValue = '';
    // Once the user types into the worktree field directly, stop overwriting
    // it with a fresh title-derived suggestion — respect their edit.
    let wtNewTouched = false;
    function slugifyBranch(title) {
      return title.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
    }
    function worktreePreferenceValue() {
      if (wtMode === 'main') return WT_PREF_MAIN;
      if (wtMode === 'new') return wtNewValue.trim();
      return wtMode; // an existing branch name, selected as-is
    }
    function renderWorktreePills() {
      // t-2241: only worktrees a new ticket could use — held ones (another ticket
      // running there, reserved, uncommitted or unmerged work) are just counted.
      const nonMain = (state.worktreeListCache || []).filter(w => !w.is_main && w.branch);
      const existing = nonMain.filter(w => !w.held_by).map(w => w.branch);
      const heldWt = nonMain.filter(w => w.held_by);
      let html = `<button class="create-pill${wtMode === 'main' ? ' active' : ''}" data-wt="main">Main checkout</button>`;
      for (const b of existing) {
        html += `<button class="create-pill${wtMode === b ? ' active' : ''}" data-wt="${esc(b)}">${esc(b)}</button>`;
      }
      html += `<button class="create-pill${wtMode === 'new' ? ' active' : ''}" type="button" title="Type a branch name -- not created yet, just remembered for first Start" data-wt="new">+ New</button>`;
      if (heldWt.length) {
        const tip = heldWt.map(w => `${w.branch} — ${w.held_by.ticket ? w.held_by.ticket + ' · ' : ''}${w.held_by.reason}`).join('\n');
        html += `<span class="create-wt-held" title="${escAttr(tip)}">${heldWt.length} unavailable</span>`;
      }
      wtEl.innerHTML = html;
      if (wtMode === 'new') {
        // No ticket id exists yet at create time (unlike the rail's own +New,
        // which suggests sprint/<id>) -- derive a suggestion from the title
        // instead, same live-suggestion spirit.
        if (!wtNewTouched && !wtNewValue) {
          const title = titleEl.value.trim();
          if (title) wtNewValue = 'sprint/' + slugifyBranch(title);
        }
        wtEl.insertAdjacentHTML('beforeend', `<input id="c-wt-new-input" class="create-input" style="width:auto;flex:1;min-width:120px" placeholder="sprint/branch-name" value="${esc(wtNewValue)}" spellcheck="false" autocomplete="off">`);
        const input = document.getElementById('c-wt-new-input');
        input.addEventListener('focus', () => input.select());
        input.addEventListener('input', () => { wtNewValue = input.value; wtNewTouched = true; });
      }
      wtEl.querySelectorAll('.create-pill').forEach(btn => {
        btn.addEventListener('click', () => {
          wtMode = btn.dataset.wt;
          renderWorktreePills();
          if (wtMode === 'new') document.getElementById('c-wt-new-input')?.focus();
        });
      });
    }
    async function refreshWorktreeRow() {
      if (!state.isGitProject) { wtRow.style.display = 'none'; return; }
      wtRow.style.display = '';
      try {
        const r = await fetch('/api/worktrees');
        state.worktreeListCache = r.ok ? await r.json() : [];
      } catch { state.worktreeListCache = []; }
      renderWorktreePills();
    }

    function open() {
      selectedType = 'task'; selectedPri = 2; templateUntouched = true;
      ciEnabled = false; gateEval = false; demoEnabled = false; stagedVisuals = [];
      wtMode = 'main'; wtNewValue = ''; wtNewTouched = false;
      ciBtn.classList.remove('active');
      gateBtn.classList.remove('active'); demoBtn.classList.remove('active'); syncGate();
      refreshWorktreeRow();
      titleEl.value = ''; detectEl.textContent = '';
      bodyEl.value = TYPE_TEMPLATES['task'] || '';
      queueEl.textContent = '→ will open in: Open';
      document.getElementById('c-submit').disabled = false;
      resetPanelDrag(document.getElementById('create-modal'));
      resetPanelResize(document.getElementById('create-modal'));
      renderTypePills(); renderPriPills();
      overlay.classList.add('open');
      requestAnimationFrame(() => titleEl.focus());
    }

    function close() { overlay.classList.remove('open'); }

    function renderTypePills() {
      typesEl.innerHTML = TICKET_TYPES.map(tp =>
        `<button class="create-pill${tp === selectedType ? ' active' : ''}" data-type="${tp}">${titleCase(tp)}</button>`
      ).join('');
      typesEl.querySelectorAll('.create-pill').forEach(btn => {
        btn.addEventListener('click', () => {
          selectedType = btn.dataset.type;
          detectEl.textContent = '';
          applyTemplate();
          renderTypePills();
        });
      });
    }

    function renderPriPills() {
      priEl.innerHTML = [0,1,2,3,4].map(p =>
        `<button class="create-pill${p === selectedPri ? ' active' : ''}" data-pri="${p}">P${p}</button>`
      ).join('');
      priEl.querySelectorAll('.create-pill').forEach(btn => {
        btn.addEventListener('click', () => { selectedPri = +btn.dataset.pri; renderPriPills(); });
      });
    }

    function applyTemplate() {
      if (!templateUntouched) return;
      bodyEl.value = TYPE_TEMPLATES[selectedType] || '';
      templateUntouched = true;
    }

    bodyEl.addEventListener('input', () => {
      // once the user edits away from the template, stop auto-filling
      templateUntouched = bodyEl.value === (TYPE_TEMPLATES[selectedType] || '');
    });

    let detectTimer;
    titleEl.addEventListener('input', () => {
      clearTimeout(detectTimer);
      detectTimer = setTimeout(() => {
        const title = titleEl.value.trim();
        // Live branch-name suggestion, independent of the type-detect early
        // return below -- keeps updating (or clearing back) as the title
        // changes, right up until the user edits the worktree field itself.
        if (wtMode === 'new' && !wtNewTouched) {
          wtNewValue = title ? 'sprint/' + slugifyBranch(title) : '';
          const wtInput = document.getElementById('c-wt-new-input');
          if (wtInput) wtInput.value = wtNewValue;
        }
        if (!title) { detectEl.textContent = ''; return; }
        const { type, reason } = detectTicketType(title);
        detectEl.textContent = `Detected: ${titleCase(type)} — ${reason}`;
        if (type !== selectedType) {
          selectedType = type;
          applyTemplate();
          renderTypePills();
        }
      }, 350);
    });

    async function submit() {
      const title = titleEl.value.trim();
      if (!title) { titleEl.focus(); titleEl.style.borderColor = 'var(--col-discarded)'; return; }
      titleEl.style.borderColor = '';
      document.getElementById('c-submit').disabled = true;
      try {
        const created = await postWrite('/api/tickets', { title, type: selectedType, status: 'open', priority: selectedPri, body: bodyEl.value, ci: ciEnabled, gate: gateEval ? 'eval' : 'full', demo: demoEnabled, worktree_preference: worktreePreferenceValue() }, 'create the ticket');
        if (!created.ok) { document.getElementById('c-submit').disabled = false; return; }
        const ticket = created.data;

        if (stagedVisuals.length) {
          let body = ticket.body || '';
          for (const v of stagedVisuals) {
            const data = await v.promise;
            const result = await uploadVisual(ticket.id, v.filename, data);
            const replacement = result && result.ok
              ? `![pasted-${v.index}](visuals/${result.filename})`
              : '![paste failed]()';
            body = body.replace(`![pasted-${v.index}](pending:${v.index})`, replacement);
          }
          if (body !== ticket.body) {
            // The ticket exists either way; a failed body write is reported, not fatal.
            if ((await postWrite(`/api/ticket/${ticket.id}/body`, { body, base_hash: ticket.ticket_etag || '' }, `save ${ticket.id}'s pasted images`)).ok) ticket.body = body;
          }
        }

        state.tickets.unshift(ticket);
        renderBoard();
        close();
      } catch {
        document.getElementById('c-submit').disabled = false;
      }
    }

    document.getElementById('btn-create').addEventListener('click', open);
    document.getElementById('btn-scratch').addEventListener('click', () => openScratch(newScratchId()));   // t-e162
    document.getElementById('ck-promote').addEventListener('click', () => startPromote(false));          // t-f553
    document.getElementById('ck-tc-title').addEventListener('click', editScratchTitle);
    document.getElementById('create-close').addEventListener('click', close);
    document.getElementById('c-cancel').addEventListener('click', close);
    document.getElementById('c-submit').addEventListener('click', submit);
    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
    titleEl.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
  })();
}
