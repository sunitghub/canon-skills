// t-c6bb: the base dialog. A new dialog starts here and gets, with no wiring of its own, what the ticket, create, commit and GitHub
// dialogs each set up by hand: an overlay that opens and closes (Esc, a click outside, the close button, focus back to where it came
// from) and a panel that moves by its header and resizes from its corner, back at its start place and size on every open. The
// drag and resize engine is board-panels.js's (one copy); the look is board-dialog.css (.dlg-overlay / .dlg-panel).
// Markup: an overlay holding a panel, the panel holding a `.modal-header` (the drag handle). The two resize corners (top-left and
// bottom-right, as the ticket and create dialogs have them) are added here unless the panel brings its own.
import { makePanelDraggable, makePanelResizable, resetPanelDrag, resetPanelResize } from './board-panels.js';

// t-cca5: the panel half on its own, for a dialog that keeps its own open/close code (ticket, create, commit, GitHub): it moves by
// `handle` and, unless `resizable` is false, resizes from its corner. The caller resets position and size on its own open.
export function initDialogPanel({ panelId, handle = '.modal-header', resizable = true }) {
  makePanelDraggable(panelId, handle);
  if (resizable) makePanelResizable(panelId);
}

export function initDialog({ overlayId, panelId, closeId, fallbackFocusId, onOpen, onClose }) {
  const overlay = document.getElementById(overlayId);
  const panel = document.getElementById(panelId);
  let returnTo = null;
  const isOpen = () => overlay.classList.contains('open');

  if (!panel.querySelector('.modal-resize-handle')) {
    for (const [cls, label] of [['modal-resize-handle modal-resize-handle-tl', 'Resize dialog from the top-left'], ['modal-resize-handle', 'Resize dialog']]) {
      const g = document.createElement('div');
      g.className = cls;
      g.title = label;
      g.setAttribute('aria-label', label);
      panel.appendChild(g);
    }
  }
  initDialogPanel({ panelId });

  function open() {
    if (isOpen()) return;
    returnTo = document.activeElement && document.activeElement !== document.body ? document.activeElement : document.getElementById(fallbackFocusId);
    resetPanelDrag(panel);
    resetPanelResize(panel);
    overlay.classList.add('open');
    overlay.setAttribute('aria-hidden', 'false');
    if (onOpen) onOpen();
  }

  function close() {
    if (!isOpen()) return;
    overlay.classList.remove('open');
    overlay.setAttribute('aria-hidden', 'true');
    if (onClose) onClose();
    const back = returnTo && document.contains(returnTo) ? returnTo : document.getElementById(fallbackFocusId);
    returnTo = null;
    if (back) back.focus();
  }

  if (closeId) document.getElementById(closeId).addEventListener('click', close);
  // a click outside closes it, but a selection dragged from the panel out onto the overlay (the pointer went down inside) does not
  let downOutside = false;
  overlay.addEventListener('pointerdown', e => { downOutside = e.target === overlay; });
  overlay.addEventListener('click', e => { if (e.target === overlay && downOutside) close(); downOutside = false; });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && isOpen()) { e.preventDefault(); close(); } });
  return { open, close };
}
