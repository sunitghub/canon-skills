#!/usr/bin/env node
// board-spec-ids-unit — t-eb92. Protects tests/sprint-check-app.spec.js, which writes and deletes tickets under its project
// root: a random id that collided with a real ticket would delete that ticket's folder. Checks (1) the helpers in
// tests/board-spec-ids.js and (2) a lint of the spec: no Math.random, no timestamped t-... id literal, no rmSync without
// the `/* non-ticket */` marker (a ticket folder goes only through removeTestTicket). Usage: node tests/board-spec-ids-unit.js
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { newTicketId, claimTicketId, adoptBoardTicket, removeTestTicket } = require('./board-spec-ids');

// Returns the violations in a spec's source, as "line N: reason".
function lintSpec(src) {
  const bad = [];
  src.split('\n').forEach((line, i) => {
    const at = (why) => bad.push(`line ${i + 1}: ${why}`);
    if (/Math\.random/.test(line)) at('Math.random in the spec: make ids with newTicketId');
    if (/`t-[^`]*\$\{[^}`]*(Date\.now|stamp|Math)/.test(line)) at('a timestamped ticket id literal: use newTicketId(root, label)');
    if (/rmSync/.test(line) && !/\/\* non-ticket \*\//.test(line)) at('rmSync outside removeTestTicket: delete a ticket with removeTestTicket(root, id)');
  });
  return bad;
}

let failed = 0;
const check = (name, fn) => { try { fn(); console.log(`ok - ${name}`); } catch (e) { failed++; console.log(`not ok - ${name}\n  ${e.message}`); } };
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'board-spec-ids-'));
fs.mkdirSync(path.join(root, '.tickets', 't-real'), { recursive: true });

check('newTicketId retries when the first candidate exists', () => {
  let calls = 0;
  const id = newTicketId(root, undefined, () => ++calls === 1);   // the first candidate "exists"
  assert.ok(calls >= 2, `existence checked ${calls} time(s)`);
  assert.match(id, /^t-[a-z0-9]{4}$/);
});
check('newTicketId with a label makes t-<label>-<digits>, never an id issued before', () => {
  const a = newTicketId(root, 'lbl'), b = newTicketId(root, 'lbl');
  assert.match(a, /^t-lbl-\d+/);
  assert.notStrictEqual(a, b);
});
check('removeTestTicket deletes an id newTicketId made, and a second delete is a harmless no-op', () => {
  const id = newTicketId(root);
  fs.mkdirSync(path.join(root, '.tickets', id), { recursive: true });
  removeTestTicket(root, id);
  assert.ok(!fs.existsSync(path.join(root, '.tickets', id)));
  removeTestTicket(root, id);
});
check('claimTicketId refuses an id that already exists and registers one that does not', () => {
  assert.throws(() => claimTicketId(root, 't-real'), /already exists/);
  claimTicketId(root, 't-fixd');
  removeTestTicket(root, 't-fixd');
});
check('claimTicketId returns its id and refuses to claim it twice', () => {
  assert.strictEqual(claimTicketId(root, 't-twic'), 't-twic');
  assert.throws(() => claimTicketId(root, 't-twic'), /already exists/);
});
check('adoptBoardTicket returns the id and refuses an empty id, an empty title, a missing folder or a title not in ticket.md', () => {
  const dir = path.join(root, '.tickets', 't-ad0p');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'ticket.md'), '# Title A\n');
  assert.throws(() => adoptBoardTicket(root, '', 'Title A'), /not a ticket this test created/);
  assert.throws(() => adoptBoardTicket(root, 't-ad0p', ''), /not a ticket this test created/);
  assert.throws(() => adoptBoardTicket(root, 't-nodir', 'Title A'), /not a ticket this test created/);
  assert.throws(() => adoptBoardTicket(root, 't-ad0p', 'Title B'), /not a ticket this test created/);
  assert.strictEqual(adoptBoardTicket(root, 't-ad0p', 'Title A'), 't-ad0p');
  removeTestTicket(root, 't-ad0p');
});
check('removeTestTicket throws for an id it did not create and leaves the folder', () => {
  assert.throws(() => removeTestTicket(root, 't-real'), /not created/);
  assert.ok(fs.existsSync(path.join(root, '.tickets', 't-real')));
});
check('adoptBoardTicket accepts only a ticket whose ticket.md holds the test title', () => {
  const dir = path.join(root, '.tickets', 't-b0rd');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'ticket.md'), '# My unique title 123\n');
  assert.throws(() => adoptBoardTicket(root, 't-real', 'My unique title 123'), /not a ticket this test created/);
  assert.throws(() => adoptBoardTicket(root, 't-b0rd', 'another title'), /not a ticket this test created/);
  adoptBoardTicket(root, 't-b0rd', 'My unique title 123');
  removeTestTicket(root, 't-b0rd');
  assert.ok(!fs.existsSync(dir));
});

const spec = fs.readFileSync(path.join(__dirname, 'sprint-check-app.spec.js'), 'utf8');
check('the board spec has no raw random id, timestamped id literal or ticket-folder rmSync', () => {
  assert.deepStrictEqual(lintSpec(spec), []);
});
check('the lint fails when a raw random id is reintroduced (revert check)', () => {
  assert.ok(lintSpec(spec + "\nconst id = `t-${Math.random().toString(36).slice(2, 6)}`;\n").length >= 1);
});
check('the lint fails on a timestamped id literal and on a direct ticket-folder rmSync', () => {
  assert.ok(lintSpec("const id = `t-x-${Date.now()}`;").length === 1);
  assert.ok(lintSpec("fs.rmSync(path.join(R, '.tickets', id), { recursive: true });").length === 1);
});

fs.rmSync(root, { recursive: true, force: true });
if (failed) { console.log(`${failed} failed`); process.exit(1); }
