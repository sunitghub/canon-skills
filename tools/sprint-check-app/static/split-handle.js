// t-ccf5: the split handle's rules, shared by the Cockpit shell's project split (cockpit-tabs.js) and the board's Terminal pane
// (board-pane.js), so the two never drift: the ratio clamp, the stored-ratio check, and one handle binder (drag, arrow keys, Home,
// double-click). Imports nothing. `min` is the smallest a pane may get, in px, before the 3px half-handle.

export function clampRatio(r, total, min) {
  const edge = min + 3;
  if (!(total > 2 * edge)) return .5;
  return Math.min(1 - edge / total, Math.max(edge / total, r));
}

// A stored ratio is accepted only as a number strictly between .05 and .95; anything else (a string, NaN, 0, 2) is .5.
export function validRatio(r) { return (typeof r === 'number' && r > .05 && r < .95) ? r : .5; }

// o: active() -> bool; dir() -> 'h' (side by side) | 'v' (stacked); box() -> the container's rect; get() -> ratio;
//    set(r) -> take and apply a ratio (the owner clamps); done() -> save.
export function bindSplitHandle(handle, o) {
  let dragging = false;
  const at = e => { const r = o.box(); return o.dir() === 'v' ? (e.clientY - r.top) / r.height : (e.clientX - r.left) / r.width; };
  handle.addEventListener('pointerdown', e => {
    dragging = true; handle.classList.add('drag');
    try { handle.setPointerCapture(e.pointerId); } catch (err) {}
    e.preventDefault();
  });
  handle.addEventListener('pointermove', e => { if (dragging && o.active()) o.set(at(e)); });
  const stop = () => { if (!dragging) return; dragging = false; handle.classList.remove('drag'); o.done(); };
  handle.addEventListener('pointerup', stop);
  handle.addEventListener('pointercancel', stop);
  handle.addEventListener('dblclick', () => { if (!o.active()) return; o.set(.5); o.done(); });
  handle.addEventListener('keydown', e => {
    if (!o.active()) return;
    const step = e.shiftKey ? .1 : .02, back = o.dir() === 'v' ? 'ArrowUp' : 'ArrowLeft', fwd = o.dir() === 'v' ? 'ArrowDown' : 'ArrowRight';
    if (e.key === back || e.key === fwd) { e.preventDefault(); o.set(o.get() + (e.key === fwd ? step : -step)); }
    else if (e.key === 'Home') { e.preventDefault(); o.set(.5); }
    else return;
    o.done();
  });
}
