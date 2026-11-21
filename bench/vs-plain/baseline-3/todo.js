#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const file = process.env.TODO_FILE || path.join(process.cwd(), 'todos.json');

function fail(msg) {
  process.stderr.write(msg + '\n');
  process.exit(1);
}

function load() {
  if (!fs.existsSync(file)) return { next: 1, todos: [] };
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function save(db) {
  fs.writeFileSync(file, JSON.stringify(db, null, 2) + '\n');
}

function isDate(s) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(s + 'T00:00:00Z');
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

function today() {
  if (process.env.TODO_TODAY) return process.env.TODO_TODAY;
  const d = new Date();
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function findId(db, arg) {
  if (!/^\d+$/.test(arg || '')) fail(`Not a valid id: ${arg === undefined ? '(none)' : arg}`);
  const t = db.todos.find(x => x.id === Number(arg));
  if (!t) fail(`No todo #${arg}`);
  return t;
}

function line(t) {
  return `#${t.id} [${t.done ? 'x' : ' '}] ${t.text}` + (t.due ? ` (due ${t.due})` : '');
}

const [cmd, ...args] = process.argv.slice(2);
const db = load();

switch (cmd) {
  case 'add': {
    const text = args[0];
    if (!text) fail('Usage: todo.js add "<text>" [--due YYYY-MM-DD]');
    let due;
    const i = args.indexOf('--due', 1);
    if (i !== -1) {
      due = args[i + 1];
      if (!isDate(due || '')) fail(`Not a valid date: ${due === undefined ? '(none)' : due}`);
    }
    const t = { id: db.next, text, done: false };
    if (due) t.due = due;
    db.todos.push(t);
    db.next += 1;
    save(db);
    console.log(`Added #${t.id}: ${text}`);
    break;
  }
  case 'list': {
    const flag = args[0];
    const now = today();
    const filters = {
      '--open': t => !t.done,
      '--done': t => t.done,
      '--overdue': t => t.due && t.due <= now,
    };
    if (flag !== undefined && !filters[flag]) fail(`Unknown option: ${flag}`);
    const shown = db.todos.filter(flag ? filters[flag] : () => true).sort((a, b) => a.id - b.id);
    console.log(shown.length ? shown.map(line).join('\n') : 'No todos.');
    break;
  }
  case 'done': {
    const t = findId(db, args[0]);
    t.done = true;
    save(db);
    console.log(`Done #${t.id}`);
    break;
  }
  case 'remove': {
    const t = findId(db, args[0]);
    db.todos = db.todos.filter(x => x !== t);
    save(db);
    console.log(`Removed #${t.id}`);
    break;
  }
  default:
    fail(`Unknown command: ${cmd === undefined ? '(none)' : cmd}`);
}
