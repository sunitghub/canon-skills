#!/usr/bin/env node
// split-handle-unit — t-ccf5. Protects the Cockpit's split view and the board's Terminal pane, which share static/split-handle.js: the
// ratio clamp (each pane keeps its minimum), the stored-ratio check (a bad stored value never reaches a layout) and the handle's
// drag, double-click and arrow keys. The handle runs here against a fake element. Usage: node tests/split-handle-unit.js
const assert = require('assert');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  const { clampRatio, validRatio, bindSplitHandle } = await import(pathToFileURL(path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static', 'split-handle.js')).href);

  // clampRatio(r, total, min): each pane keeps min + 3px; a container too small for two panes answers .5
  assert.strictEqual(clampRatio(.5, 1000, 220), .5);
  assert.strictEqual(clampRatio(.01, 1000, 220), 223 / 1000);                // never below the first pane's minimum
  assert.strictEqual(clampRatio(.99, 1000, 220), 1 - 223 / 1000);            // nor above, so the second pane keeps its minimum
  assert.strictEqual(clampRatio(.3, 1000, 220), .3);                         // inside the limits it is unchanged
  assert.strictEqual(clampRatio(.1, 446, 220), .5);                          // total == 2*edge: no room, so .5
  assert.strictEqual(clampRatio(.1, 447, 220) > .49, true);                  // one px more than 2*edge: clamped, not .5-ed
  assert.strictEqual(clampRatio(.2, 300, 220), .5);

  // validRatio: a number strictly between .05 and .95, else .5
  for (const bad of ['x', null, undefined, NaN, 0, .05, .95, 1, 2, -1, [], {}, '0.4']) assert.strictEqual(validRatio(bad), .5, String(bad));
  assert.strictEqual(validRatio(.06), .06); assert.strictEqual(validRatio(.94), .94); assert.strictEqual(validRatio(.5), .5);

  // bindSplitHandle against a fake handle
  const mk = () => {
    const h = { on: {}, cls: new Set(), captured: null };
    h.addEventListener = (t, fn) => { h.on[t] = fn; };
    h.classList = { add: c => h.cls.add(c), remove: c => h.cls.delete(c) };
    h.setPointerCapture = id => { h.captured = id; };
    return h;
  };
  const owner = (dirv, active) => {
    const o = { ratio: .5, saved: 0, active: () => active.v, dir: () => dirv, box: () => ({ left: 100, top: 50, width: 1000, height: 600 }), get: () => o.ratio,
      set: r => { o.ratio = r; }, done: () => { o.saved++; } };
    return o;
  };
  const key = (h, k, shift) => { let pd = false; h.on.keydown({ key: k, shiftKey: !!shift, preventDefault: () => { pd = true; } }); return pd; };

  { // beside (h): the pointer's x decides; the owner is told on release
    const h = mk(), act = { v: true }, o = owner('h', act); bindSplitHandle(h, o);
    h.on.pointerdown({ pointerId: 7, preventDefault() {} });
    assert.strictEqual(h.captured, 7); assert.ok(h.cls.has('drag'));
    h.on.pointermove({ clientX: 600, clientY: 0 }); assert.strictEqual(o.ratio, .5);        // (600-100)/1000
    h.on.pointermove({ clientX: 300, clientY: 999 }); assert.strictEqual(o.ratio, .2);      // y is ignored when side by side
    assert.strictEqual(o.saved, 0);
    h.on.pointerup(); assert.ok(!h.cls.has('drag')); assert.strictEqual(o.saved, 1);
    h.on.pointerup(); assert.strictEqual(o.saved, 1);                                       // a release with no drag saves nothing
    h.on.pointermove({ clientX: 900, clientY: 0 }); assert.strictEqual(o.ratio, .2);        // and a move after it moves nothing
  }
  { // stacked (v): the pointer's y decides
    const h = mk(), act = { v: true }, o = owner('v', act); bindSplitHandle(h, o);
    h.on.pointerdown({ pointerId: 1, preventDefault() {} });
    h.on.pointermove({ clientX: 0, clientY: 350 }); assert.strictEqual(o.ratio, .5);        // (350-50)/600
    h.on.pointercancel(); assert.strictEqual(o.saved, 1);
  }
  { // an inactive split ignores the pointer, double-click and keys
    const h = mk(), act = { v: false }, o = owner('h', act); bindSplitHandle(h, o);
    h.on.pointerdown({ pointerId: 1, preventDefault() {} }); h.on.pointermove({ clientX: 900, clientY: 0 });
    assert.strictEqual(o.ratio, .5);
    h.on.dblclick(); assert.strictEqual(o.saved, 0);
    assert.strictEqual(key(h, 'ArrowRight'), false); assert.strictEqual(o.ratio, .5);
  }
  { // keys: arrows nudge by .02 (.1 with Shift) in the split's own direction, Home resets, others are left alone
    const h = mk(), act = { v: true }, o = owner('h', act); bindSplitHandle(h, o);
    assert.strictEqual(key(h, 'ArrowRight'), true); assert.strictEqual(+o.ratio.toFixed(2), .52);
    assert.strictEqual(key(h, 'ArrowLeft', true), true); assert.strictEqual(+o.ratio.toFixed(2), .42);
    assert.strictEqual(key(h, 'ArrowDown'), false); assert.strictEqual(+o.ratio.toFixed(2), .42);   // the wrong axis does nothing
    assert.strictEqual(key(h, 'Home'), true); assert.strictEqual(o.ratio, .5);
    assert.strictEqual(key(h, 'a'), false);
    assert.strictEqual(o.saved, 3);                                                            // one save per handled key
    o.ratio = .9; h.on.dblclick(); assert.strictEqual(o.ratio, .5); assert.strictEqual(o.saved, 4);
    const hv = mk(), ov = owner('v', act); bindSplitHandle(hv, ov);
    assert.strictEqual(key(hv, 'ArrowDown'), true); assert.strictEqual(+ov.ratio.toFixed(2), .52);
    assert.strictEqual(key(hv, 'ArrowUp'), true); assert.strictEqual(+ov.ratio.toFixed(2), .5);
    assert.strictEqual(key(hv, 'ArrowLeft'), false);
  }
  console.log('split-handle-unit: ok (clamp, stored-ratio check, drag, double-click and keys, both directions)');
})().catch(e => { console.error(e); process.exit(1); });
