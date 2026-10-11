import { handleMarkdownEnter, handleTabIndent } from './editor.js';
import { fetchVersion, loadData, state } from './board-core.js';
import { normalizeSearch, whyQueryFromInput } from './board-helpers.js';
import { renderBoard, showToast } from './board-render.js';
import { activateDoc, modalState, refreshDocTree } from './board-modal.js';
import { EDITOR_LINES_KEY, closeModal, docEditable, editorLinesOn, enterEditMode, exitEditMode, insertEditorSnippet, refreshEditorGutter } from './board-docs.js';
import { PASTE_IMAGE_EXT, insertPlainText, nextPasteVisualIndex, readClipboardImages, uploadImageIntoEditor } from './board-panels.js';

// ── Keyboard ──────────────────────────────────────────────────────────────

// ── Util ──────────────────────────────────────────────────────────────────

export function setText(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = String(val ?? '');
}

// ── Sidebar collapse + resize ─────────────────────────────────────────────

// ── Board search ─────────────────────────────────────────────────────────

// ── Tour panel ────────────────────────────────────────────────────────────

// ── Theme toggle ──────────────────────────────────────────────────────────

// ── Boot ──────────────────────────────────────────────────────────────────

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initUi() {
  document.addEventListener('keydown', e => {
    const open = document.getElementById('modal-overlay').classList.contains('open');
    if (!open) return;

    if (e.key === 'Escape') {
      if (modalState.editMode) {
        const t = state.tickets.find(t => t.id === state.selectedId);
        if (t) exitEditMode(t);
      } else {
        closeModal();
      }
      return;
    }

    // t-a205: `e` starts editing, where the Edit button used to; never while typing in a field or with a modifier held.
    if (e.key === 'e' && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && !modalState.editMode && !modalState.ghost) {
      const tg = e.target;
      if (tg && (tg.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(tg.tagName))) return;
      const t = state.tickets.find(x => x.id === state.selectedId);
      if (t && docEditable(t)) { e.preventDefault(); enterEditMode(t); }
    }
  });

  // t-a205: double-click the document to edit it (checkbox rows and controls keep their own meaning).
  document.getElementById('m-body').addEventListener('dblclick', e => {
    if (modalState.editMode || e.target.closest('.doc-bullet[data-check-idx], button, input, select, textarea')) return;
    const t = state.tickets.find(x => x.id === state.selectedId);
    if (t && docEditable(t)) enterEditMode(t);
  });

  // t-612f: + / - on a doc node, and a section row (of the open doc or of one that is not open yet)
  document.getElementById('m-docs').addEventListener('click', e => {
    const ex = e.target.closest('.doc-expander');
    const ch = e.target.closest('.doc-child');
    if ((!ex && !ch) || modalState.editMode) return;
    if (ex) {
      const key = ex.dataset.key;
      if (modalState.expanded.has(key)) modalState.expanded.delete(key); else modalState.expanded.add(key);
      modalState.seen.add(key);
      refreshDocTree();
      return;
    }
    const key = ch.dataset.key, slug = ch.dataset.slug;
    if (key === (modalState.activeDoc || '')) {
      const h = document.getElementById('section-' + slug);
      if (h) h.scrollIntoView({ behavior: 'smooth', block: 'start' });
      else modalState.pendingScroll = slug;   // the rows come from the background read, so the doc may still be rendering: jump when it has
      return;
    }
    const t = state.tickets.find(x => x.id === state.selectedId);
    if (t) activateDoc(t, key || null, slug);
  });

  (function initEditorCard() {
    const ta = document.getElementById('m-edit-area');
    const gut = document.getElementById('m-gutter');
    ta.addEventListener('input', refreshEditorGutter);
    ta.addEventListener('scroll', () => { gut.scrollTop = ta.scrollTop; });
    if (window.ResizeObserver) new ResizeObserver(refreshEditorGutter).observe(ta);
    document.getElementById('btn-editor-lines').addEventListener('click', () => {
      try { localStorage.setItem(EDITOR_LINES_KEY, editorLinesOn() ? '0' : '1'); } catch {}
      refreshEditorGutter();
      ta.focus();
    });
    // Image button: same upload path as paste (uploadVisual), with a marker while the upload is in flight.
    document.getElementById('m-image-input').addEventListener('change', async e => {
      const file = e.target.files && e.target.files[0];
      e.target.value = '';
      const t = state.tickets.find(x => x.id === state.selectedId);
      if (!file || !t) return;
      const ext = PASTE_IMAGE_EXT[file.type];
      if (!ext) { insertPlainText(ta, '![unsupported image type]()'); return; }
      const index = nextPasteVisualIndex();
      const name = file.name.replace(/\.[^.]+$/, '').replace(/[^A-Za-z0-9._ -]+/g, '').trim() || `image-${index}`;
      await uploadImageIntoEditor(ta, t.id, file, `image-${index}.${ext}`, name, '![upload failed]()');
    });
  })();

  document.getElementById('modal-overlay').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeModal();
  });
  document.getElementById('btn-close').addEventListener('click', () => {
    if (modalState.editMode) {
      const t = state.tickets.find(t => t.id === state.selectedId);
      if (t) exitEditMode(t);
    } else {
      closeModal();
    }
  });
  document.getElementById('m-editor-toolbar').addEventListener('click', e => {
    const button = e.target.closest('[data-insert]');
    if (!button) return;
    if (button.dataset.insert === 'image') { document.getElementById('m-image-input').click(); return; }
    insertEditorSnippet(button.dataset.insert);
  });
  document.getElementById('c-editor-toolbar').addEventListener('click', e => {
    const button = e.target.closest('[data-insert]');
    if (!button) return;
    insertEditorSnippet(button.dataset.insert, document.getElementById('c-body'));
  });
  document.getElementById('m-edit-area').addEventListener('keydown', e => {
    handleTabIndent(e, e.currentTarget);
    handleMarkdownEnter(e, e.currentTarget);
  });
  document.getElementById('m-edit-area').addEventListener('paste', async e => {
    const images = readClipboardImages(e);
    if (!images.length) return;
    e.preventDefault();
    const t = state.tickets.find(tk => tk.id === state.selectedId);
    if (!t) return;
    const editEl = e.currentTarget;
    for (const img of images) {
      const index = nextPasteVisualIndex();
      await uploadImageIntoEditor(editEl, t.id, img.blob, `pasted-${index}.${img.ext}`, `pasted-${index}`, '![paste failed]()');
    }
  });
  document.getElementById('c-body').addEventListener('keydown', e => {
    handleTabIndent(e, e.currentTarget);
    handleMarkdownEnter(e, e.currentTarget);
  });

  (function initSidebar() {
    const sidebar      = document.getElementById('sidebar');
    const toggle       = document.getElementById('sidebar-toggle');
    const handle       = document.getElementById('sidebar-resize');
    const W_KEY        = 'sprint-check-sidebar-w';
    // t-9d93: remembered per project; a project with no saved choice starts collapsed.
    const C_KEY        = 'sprint-check-sidebar-collapsed:' + (new URLSearchParams(location.search).get('project') || '');
    const MIN_W = 160, MAX_W = 480, DEFAULT_W = 240;

    let width     = parseInt(localStorage.getItem(W_KEY) || DEFAULT_W);
    let collapsed = localStorage.getItem(C_KEY) !== 'false';

    function applyState(animate) {
      if (!animate) sidebar.style.transition = 'none';
      if (collapsed) {
        sidebar.classList.add('collapsed');
        sidebar.style.width = '44px';
        handle.style.display = 'none';
      } else {
        sidebar.classList.remove('collapsed');
        sidebar.style.width = width + 'px';
        handle.style.display = '';
      }
      if (!animate) requestAnimationFrame(() => { sidebar.style.transition = ''; });
    }

    function expandAndScrollTo(sectionId) {
      if (collapsed) {
        collapsed = false;
        localStorage.setItem(C_KEY, false);
        applyState(true);
      }
      const target = document.getElementById(sectionId);
      if (target) {
        setTimeout(() => target.scrollIntoView({ behavior: 'smooth', block: 'start' }), 220);
      }
    }

    toggle.addEventListener('click', () => {
      collapsed = !collapsed;
      localStorage.setItem(C_KEY, collapsed);
      applyState(true);
    });

    document.querySelectorAll('.rail-icon').forEach(icon => {
      icon.addEventListener('click', () => expandAndScrollTo(icon.dataset.section));
    });

    // Drag-to-resize
    let dragging = false, startX = 0, startW = 0;

    handle.addEventListener('mousedown', e => {
      dragging = true; startX = e.clientX;
      startW = sidebar.getBoundingClientRect().width;
      handle.classList.add('dragging');
      document.body.style.cursor = 'col-resize';
      document.body.style.userSelect = 'none';
      e.preventDefault();
    });

    document.addEventListener('mousemove', e => {
      if (!dragging) return;
      width = Math.min(MAX_W, Math.max(MIN_W, startW + (e.clientX - startX)));
      sidebar.style.width = width + 'px';
    });

    document.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      handle.classList.remove('dragging');
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      localStorage.setItem(W_KEY, width);
    });

    applyState(false);
  })();

  (function initBoardSearch() {
    const input = document.getElementById('board-search');
    const clear = document.getElementById('board-search-clear');
    const shell = document.getElementById('board-search-shell');
    const modeButtons = document.querySelectorAll('.search-mode-btn');
    if (!input || !clear || !shell) return;
    let whyTimer = null;
    let whyRequest = 0;

    function setMode(mode) {
      state.queryMode = mode;
      modeButtons.forEach(btn => {
        const active = btn.dataset.mode === mode;
        btn.classList.toggle('active', active);
        btn.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
      // placeholder is now managed by the search-tips system (startTips/showTip)
      input.setAttribute('aria-label', mode === 'why' ? 'Find ticket history for a file' : 'Search tickets');
      renderBoard();
    }

    async function runWhy(value) {
      const file = whyQueryFromInput(value);
      clearTimeout(whyTimer);
      if (state.queryMode !== 'why' || !file) {
        state.why = null;
        renderBoard();
        return;
      }
      const requestId = ++whyRequest;
      state.why = { file, loading: true, results: [], message: '' };
      renderBoard();
      try {
        const data = await fetch(`/api/why?file=${encodeURIComponent(file)}`).then(r => r.json());
        if (requestId !== whyRequest) return;
        state.why = data;
      } catch {
        if (requestId !== whyRequest) return;
        state.why = { file, error: 'Could not load file history.', results: [] };
      }
      renderBoard();
    }

    function scheduleWhy(value) {
      clearTimeout(whyTimer);
      whyTimer = setTimeout(() => runWhy(value), 250);
    }

    function apply(value) {
      const shortcut = String(value).match(/^why(?::|\s+)(.+)$/i);
      if (shortcut) {
        setMode('why');
        value = shortcut[1];
      }
      state.query = value;
      input.value = value;
      shell.classList.toggle('has-query', Boolean(value.trim()));
      if (state.queryMode === 'why') scheduleWhy(value);
      else state.why = null;
      renderBoard();
    }

    input.addEventListener('input', () => apply(input.value));
    input.addEventListener('keydown', e => {
      if (e.key === 'Escape' && input.value) {
        e.stopPropagation();
        apply('');
      }
    });
    modeButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        setMode(btn.dataset.mode);
        if (state.queryMode === 'why') scheduleWhy(input.value);
        else state.why = null;
        renderBoard();
        input.focus();
      });
    });
    clear.addEventListener('click', () => {
      apply('');
      input.focus();
    });

    // ── Search tips: rotating hints with AI sparkle ──────────────────────────
    const SEARCH_TIPS = [
      { query: 'is:ci', hint: 'Find CI-graded tickets' },
      { query: 'is:override', hint: 'Closed via human override' },
      { query: 'ready', hint: 'Ready to close' },
      { query: 'incomplete', hint: 'Missing acceptance or plan items' },
      { query: 'unchecked', hint: 'Has unchecked items' },
      { query: 'haiku', hint: 'Gates ran on haiku' },
      { query: 'bug', hint: 'Bug tickets' },
      { query: 'p0', hint: 'Critical priority' },
    ];
    const WHY_TIPS = [
      { query: 'src/app.js', hint: 'Why was this file built this way?' },
      { query: 'tools/sprint', hint: 'Decisions behind a tool' },
      { query: 'README.md', hint: 'What shaped the README?' },
      { query: 'standards/efficiency.md', hint: 'History of a standard' },
    ];

    const sparkle = document.getElementById('search-sparkle');
    let tipIndex = 0;
    let tipInterval = null;
    let currentTip = null;

    function getTips() {
      return state.queryMode === 'why' ? WHY_TIPS : SEARCH_TIPS;
    }

    function showTip() {
      const tips = getTips();
      if (!tips.length) return;
      tipIndex = tipIndex % tips.length;
      currentTip = tips[tipIndex];
      input.placeholder = `${currentTip.query}  \u2014  ${currentTip.hint}`;
      tipIndex++;
    }

    function startTips() {
      if (tipInterval) return;
      showTip();
      tipInterval = setInterval(showTip, 2500);
      sparkle.style.opacity = '';
    }

    function stopTips() {
      if (tipInterval) { clearInterval(tipInterval); tipInterval = null; }
      currentTip = null;
      input.placeholder = '';
      sparkle.style.opacity = '0';
    }

    // Click in search = "I want this tip" → pre-fill, stop animation
    // Click outside (blur) = restart tips if input wasn't used
    let suppressPrefill = false;
    const enterHint = document.getElementById('search-enter-hint');
    function prefillTip() {
      if (suppressPrefill) { suppressPrefill = false; return; }
      if (!input.value && currentTip) {
        input.value = currentTip.query;
        input.select();
        stopTips();
        shell.classList.add('has-query');
        enterHint.classList.add('visible');
      }
    }
    function hideEnterHint() { enterHint.classList.remove('visible'); }
    input.addEventListener('click', prefillTip);
    input.addEventListener('blur', () => {
      setTimeout(() => {
        if (!document.activeElement || document.activeElement !== input) {
          hideEnterHint();
          if (input.value && currentTip === null) {
            const normalized = normalizeSearch(input.value);
            const isTipQuery = getTips().some(t => normalizeSearch(t.query) === normalized);
            if (isTipQuery && !state.query) {
              input.value = '';
              shell.classList.remove('has-query');
              startTips();
            }
          } else if (!input.value) {
            startTips();
          }
        }
      }, 100);
    });

    // Enter confirms a pre-filled or typed query
    input.addEventListener('keydown', e => {
      if (e.key === 'Enter' && input.value) {
        hideEnterHint();
        apply(input.value);
      }
    });

    input.addEventListener('input', () => {
      hideEnterHint();
      if (input.value) {
        stopTips();
      } else {
        startTips();
      }
    });

    clear.addEventListener('click', () => {
      setTimeout(() => { if (!input.value) startTips(); }, 0);
    });

    modeButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        tipIndex = 0;
        stopTips();
        input.value = '';
        shell.classList.remove('has-query');
        suppressPrefill = true;
        apply('');
        startTips();
      });
    });

    input.addEventListener('keydown', e => {
      if (e.key === 'Escape' && !input.value) {
        setTimeout(() => startTips(), 0);
      }
    });

    setMode('search');
    startTips();
  })();

  (function initTour() {
    const overlay = document.getElementById('tour-overlay');
    const open  = () => overlay.classList.add('open');
    const close = () => overlay.classList.remove('open');
    document.getElementById('tour-btn').addEventListener('click', open);
    document.getElementById('tour-close').addEventListener('click', close);
    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
    document.addEventListener('keydown', e => { if (e.key === 'Escape' && overlay.classList.contains('open')) close(); });
  })();

  (function initTheme() {
    const btn  = document.getElementById('theme-toggle');
    const html = document.documentElement;
    const stored = localStorage.getItem('sprint-check-theme');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    // t-a55a: when embedded in a Cockpit tab, honor the shell-passed ?theme so the
    // board matches the Cockpit's theme (the shell uses its own key/param).
    const urlTheme = new URLSearchParams(location.search).get('theme');
    const isDark = urlTheme ? (urlTheme !== 'light') : (stored ? stored === 'dark' : prefersDark);

    function apply(dark) {
      if (dark) {
        html.removeAttribute('data-theme');
        btn.textContent = '🌙';
      } else {
        html.setAttribute('data-theme', 'light');
        btn.textContent = '☀️';
      }
      localStorage.setItem('sprint-check-theme', dark ? 'dark' : 'light');
    }

    apply(isDark);
    btn.addEventListener('click', () => apply(html.getAttribute('data-theme') === 'light'));
    // Let the Cockpit shell push live theme changes into this iframe.
    window.addEventListener('message', (e) => {
      if (e.data && e.data.type === 'canon-theme' && (e.data.theme === 'dark' || e.data.theme === 'light')) {
        apply(e.data.theme === 'dark');
      }
    });
  })();

  // Set up CI gate — one click writes .github/workflows/canon-gate.yml (refuse-on-exists).
  document.getElementById('btn-ci-setup')?.addEventListener('click', async () => {
    try {
      const res = await fetch('/api/ci-workflow', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
      }).then(r => r.json());
      if (res.ok) {
        showToast('✓ Wrote ' + res.path + ' — add an ANTHROPIC_API_KEY secret + push to enable PR grading', 'warn');
      } else if (res.reason === 'exists') {
        showToast('⚠ ' + res.path + ' already exists — delete it to regenerate', 'block');
      } else {
        showToast('⚠ Could not write CI workflow: ' + (res.reason || 'unknown error'), 'block');
      }
    } catch (e) {
      showToast('⚠ Could not reach the server to set up CI', 'block');
    }
  });

  loadData();
  fetchVersion();
  setInterval(loadData, 8000);
}

