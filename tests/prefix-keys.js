#!/usr/bin/env node
// prefix-keys — unit coverage for the cockpit keyboard prefix (t-a198). Loads the REAL snippet between the
// canon:prefix-keys markers out of the shell page (the other two frames carry a byte-identical copy, pinned by
// prefix-keys-parity.sh) and drives it with plain event objects, so no browser is needed.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'tools', 'sprint-check-app', 'cockpit.html'), 'utf8');
const a = html.indexOf('// canon:prefix-keys:begin');
const b = html.indexOf('// canon:prefix-keys:end');
if (a < 0 || b < 0) { console.log('FAIL: snippet markers not found in cockpit.html'); process.exit(1); }
const snippet = html.slice(a, b);

let fails = 0;
function ok(name, cond, detail) {
  if (cond) console.log('  ok   ' + name);
  else { fails++; console.log('  FAIL ' + name + (detail !== undefined ? '  => ' + JSON.stringify(detail) : '')); }
}

function load(stored) {
  const timers = [];
  const sandbox = {
    localStorage: { getItem: (k) => (k === 'canon-prefix' && stored !== undefined ? stored : null) },
    setTimeout: (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length; },
    clearTimeout: (id) => { if (timers[id - 1]) timers[id - 1].live = false; },
  };
  vm.createContext(sandbox);
  vm.runInContext(snippet, sandbox);
  return { ctx: sandbox, timers };
}
function ev(type, key, o) {
  o = o || {};
  const e = { type, key, code: o.code || 'Key' + key, ctrlKey: !!o.ctrl, altKey: !!o.alt, metaKey: !!o.meta, shiftKey: !!o.shift,
    repeat: !!o.repeat, isComposing: false, prevented: 0, stopped: 0,
    preventDefault() { this.prevented++; }, stopPropagation() { this.stopped++; },
    getModifierState: (m) => m === 'AltGraph' && !!o.altgr };
  return e;
}
// one physical keypress: keydown, keypress, keyup — returns what a consumer (xterm) would have seen as "not handled"
function press(h, key, o) {
  const seen = [];
  for (const t of ['keydown', 'keypress', 'keyup']) { const e = ev(t, key, o); if (!h.handle(e)) seen.push(t); }
  return seen;
}

