#!/usr/bin/env node
// sprint-check-md (t-43ba) — md() (static/markdown.js), the one renderer for every ticket doc and, through
// upRenderReport, every Upkeep report: _italic_ and > quotes render; an underscore in a code span or a snake_case word
// stays literal. Loads the REAL md() out of the board's modules (tests/board-script.js).
const { loadBoard } = require('./board-script');

const { md } = loadBoard();
let fails = 0;
function ok(name, cond, detail) {
  if (cond) console.log('  ok   ' + name);
  else { fails++; console.log('  FAIL ' + name + (detail !== undefined ? '  => ' + JSON.stringify(detail) : '')); }
}

ok('md loaded from the board modules', typeof md === 'function');
const scope = md('_Scope: whole repo. Generated: 2026-10-21._');
ok('a whole-line _italic_ renders as <em>', scope === '<em>Scope: whole repo. Generated: 2026-10-21.</em>', scope);
const mid = md('see _this_, then');
ok('a mid-line _italic_ renders as <em>', mid === 'see <em>this</em>, then', mid);
const quote = md('> Advisory only — nothing was modified.');
ok('a > line renders as a blockquote', quote === '<blockquote class="doc-quote">Advisory only — nothing was modified.</blockquote>', quote);
const two = md('> one\n> two');
ok('adjacent > lines merge into one blockquote', two === '<blockquote class="doc-quote">one<br>two</blockquote>', two);
const inner = md('> _Scope_ and `a_b_c`');
ok('markup inside a quote renders; an underscore in a code span stays literal',
  inner === '<blockquote class="doc-quote"><em>Scope</em> and <code class="doc-code">a_b_c</code></blockquote>', inner);
const code = md('`_not italic_`');
ok('a code span that is wholly _x_ stays literal', code === '<code class="doc-code">_not italic_</code>', code);
const snake = md('upkeep_runs_json and a_b.png');
ok('snake_case words stay literal', snake === 'upkeep_runs_json and a_b.png', snake);
const gt = md('a > b');
ok('a > that does not start the line is text', gt === 'a &gt; b', gt);

if (fails) { console.log(`sprint-check-md: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-md: ok (_italic_, > quotes, code-span and snake_case underscores literal)');
