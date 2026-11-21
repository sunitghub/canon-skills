// Shared helper for the hidden acceptance tests (t-e85f): runs the app under test, `node todo.js ...`, in BENCH_APP_DIR with its
// own TODO_FILE, the way a person would. Neither bench arm ever sees this folder (run.sh copies it in only after a session ends).
'use strict';
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const APP = process.env.BENCH_APP_DIR;
if (!APP || !fs.existsSync(path.join(APP, 'todo.js'))) throw new Error('BENCH_APP_DIR must name a folder holding todo.js');

// fresh() -> a cli(args, env) bound to a new, empty to-do file
function fresh() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bench-todo-'));
  const file = path.join(dir, 'todos.json');
  const cli = (args, env = {}) => {
    const r = spawnSync(process.execPath, [path.join(APP, 'todo.js'), ...args], {
      cwd: dir, encoding: 'utf8', timeout: 10000, env: { ...process.env, TODO_FILE: file, TODO_TODAY: '2026-03-10', ...env },
    });
    return { code: r.status, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
  };
  return { cli, dir, file };
}

module.exports = { fresh };