// ── default prefix ctrl+. ──
{
  const { ctx, timers } = load(undefined);
  ok('default label is ctrl+.', ctx.canonPrefixLabel() === 'ctrl+.');
  const out = []; const h = ctx.canonPrefixKeys((t, k) => out.push([t, k]));
  const dn = ev('keydown', '.', { ctrl: true, code: 'Period' });
  ok('ctrl+. is consumed and arms', h.handle(dn) === true && dn.prevented === 1 && dn.stopped === 1 && out.length === 1 && out[0][0] === 'armed', out);
  ok('its keypress and keyup are swallowed too (nothing leaks to a terminal)', h.handle(ev('keypress', '.', { code: 'Period' })) === true && h.handle(ev('keyup', '.', { code: 'Period' })) === true);
  const seen = press(h, '2', { code: 'Digit2' });
  ok('the next key is consumed whole (keydown, keypress, keyup)', seen.length === 0 && out.length === 2 && out[1][0] === 'key' && out[1][1] === '2', { seen, out });
  ok('after that the handler is idle: a plain key passes through', press(h, 'a').length === 3);
  ok('the 1.5 s timer was set and cleared', timers.length === 1 && timers[0].ms === 1500 && timers[0].live === false);
}
// ── Escape, timeout, unbound key ──
{
  const { ctx, timers } = load(undefined); const out = []; const h = ctx.canonPrefixKeys((t, k) => out.push(t + ':' + k));
  h.handle(ev('keydown', '.', { ctrl: true, code: 'Period' })); h.handle(ev('keyup', '.', { code: 'Period' }));
  ok('Escape cancels and is consumed', h.handle(ev('keydown', 'Escape', { code: 'Escape' })) === true && out.join() === 'armed:,cancel:', out);
  h.handle(ev('keydown', '.', { ctrl: true, code: 'Period' })); h.handle(ev('keyup', '.', { code: 'Period' }));
  timers[timers.length - 1].fn();
  ok('the timeout cancels', out[out.length - 1] === 'cancel:', out);
  ok('after the timeout a plain key is not consumed', press(h, 'q').length === 3);
  h.handle(ev('keydown', '.', { ctrl: true, code: 'Period' })); h.handle(ev('keyup', '.', { code: 'Period' }));
  ok('an unbound key is still consumed and reported (the shell ignores it)', h.handle(ev('keydown', 'z', { code: 'KeyZ' })) === true && out[out.length - 1] === 'key:z', out);
  h.handle(ev('keydown', '.', { ctrl: true, code: 'Period' })); h.handle(ev('keyup', '.', { code: 'Period' }));
  ok('a lone modifier press while armed neither cancels nor is consumed', h.handle(ev('keydown', 'Shift', { code: 'ShiftLeft', shift: true })) === false);
  ok('shifted key (?) after the prefix is delivered as ?', h.handle(ev('keydown', '?', { code: 'Slash', shift: true })) === true && out[out.length - 1] === 'key:?', out);
}
// ── hostile: keys that must never be the prefix ──
{
  const { ctx } = load(undefined); const out = []; const h = ctx.canonPrefixKeys((t, k) => out.push(t));
  for (const [name, e] of [
    ['ctrl+c', ev('keydown', 'c', { ctrl: true })], ['ctrl+d', ev('keydown', 'd', { ctrl: true })], ['ctrl+z', ev('keydown', 'z', { ctrl: true })],
    ['ctrl+b', ev('keydown', 'b', { ctrl: true })], ['ctrl+\\', ev('keydown', '\\', { ctrl: true })], ['plain .', ev('keydown', '.', {})],
    ['ctrl+alt+. (AltGr on Windows layouts)', ev('keydown', '.', { ctrl: true, alt: true })],
    ['AltGraph state set', ev('keydown', '.', { ctrl: true, altgr: true })],
    ['meta+ctrl+.', ev('keydown', '.', { ctrl: true, meta: true })], ['ctrl+shift+.', ev('keydown', '.', { ctrl: true, shift: true })],
    ['held ctrl+. (repeat)', ev('keydown', '.', { ctrl: true, repeat: true })],
  ]) ok(name + ' is not consumed', h.handle(e) === false && e.prevented === 0, out);
  const comp = ev('keydown', '.', { ctrl: true }); comp.isComposing = true;
  ok('keys during IME composition are not consumed', h.handle(comp) === false);
  ok('nothing was ever armed', out.length === 0, out);
}
// ── rebinding via localStorage ──
{
  let r = load('ctrl+;'); ok('valid override is used', r.ctx.canonPrefixLabel() === 'ctrl+;');
  let out = []; let h = r.ctx.canonPrefixKeys((t) => out.push(t));
  ok('the overridden chord arms', h.handle(ev('keydown', ';', { ctrl: true, code: 'Semicolon' })) === true && out[0] === 'armed');
  ok('the old default no longer arms', load('ctrl+;').ctx.canonPrefixKeys(() => {}).handle(ev('keydown', '.', { ctrl: true })) === false);
  for (const bad of ['ctrl+c', 'ctrl+C', 'ctrl+', 'ctrl+ab', 'alt+.', 'ctrl+\\', 'ctrl++', 'ctrl+ ', '', 'garbage', 'ctrl+1', 'ctrl+alt+.']) {
    ok('malformed or unsafe override ' + JSON.stringify(bad) + ' falls back to ctrl+.', load(bad).ctx.canonPrefixLabel() === 'ctrl+.', load(bad).ctx.canonPrefixLabel());
  }
  const broken = { localStorage: { getItem() { throw new Error('blocked'); } }, setTimeout() {}, clearTimeout() {} };
  vm.createContext(broken); vm.runInContext(snippet, broken);
  ok('a throwing localStorage falls back to ctrl+.', broken.canonPrefixLabel() === 'ctrl+.');
}
// ── a stale swallow never eats later typing ──
{
  const { ctx } = load(undefined); const h = ctx.canonPrefixKeys(() => {});
  h.handle(ev('keydown', '.', { ctrl: true, code: 'Period' }));      // consumed; its keyup never arrives (focus moved)
  h.handle(ev('keydown', '2', { code: 'Digit2' }));                  // armed -> consumed; swallow = Digit2, keyup lost too
  ok('a later keydown resets the swallow, so typing 2 later is not eaten', press(h, 'a', { code: 'KeyA' }).length === 3 && h.handle(ev('keypress', '2', { code: 'Digit2' })) === false);
}

if (fails) { console.log(`\nprefix-keys: ${fails} FAILED`); process.exit(1); }
console.log('prefix-keys: ok');
