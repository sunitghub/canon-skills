#!/usr/bin/env node
// sprint-check-esc — the board's esc()/escAttr() are safe in text AND inside a quoted attribute (t-d2e1). Loads the
// REAL functions out of the board's modules (tests/board-script.js). The shell's esc() (static/cockpit-core.js) builds
// on the DOM, so the Playwright spec checks it in the page with the same cases.
const { loadBoard } = require('./board-script');

const { esc, escAttr } = loadBoard();
let fails = 0;
function ok(name, cond, detail) {
  if (cond) console.log('  ok   ' + name);
  else { fails++; console.log('  FAIL ' + name + (detail !== undefined ? '  => ' + JSON.stringify(detail) : '')); }
}

ok('esc and escAttr loaded from the board modules', typeof esc === 'function' && typeof escAttr === 'function');
ok('the five HTML-special characters become entities', esc(`&<>"'`) === '&amp;&lt;&gt;&quot;&#39;', esc(`&<>"'`));
ok('escAttr returns what esc returns', escAttr(`a"onmouseover="x' & <b>`) === esc(`a"onmouseover="x' & <b>`));
ok('the quote-breakout payload stays inside its attribute', !/"/.test(esc('a"onmouseover="x')), esc('a"onmouseover="x'));
ok('null and undefined render as empty', esc(null) === '' && esc(undefined) === '');

// Decoding is written independently of esc(): one pass over exactly the five entities esc() may produce.
const ENT = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" };
const decode = s => s.replace(/&amp;|&lt;|&gt;|&quot;|&#39;/g, m => ENT[m]);

// Fuzz: 500 strings from a seeded generator (reproducible), mixing the special characters, unicode, control
// characters, entity-looking text, empty and long strings.
let seed = 0x2d1e;
const rnd = n => { seed = (seed * 1103515245 + 12345) >>> 0; return seed % n; };
const POOL = ['&', '<', '>', '"', "'", '&amp;', '&quot;', 'a', 'Z', '0', ' ', '\n', '\r', '\t', '\u0000', 'é', ' ', '😀', '=', '/', '`', '\\'];
const bad = [];
for (let i = 0; i < 500; i++) {
  const len = i === 0 ? 0 : i === 1 ? 5000 : rnd(40);
  let s = '';
  for (let j = 0; j < len; j++) s += POOL[rnd(POOL.length)];
  const out = esc(s);
  if (/["'<>]/.test(out) || decode(out) !== s) bad.push(JSON.stringify(s).slice(0, 60));
}
ok('fuzz: 500 strings escape with no raw " \' < > and decode back exactly', bad.length === 0, bad.slice(0, 3));

if (fails) { console.log(`sprint-check-esc: ${fails} failing`); process.exit(1); }
console.log('sprint-check-esc: ok (esc/escAttr attribute-safe; 500-string fuzz)');
