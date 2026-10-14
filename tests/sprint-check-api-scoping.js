#!/usr/bin/env node
// sprint-check-api-scoping (t-3c65) — every /api/ path the board fetches must be
// Cockpit-scoped (matches the fetch wrapper's READ_RE or WRITE_RE) or sit on the
// explicit UNSCOPED list below. A route missing from both silently hits the board's
// DEFAULT project inside a Cockpit tab (t-d254: ticket-commit/ did, live-caught).
// READ_RE/WRITE_RE are read out of the board's own code, never copied here. A path counts
// as scoped if it matches either regex; the HTTP method is not checked.
// SPRINT_CHECK_APP_HTML overrides the file under test (revert checks on a scratch copy).
const fs = require('fs');
const { APP_HTML, boardScripts } = require('./board-script');

const APP = process.env.SPRINT_CHECK_APP_HTML || APP_HTML;
// t-c58e, t-1543: the markup plus every board module (the entry and all it imports), so a path moved out of app.html still counts.
const html = [fs.readFileSync(APP, 'utf8'), ...boardScripts(APP).map((s) => s.source)].join('\n');

// Unscoped by design: path (after ${...} -> X) -> why it must NOT carry ?project.
// A key matches the path exactly or as a `<key>/...` prefix.
const UNSCOPED = {
  '/api/cockpit': 'the one shared daemon, not per-project',
  '/api/cockpit-sessions': 'lists sessions across ALL projects (t-391a)',
  '/api/cockpit-docs': 'resolves its project from the explicit ?cwd',
  '/api/version': 'install-wide build info',
  '/api/ci-workflow': 'install-wide CI workflow toggle',
  '/api/admin/model-tiers': 'install-wide model registry',
  '/api/ticket/X/headless-run': 'headless run state lives with the daemon, not a project root',
  '/api/ticket-image': 'only an <img src>; resolveMockupSrc scopes it itself (t-7d83)',
  '/api/themes': 'install-wide user themes folder, $CANON_HOME/themes (t-f889)',
};

let fails = 0;
const fail = (msg) => { console.error('FAIL: ' + msg); fails++; };

const regexFor = (name) => {
  const m = html.match(new RegExp('const ' + name + ' = (/.*/);'));
  if (!m) { fail(name + ' not found in the board code'); return null; }
  return new Function('return ' + m[1])();
};
const READ_RE = regexFor('READ_RE');
const WRITE_RE = regexFor('WRITE_RE');

const paths = new Set();
for (const line of html.split('\n')) {
  if (/^\s*(\/\/|\*|<!--)/.test(line)) continue;
  for (const m of line.matchAll(/['"`](\/api\/[^'"`\s?]*)/g)) {
    paths.add(m[1].replace(/\$\{[^}]*\}/g, 'X'));
  }
}

if (paths.size < 15) fail('extracted only ' + paths.size + ' distinct /api/ paths (expected >= 15) — the extractor is broken');

const covers = (key, p) => p === key || p.startsWith(key + '/');
if (READ_RE && WRITE_RE) {
  const scoped = (p) => READ_RE.test(p) || WRITE_RE.test(p);
  for (const p of [...paths].sort()) {
    if (!Object.keys(UNSCOPED).some((k) => covers(k, p)) && !scoped(p)) fail(p + ' is neither in READ_RE/WRITE_RE nor UNSCOPED — a Cockpit tab would hit the default project');
  }
  for (const p of Object.keys(UNSCOPED)) {
    if (![...paths].some((q) => covers(p, q))) fail('UNSCOPED entry ' + p + ' is no longer referenced by the board code — remove it');
    if ([...paths].some((q) => covers(p, q) && scoped(q))) fail('UNSCOPED entry ' + p + ' also matches READ_RE/WRITE_RE — it is scoped, not unscoped');
  }
}

if (fails) process.exit(1);
console.log('sprint-check-api-scoping: ok (' + paths.size + ' /api/ paths, ' + Object.keys(UNSCOPED).length + ' unscoped by design)');
