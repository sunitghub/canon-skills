import { state } from './board-core.js';
import { esc } from './board-helpers.js';
import { renderBoard, updateDoc } from './board-render.js';
import { modalState, openModal } from './board-modal.js';
import { refreshEditorGutter, renderModalBody } from './board-docs.js';

// ── Semantic ticket matching ──────────────────────────────────────────────

const _STOP = new Set(['a','an','the','and','or','in','on','for','to','of','with','by',
  'from','is','are','was','were','be','been','as','at','it','its','this','that','into',
  'via','add','fix','feat','chore','refactor','update','remove','change']);

function tokenize(s) {
  return s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/)
    .filter(w => w.length > 2 && !_STOP.has(w));
}

function semanticScore(commitText, ticketTitle) {
  const ctoks = new Set(tokenize(commitText));
  const ttoks  = tokenize(ticketTitle);
  const hits   = ttoks.filter(w => ctoks.has(w)).length;
  return hits / Math.max(ttoks.length, 1);
}

// ── Commit detail panel ───────────────────────────────────────────────────

export async function openCommitPanel(hash) {
  const overlay = document.getElementById('commit-overlay');
  resetPanelDrag(document.getElementById('commit-panel'));
  document.getElementById('co-hash').textContent    = hash.slice(0, 7);
  document.getElementById('co-subject').textContent = '…';
  document.getElementById('co-meta').textContent    = '';
  document.getElementById('co-body').textContent    = '';
  document.getElementById('co-tickets').innerHTML   = '';
  document.getElementById('co-files').innerHTML     = '';
  overlay.classList.add('open');

  try {
    const d = await fetch(`/api/commit/${hash}`).then(r => r.json());
    document.getElementById('co-subject').textContent = d.subject;
    document.getElementById('co-meta').innerHTML =
      `<span class="commit-meta-chip">${esc(d.author || 'Unknown author')}</span>` +
      `<span class="commit-meta-chip">${esc(d.date || 'Unknown date')}</span>`;
    document.getElementById('co-body').textContent    = d.body || '';

    const ticketsEl = document.getElementById('co-tickets');
    const direct    = state.tickets.filter(t => d.related_ticket_ids.includes(t.id));

    let chips, label, note = '';
    if (direct.length) {
      chips = direct;
      label = 'Related tickets';
    } else {
      // Semantic backfill: score all tickets against the commit text
      const commitText = `${d.subject} ${d.body} ${d.files.join(' ')}`;
      const scored = state.tickets
        .filter(t => t.status !== 'cancelled')
        .map(t => ({ t, score: semanticScore(commitText, t.title) }))
        .filter(x => x.score > 0)
        .sort((a, b) => b.score - a.score);
      chips = scored.map(x => x.t);
      label = chips.length ? 'Likely related tickets' : 'Active sprint context';
      note  = chips.length
        ? `<div class="commit-section-note">No ticket IDs in commit — matched by keyword.</div>`
        : `<div class="commit-section-note">No ticket IDs in commit. Tip: prefix commits with <code class="doc-code">${esc(state.tickets.find(t=>t.status==='in_progress')?.id ?? 't-xxxx')}: </code></div>`;
      if (!chips.length) chips = state.tickets.filter(t => t.status === 'open' || t.status === 'in_progress');
    }

    if (chips.length) {
      ticketsEl.innerHTML =
        `<div class="commit-section"><div class="commit-section-label">${label}</div>${note}` +
        `<div class="commit-ticket-chips">` +
        chips.map(t =>
          `<button class="commit-ticket-chip" data-id="${esc(t.id)}">${esc(t.id)} — ${esc(t.title)}</button>`
        ).join('') + `</div></div>`;
      ticketsEl.querySelectorAll('.commit-ticket-chip').forEach(btn => {
        btn.addEventListener('click', () => { closeCommitPanel(); openModal(btn.dataset.id); });
      });
    }

    if (d.files.length) {
      document.getElementById('co-files').innerHTML =
        `<div class="commit-section"><div class="commit-section-label">${d.files.length} file${d.files.length > 1 ? 's' : ''} changed</div>` +
        `<div class="commit-file-list">` +
        d.files.map(f => `<div class="commit-file">${esc(f)}</div>`).join('') +
        `</div></div>`;
    }
  } catch {
    document.getElementById('co-subject').textContent = 'Could not load commit.';
  }
}

function closeCommitPanel() {
  document.getElementById('commit-overlay').classList.remove('open');
}

export function resetPanelDrag(panel) {
  if (!panel) return;
  panel.dataset.dragX = '0';
  panel.dataset.dragY = '0';
  panel.style.setProperty('--drag-x', '0px');
  panel.style.setProperty('--drag-y', '0px');
}

export function resetPanelResize(panel) {
  if (!panel) return;
  panel.style.width = '';
  panel.style.height = '';
}

