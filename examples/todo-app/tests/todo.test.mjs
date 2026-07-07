import test from 'node:test';
import assert from 'node:assert/strict';
import {
  addTodo,
  createTodo,
  remainingCount,
  toggleTodo
} from '../src/app.js';

test('createTodo trims titles and creates stable ids', () => {
  assert.deepEqual(createTodo('  Buy milk  ', 1000, 0), {
    id: 'todo-1000-0-buy-milk',
    title: 'Buy milk',
    done: false,
    createdAt: 1000
  });
});

test('blank todo titles are ignored', () => {
  const items = [{ id: 'todo-1', title: 'Existing', done: false }];
  assert.equal(createTodo('   ', 1000, 0), null);
  assert.equal(addTodo(items, '   ', 1000, 0), items);
});

test('todos can be added and toggled complete', () => {
  let items = [];
  items = addTodo(items, 'Ship docs', 1, 0);
  items = addTodo(items, 'Open sprint-check', 2, 1);

  assert.equal(remainingCount(items), 2);

  items = toggleTodo(items, 'todo-1-0-ship-docs');
  assert.equal(remainingCount(items), 1);
  assert.equal(items[0].done, true);

  items = toggleTodo(items, 'todo-1-0-ship-docs');
  assert.equal(remainingCount(items), 2);
  assert.equal(items[0].done, false);
});

test('same now + same title no longer collide on id', () => {
  let items = [];
  items = addTodo(items, 'Buy milk', 1000, 0);
  items = addTodo(items, 'Buy milk', 1000, 1);

  assert.notEqual(items[0].id, items[1].id);
});

test('toggling one former-collision item leaves the other untouched', () => {
  let items = [];
  items = addTodo(items, 'Buy milk', 1000, 0);
  items = addTodo(items, 'Buy milk', 1000, 1);

  items = toggleTodo(items, items[0].id);

  assert.equal(items[0].done, true);
  assert.equal(items[1].done, false);
});
