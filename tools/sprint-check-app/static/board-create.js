import { TICKET_TYPES, TYPE_TEMPLATES, detectTicketType, state } from './board-core.js';
import { LITE_LABEL, LITE_TIP, titleCase } from './board-helpers.js';
import { editScratchTitle, newScratchId, openScratch, postWrite, renderBoard, startPromote } from './board-render.js';
import { openTagMenu, tagChipsHTML } from './board-tags.js';
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
    const bodyEl   = document.getElementById('c-body');
    const queueEl  = document.getElementById('c-queue');

    let selectedType = 'task';
    let selectedPri  = 2;
    let ciEnabled = false;
    let gateEval = false;
    let demoEnabled = false;
    let templateUntouched = true;
    let stagedVisuals = [];
    let createTags = [];   // t-37e8: the tags picked in the dropdown; sent with the create
    const tagsBtn = document.getElementById('c-tags-btn');
    const paintCreateTags = () => { document.getElementById('c-tag-chips').innerHTML = tagChipsHTML(createTags, 8); tagsBtn.textContent = createTags.length ? 'Edit tags' : '+ Tags'; };
    tagsBtn.addEventListener('click', () => openTagMenu({ anchor: tagsBtn, selected: createTags, onChange: async tags => { createTags = tags; paintCreateTags(); return true; } }));

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
    demoBtn.textContent = LITE_LABEL; demoBtn.title = LITE_TIP;

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

    function open() {
      selectedType = 'task'; selectedPri = 2; templateUntouched = true;
      ciEnabled = false; gateEval = false; demoEnabled = false; stagedVisuals = [];
      createTags = []; paintCreateTags();
      ciBtn.classList.remove('active');
      gateBtn.classList.remove('active'); demoBtn.classList.remove('active'); syncGate();
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
        const created = await postWrite('/api/tickets', { title, type: selectedType, status: 'open', priority: selectedPri, body: bodyEl.value, ci: ciEnabled, gate: gateEval ? 'eval' : 'full', demo: demoEnabled, tags: createTags }, 'create the ticket');
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
    document.getElementById('btn-terminal').addEventListener('click', () => openScratch(newScratchId(), { term: true }));   // t-57ab
    document.getElementById('ck-promote').addEventListener('click', () => startPromote(false));          // t-f553
    document.getElementById('ck-tc-title').addEventListener('click', editScratchTitle);
    document.getElementById('create-close').addEventListener('click', close);
    document.getElementById('c-cancel').addEventListener('click', close);
    document.getElementById('c-submit').addEventListener('click', submit);
    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
    titleEl.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
  })();
}
