#!/usr/bin/env node
// busy-unit — t-ae96. Protects static/busy.js, the one busy-button helper every async button on the board and the shell uses
// (Factory's Check again, the card's Refresh, + skill, Turn on history, the board's commit and worktree-create): the button is busy
// (label, disabled, aria-busy) while the action runs and is put back exactly as it was after a success, a throw and a rejected
// promise; the action's result is returned; two overlapping calls restore once, when the last finishes; a button that was disabled
// stays disabled. The button here is a fake with the few members the helper uses. Usage: node tests/busy-unit.js
const assert = require('assert');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  global.document = { createTextNode: t => ({ text: String(t) }) };
  const { withBusy } = await import(pathToFileURL(path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static', 'busy.js')).href);
  const fakeBtn = (disabled = false) => {
    const icon = { icon: true }, label = { text: 'Check again' };
    return { icon, label, childNodes: [icon, label], disabled, attrs: {},
      replaceChildren(...n) { this.childNodes = n; }, setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; } };
  };
  const text = b => b.childNodes.map(n => (n.icon ? '<icon>' : n.text)).join('');

  // busy while it runs, put back after: the same nodes (an icon is not re-parsed), the result returned
  let b = fakeBtn(), seen;
  const out = await withBusy(b, 'Checking…', async () => { seen = { text: text(b), disabled: b.disabled, busy: b.attrs['aria-busy'] }; return 42; });
  assert.deepStrictEqual(seen, { text: 'Checking…', disabled: true, busy: 'true' });
  assert.strictEqual(out, 42);
  assert.deepStrictEqual(b.childNodes, [b.icon, b.label]); assert.strictEqual(b.disabled, false); assert.strictEqual('aria-busy' in b.attrs, false);

  // a thrown action and a rejected promise restore it too, and the error still reaches the caller
  for (const act of [() => { throw new Error('boom'); }, () => Promise.reject(new Error('boom'))]) {
    b = fakeBtn();
    await assert.rejects(withBusy(b, 'Working…', act), /boom/);
    assert.deepStrictEqual(b.childNodes, [b.icon, b.label]); assert.strictEqual(b.disabled, false); assert.strictEqual('aria-busy' in b.attrs, false);
  }

  // a button that was disabled before stays disabled
  b = fakeBtn(true);
  await withBusy(b, 'x', async () => {});
  assert.strictEqual(b.disabled, true);

  // two overlapping calls: the first to finish leaves it busy, the last restores it (once, with the original nodes)
  b = fakeBtn();
  let r1, r2; const p1 = new Promise(r => { r1 = r; }), p2 = new Promise(r => { r2 = r; });
  const a = withBusy(b, 'one', () => p1), c = withBusy(b, 'two', () => p2);
  assert.strictEqual(text(b), 'one');                                         // the second call does not re-label it
  r1(); await a;
  assert.strictEqual(b.attrs['aria-busy'], 'true'); assert.strictEqual(b.disabled, true);
  r2(); await c;
  assert.deepStrictEqual(b.childNodes, [b.icon, b.label]); assert.strictEqual(b.disabled, false); assert.strictEqual('aria-busy' in b.attrs, false);

  // an empty label shows the spinner alone
  b = fakeBtn();
  await withBusy(b, '', async () => { assert.strictEqual(text(b), ''); });
  console.log('busy-unit: ok');
})().catch(e => { console.error(e); process.exit(1); });