export function makePanelDraggable(panelId, headerSelector = '.modal-header') {
  const panel = document.getElementById(panelId);
  const header = panel?.querySelector(headerSelector);
  if (!panel || !header) return;

  const sideHandles = [...(panel.querySelectorAll('.modal-side-drag') || [])];
  const handles = [header, ...sideHandles];

  let dragging = false;
  let activeHandle = null;
  let startX = 0;
  let startY = 0;
  let baseX = 0;
  let baseY = 0;

  handles.forEach(handle => {
    handle.addEventListener('pointerdown', e => {
      if (e.target.closest('button, a, input, textarea, select')) return;
      dragging = true;
      activeHandle = handle;
      startX = e.clientX;
      startY = e.clientY;
      baseX = Number(panel.dataset.dragX || 0);
      baseY = Number(panel.dataset.dragY || 0);
      handle.classList.add('dragging');
      panel.classList.add('dragging-panel');
      document.body.style.userSelect = 'none';
      handle.setPointerCapture(e.pointerId);
    });

    handle.addEventListener('pointermove', e => {
      if (!dragging) return;
      const nextX = baseX + e.clientX - startX;
      const nextY = baseY + e.clientY - startY;
      panel.dataset.dragX = String(nextX);
      panel.dataset.dragY = String(nextY);
      panel.style.setProperty('--drag-x', `${nextX}px`);
      panel.style.setProperty('--drag-y', `${nextY}px`);
    });

    const stopDrag = e => {
      if (!dragging) return;
      dragging = false;
      handle.classList.remove('dragging');
      panel.classList.remove('dragging-panel');
      document.body.style.userSelect = '';
      activeHandle = null;
      try { handle.releasePointerCapture(e.pointerId); } catch {}
    };

    handle.addEventListener('pointerup', stopDrag);
    handle.addEventListener('pointercancel', stopDrag);
  });
}

export function makePanelResizable(panelId) {
  const panel = document.getElementById(panelId);
  if (!panel) return;
  panel.querySelectorAll('.modal-resize-handle').forEach(handle => {
    const topLeft = handle.classList.contains('modal-resize-handle-tl');
    let resizing = false;
    let startX = 0, startY = 0, startWidth = 0, startHeight = 0, startDragX = 0, startDragY = 0;

    handle.addEventListener('pointerdown', e => {
      resizing = true;
      startX = e.clientX;
      startY = e.clientY;
      const rect = panel.getBoundingClientRect();
      startWidth = rect.width;
      startHeight = rect.height;
      startDragX = Number(panel.dataset.dragX || 0);
      startDragY = Number(panel.dataset.dragY || 0);
      handle.classList.add('resizing');
      panel.classList.add('resizing-panel');
      document.body.style.userSelect = 'none';
      handle.setPointerCapture(e.pointerId);
      e.preventDefault();
      e.stopPropagation();
    });

    handle.addEventListener('pointermove', e => {
      if (!resizing) return;
      const maxWidth = Math.max(320, window.innerWidth - 24);
      const maxHeight = Math.max(320, window.innerHeight - 24);
      const minWidth = Math.min(420, maxWidth);
      const minHeight = Math.min(320, maxHeight);
      const dx = e.clientX - startX, dy = e.clientY - startY;
      const nextWidth = Math.min(maxWidth, Math.max(minWidth, startWidth + (topLeft ? -dx : dx)));
      const nextHeight = Math.min(maxHeight, Math.max(minHeight, startHeight + (topLeft ? -dy : dy)));
      panel.style.width = `${nextWidth}px`;
      panel.style.height = `${nextHeight}px`;
      if (topLeft) {
        // t-612f: the dialog is centred, so growing it from the top-left keeps the bottom-right corner still only if the centre
        // moves back by half of each size change (the same --drag offset the side drags use)
        const nx = startDragX - (nextWidth - startWidth) / 2, ny = startDragY - (nextHeight - startHeight) / 2;
        panel.dataset.dragX = String(nx);
        panel.dataset.dragY = String(ny);
        panel.style.setProperty('--drag-x', `${nx}px`);
        panel.style.setProperty('--drag-y', `${ny}px`);
      }
    });

    const stopResize = e => {
      if (!resizing) return;
      resizing = false;
      handle.classList.remove('resizing');
      panel.classList.remove('resizing-panel');
      document.body.style.userSelect = '';
      try { handle.releasePointerCapture(e.pointerId); } catch {}
    };

    handle.addEventListener('pointerup', stopResize);
    handle.addEventListener('pointercancel', stopResize);
  });
}

// ── Inline checkbox toggle ────────────────────────────────────────────────

export function tagCheckboxes(el) {
  const t = state.tickets.find(tk => tk.id === state.selectedId);
  const locked = !t || t.status === 'closed' || t.status === 'cancelled';
  let count = 0;
  el.querySelectorAll('.doc-bullet[data-src-idx]').forEach(bullet => {
    if (!locked) {
      // Promote the source index to data-check-idx so the click handler finds it
      bullet.dataset.checkIdx = bullet.dataset.srcIdx;
      count++;
    } else {
      delete bullet.dataset.checkIdx;
    }
  });
  const tip = document.getElementById('m-check-tip');
  if (tip) tip.classList.toggle('visible', count > 0 && !modalState.editMode && !locked);
}

