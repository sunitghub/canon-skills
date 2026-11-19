#!/usr/bin/env node
// sprint-check-cockpit-pathkey (t-154c) — the Cockpit's worktree path key (board-worktree.js cockpitPathKey), loaded from the REAL board
// scripts (tests/board-script.js). Windows VM 2026-11-19: tkt wrote a land worktree's lock as /c/Users/...; the key never matched git's
// C:/Users/... entry, so the panel named the folder, offered "Switch" for the worktree already in use, and the session started in main.
// Protects the Worktree panel's label, the start request's cwd and the same-worktree pick.
const { loadBoard } = require('./board-script');
const ctx = loadBoard();
let fails = 0;
const ok = (name, cond, detail) => { if (cond) console.log('  ok   ' + name); else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); } };
const { cockpitPathKey } = ctx;
ok('cockpitPathKey loaded from the board scripts', typeof cockpitPathKey === 'function');
const k = cockpitPathKey('C:/Users/agentops/Documents/ToDo-Demo-worktrees/land-t-exiu');
for (const [name, p] of [
  ['Git Bash form (the lock tkt wrote)', '/c/Users/agentops/Documents/ToDo-Demo-worktrees/land-t-exiu'],
  ['native backslashes', 'C:\\Users\\agentops\\Documents\\ToDo-Demo-worktrees\\land-t-exiu'],
  ['lower-case drive', 'c:/users/agentops/documents/todo-demo-worktrees/land-t-exiu'],
  ['a trailing slash', 'C:/Users/agentops/Documents/ToDo-Demo-worktrees/land-t-exiu/'],
  ['doubled separators', 'C://Users//agentops//Documents//ToDo-Demo-worktrees//land-t-exiu'],
]) ok(`one key: ${name}`, cockpitPathKey(p) === k, [cockpitPathKey(p), k]);
ok('another drive is another folder', cockpitPathKey('/d/Users/agentops/Documents/ToDo-Demo-worktrees/land-t-exiu') !== k);
ok('a bare drive: C: and /c agree', cockpitPathKey('C:') === cockpitPathKey('/c') && cockpitPathKey('C:/') === cockpitPathKey('/c/'));
ok('a POSIX path is not taken for a drive', cockpitPathKey('/Users/x/p') === '/users/x/p' && cockpitPathKey('/cd/x') === '/cd/x');
ok("'' and null both give '' (the caller keeps null and '' distinct)", cockpitPathKey('') === '' && cockpitPathKey(null) === '');
// the lock → tab cwd rule: a /c/ lock runs under the matching worktree entry's own C:/ path, the main checkout as '' (reviewer: untested)
const { lockedWorktreeCwd } = ctx;
ok('lockedWorktreeCwd loaded', typeof lockedWorktreeCwd === 'function');
const MAIN = { path: 'C:/Users/a/ToDo-Demo', branch: 'master', is_main: true };
const WT = { path: 'C:/Users/a/ToDo-Demo-worktrees/land-t-exiu', branch: 'land/t-exiu', is_main: false };
ok('a /c/ lock runs under the entry\'s own C:/ path', lockedWorktreeCwd('/c/Users/a/ToDo-Demo-worktrees/land-t-exiu', MAIN, [WT]) === WT.path);
ok('a /c/ lock on the main checkout is \'\' (main)', lockedWorktreeCwd('/c/Users/a/ToDo-Demo', MAIN, [WT]) === '');
ok('no matching entry: the lock as written', lockedWorktreeCwd('/c/Users/a/elsewhere', MAIN, [WT]) === '/c/Users/a/elsewhere');
ok('no entries: the lock as written', lockedWorktreeCwd('C:/x', null, null) === 'C:/x');
if (fails) { console.log(`sprint-check-cockpit-pathkey: ${fails} failure(s)`); process.exit(1); }
console.log('sprint-check-cockpit-pathkey: ok');
