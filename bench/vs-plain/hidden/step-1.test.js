// bench-canary: fc8c6a891fd8a400 (run.sh marks a session contaminated if its transcript holds this line's value: a read by any path)
// Hidden acceptance tests for step-1.md (t-e85f): add, list, done, remove, storage and errors, through the CLI only.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fresh } = require('./lib.js');

test('an empty list says No todos.', () => {
  const { cli } = fresh();
  assert.deepEqual(cli(['list']), { code: 0, out: 'No todos.', err: '' });
});

test('add prints the new id and text, ids start at 1', () => {
  const { cli } = fresh();
  assert.equal(cli(['add', 'buy milk']).out, 'Added #1: buy milk');
  assert.equal(cli(['add', 'call mom']).out, 'Added #2: call mom');
});

test('list shows open and done to-dos in id order', () => {
  const { cli } = fresh();
  cli(['add', 'a']); cli(['add', 'b']); cli(['add', 'c']);
  assert.equal(cli(['done', '2']).out, 'Done #2');
  assert.equal(cli(['list']).out, '#1 [ ] a\n#2 [x] b\n#3 [ ] c');
});

test('remove deletes and ids are never reused', () => {
  const { cli } = fresh();
  cli(['add', 'a']); cli(['add', 'b']);
  assert.equal(cli(['remove', '2']).out, 'Removed #2');
  assert.equal(cli(['add', 'c']).out, 'Added #3: c');
  assert.equal(cli(['list']).out, '#1 [ ] a\n#3 [ ] c');
});

test('the list is saved in TODO_FILE as JSON and survives across runs', () => {
  const { cli, file } = fresh();
  cli(['add', 'kept']);
  JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(cli(['list']).out, '#1 [ ] kept');
});

test('without TODO_FILE it uses todos.json in the current folder', () => {
  const { cli, dir } = fresh();
  cli(['add', 'here'], { TODO_FILE: '' });
  assert.ok(fs.existsSync(path.join(dir, 'todos.json')), 'todos.json in the current folder');
});

test('text with spaces and quotes is kept as given', () => {
  const { cli } = fresh();
  cli(['add', 'say "hi" to Ann']);
  assert.equal(cli(['list']).out, '#1 [ ] say "hi" to Ann');
});

for (const [name, args] of [
  ['an unknown command', ['frobnicate']],
  ['add with no text', ['add']],
  ['add with empty text', ['add', '']],
  ['done of a missing id', ['done', '7']],
  ['done of a non-number id', ['done', 'x']],
  ['remove of a missing id', ['remove', '9']],
]) {
  test(`${name} exits 1 with a message on stderr and changes nothing`, () => {
    const { cli } = fresh();
    cli(['add', 'only']);
    const r = cli(args);
    assert.equal(r.code, 1);
    assert.ok(r.err.length > 0, 'a message on stderr');
    assert.equal(cli(['list']).out, '#1 [ ] only');
  });
}