async function toggleCheckbox(docFile, checkIdx) {
  let firstText = null;
  const res = await updateDoc(docFile, (content, attempt) => {
    let i = 0, seen = null;
    const updated = content.replace(/^(- \[)([ xX])(\] .+)$/gm, (m, pre, mark, rest) => {
      if (i++ === checkIdx) { seen = rest; return pre + (mark.trim() === '' ? 'x' : ' ') + rest; }
      return m;
    });
    if (seen === null) throw new Error('that checklist item is gone — reload');
    // On a re-apply after a collision, flip the same item only if it is still the item the person clicked.
    if (attempt === 0) firstText = seen;
    else if (seen !== firstText) throw new Error('the checklist changed — reload');
    return updated;
  }, 'update that checkbox');
  return !!res.ok;
}

// ── Clipboard image paste (t-626d) ─────────────────────────────────────────
// Lands pasted images in .tickets/<id>/visuals/, the same convention `sprint
// start` uses for mockups/visual references (standards/ticket-layout.md).

export const PASTE_IMAGE_EXT = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' };
let pasteVisualCounter = 0;

export function nextPasteVisualIndex() {
  pasteVisualCounter += 1;
  return pasteVisualCounter;
}

export function readClipboardImages(e) {
  const items = e.clipboardData && e.clipboardData.items;
  if (!items) return [];
  const out = [];
  for (const item of items) {
    if (item.kind !== 'file') continue;
    const ext = PASTE_IMAGE_EXT[item.type];
    if (!ext) continue;
    const blob = item.getAsFile();
    if (blob) out.push({ blob, ext });
  }
  return out;
}

export function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

// Pasted images and the toolbar's image button share one flow: a marker at the caret while the upload runs, then the
// markdown (or failText). The marker is re-located afterwards because the person may keep typing during the upload.
export async function uploadImageIntoEditor(editEl, ticketId, blob, filename, label, failText) {
  const marker = `![Uploading ${label}…]()`;
  const markerStart = editEl.selectionStart;
  insertPlainText(editEl, marker);
  const result = await uploadVisual(ticketId, filename, await blobToBase64(blob));
  const replacement = result && result.ok ? `![${label}](visuals/${result.filename})` : failText;
  const at = editEl.value.indexOf(marker, markerStart);
  if (at !== -1) {
    editEl.value = editEl.value.slice(0, at) + replacement + editEl.value.slice(at + marker.length);
    refreshEditorGutter();
  }
}

export function insertPlainText(textarea, text) {
  textarea.focus();
  textarea.setSelectionRange(textarea.selectionStart, textarea.selectionEnd);
  document.execCommand('insertText', false, text);
}

export async function uploadVisual(ticketId, filename, base64) {
  try {
    const res = await fetch(`/api/ticket/${ticketId}/visual`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ filename, data: base64 }),
    });
    return res.ok ? await res.json() : { ok: false };
  } catch {
    return { ok: false };
  }
}

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initPanels() {
  document.getElementById('commit-close').addEventListener('click', closeCommitPanel);
  document.getElementById('commit-overlay').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeCommitPanel();
  });

  makePanelDraggable('modal');
  makePanelDraggable('commit-panel');
  makePanelDraggable('create-modal');
  makePanelResizable('modal');
  makePanelResizable('create-modal');
  makePanelDraggable('gh-dialog-box', '#gh-dialog-title');   // t-e523: the GitHub dialog moves by its title
  makePanelResizable('gh-dialog-box');

  // Delegated handler — fires once, lives on #m-body permanently
  document.getElementById('m-body').addEventListener('click', async e => {
    if (modalState.editMode) return;
    const bullet = e.target.closest('.doc-bullet[data-check-idx]');
    if (!bullet || !modalState.activeDoc) return;
    const currentTicket = state.tickets.find(tk => tk.id === state.selectedId);
    if (!currentTicket || currentTicket.status === 'closed' || currentTicket.status === 'cancelled') return;
    e.stopPropagation();

    const idx = Number(bullet.dataset.checkIdx);
    const marker = bullet.querySelector('.doc-check-marker');
    const wasOpen = bullet.classList.contains('doc-check-open');

    // Optimistic UI update
    bullet.classList.add('toggling');
    bullet.classList.toggle('doc-check-open', !wasOpen);
    if (marker) { marker.classList.toggle('open', !wasOpen); marker.textContent = wasOpen ? '✓' : ''; }

    const saved = await toggleCheckbox(modalState.activeDoc, idx);
    bullet.classList.remove('toggling');
    if (!saved) { // t-1940: revert the optimistic flip
      bullet.classList.toggle('doc-check-open', wasOpen);
      if (marker) { marker.classList.toggle('open', wasOpen); marker.textContent = wasOpen ? '' : '✓'; }
    }

    // Re-sync tickets so readiness indicators update on the board
    try {
      const tr = await fetch('/api/tickets');
      if (tr.ok) { state.tickets = await tr.json(); renderBoard(); }
    } catch {}
    // Re-render the modal body to reflect the saved state
    const t = state.tickets.find(tk => tk.id === state.selectedId);
    if (t) renderModalBody(t);
  });
}
