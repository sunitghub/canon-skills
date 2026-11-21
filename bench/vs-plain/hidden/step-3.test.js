// Hidden acceptance tests for step-3.md (t-e85f), the planted bug in baseline-3/: --overdue must leave out a to-do due today and a
// done one. TODO_TODAY is 2026-03-10. Steps 1 and 2's tests run with it, as the regression half of the score.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { fresh } = require('./lib.js');

test('a to-do due today is not overdue', () => {
  const { cli } = fresh();
  cli(['add', 'today', '--due', '2026-03-10']);
  assert.equal(cli(['list', '--overdue']).out, 'No todos.');
});

test('a done to-do is never overdue', () => {
  const { cli } = fresh();
  cli(['add', 'old', '--due', '2026-01-01']); cli(['done', '1']);
  assert.equal(cli(['list', '--overdue']).out, 'No todos.');
});

test('--overdue lists exactly the open to-dos due before today', () => {
  const { cli } = fresh();
  cli(['add', 'a', '--due', '2026-03-09']); cli(['add', 'b', '--due', '2026-03-10']);
  cli(['add', 'c', '--due', '2026-02-01']); cli(['done', '3']); cli(['add', 'd']);
  assert.equal(cli(['list', '--overdue']).out, '#1 [ ] a (due 2026-03-09)');
});
