// Hidden acceptance tests for step-2.md (t-e85f): due dates, --open, --done, --overdue, through the CLI only. TODO_TODAY is 2026-03-10.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { fresh } = require('./lib.js');

function seeded() {
  const f = fresh();
  f.cli(['add', 'past', '--due', '2026-03-01']);   // 1 overdue
  f.cli(['add', 'today', '--due', '2026-03-10']);  // 2 not overdue
  f.cli(['add', 'later', '--due', '2026-04-01']);  // 3
  f.cli(['add', 'no date']);                       // 4
  f.cli(['add', 'old done', '--due', '2026-01-01']); f.cli(['done', '5']);
  return f;
}

test('add --due saves the date and list shows it', () => {
  const { cli } = fresh();
  assert.equal(cli(['add', 'pay rent', '--due', '2026-04-01']).code, 0);
  assert.equal(cli(['list']).out, '#1 [ ] pay rent (due 2026-04-01)');
});

test('a to-do without a due date lists as before', () => {
  const { cli } = seeded();
  assert.match(cli(['list']).out, /^#4 \[ \] no date$/m);
});

for (const bad of ['2026-02-30', '2026-1-5', 'tomorrow', '2026-13-01']) {
  test(`--due ${bad} is refused and nothing is saved`, () => {
    const { cli } = fresh();
    const r = cli(['add', 'x', '--due', bad]);
    assert.equal(r.code, 1);
    assert.ok(r.err.length > 0);
    assert.equal(cli(['list']).out, 'No todos.');
  });
}

test('list --open lists only open to-dos', () => {
  const { cli } = seeded();
  assert.equal(cli(['list', '--open']).out.split('\n').map(l => l.split(' ')[0]).join(','), '#1,#2,#3,#4');
});

test('list --done lists only done to-dos', () => {
  const { cli } = seeded();
  assert.equal(cli(['list', '--done']).out, '#5 [x] old done (due 2026-01-01)');
});

test('list --overdue lists open to-dos due before today', () => {
  const { cli } = seeded();
  assert.match(cli(['list', '--overdue']).out, /^#1 \[ \] past \(due 2026-03-01\)$/m);
});

test('TODO_TODAY moves what is overdue', () => {
  const { cli } = seeded();
  const ids = cli(['list', '--overdue'], { TODO_TODAY: '2026-05-01' }).out.split('\n').map(l => l.split(' ')[0]);
  assert.ok(ids.includes('#3') && ids.includes('#1'), ids.join(','));
});

test('a filter that matches nothing says No todos.', () => {
  const { cli } = fresh();
  cli(['add', 'open one']);
  assert.equal(cli(['list', '--done']).out, 'No todos.');
});
