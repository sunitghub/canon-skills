const STORAGE_KEY = 'canon.todo.items';

export function createTodo(title, now = Date.now()) {
  const cleanTitle = title.trim();
  if (!cleanTitle) return null;
  return {
    id: `todo-${now}-${cleanTitle.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}`,
    title: cleanTitle,
    done: false,
    createdAt: now
  };
}

export function addTodo(items, title, now = Date.now()) {
  const todo = createTodo(title, now);
  return todo ? [...items, todo] : items;
}

export function toggleTodo(items, id) {
  return items.map(item => item.id === id ? { ...item, done: !item.done } : item);
}

export function deleteTodo(items, id) {
  return items.filter(item => item.id !== id);
}

export function filterTodos(items, filter) {
  if (filter === 'open') return items.filter(item => !item.done);
  if (filter === 'done') return items.filter(item => item.done);
  return items;
}

export function remainingCount(items) {
  return items.filter(item => !item.done).length;
}

function loadTodos() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveTodos(items) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(items));
}

function startApp() {
  const form = document.querySelector('#todo-form');
  const input = document.querySelector('#todo-input');
  const list = document.querySelector('#todo-list');
  const count = document.querySelector('#remaining-count');
  const filterButtons = [...document.querySelectorAll('[data-filter]')];

  let items = loadTodos();
  let filter = 'all';

  function commit(nextItems) {
    items = nextItems;
    saveTodos(items);
    render();
  }

  function render() {
    const visible = filterTodos(items, filter);
    count.value = `${remainingCount(items)} open`;
    list.innerHTML = '';

    if (visible.length === 0) {
      const empty = document.createElement('li');
      empty.className = 'empty';
      empty.textContent = filter === 'all' ? 'No tasks yet.' : `No ${filter} tasks.`;
      list.append(empty);
      return;
    }

    for (const item of visible) {
      const li = document.createElement('li');
      li.className = `item${item.done ? ' done' : ''}`;

      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = item.done;
      checkbox.setAttribute('aria-label', `Mark ${item.title} ${item.done ? 'open' : 'done'}`);
      checkbox.addEventListener('change', () => commit(toggleTodo(items, item.id)));

      const title = document.createElement('span');
      title.className = 'title';
      title.textContent = item.title;

      const remove = document.createElement('button');
      remove.type = 'button';
      remove.textContent = 'Delete';
      remove.addEventListener('click', () => commit(deleteTodo(items, item.id)));

      li.append(checkbox, title, remove);
      list.append(li);
    }
  }

  form.addEventListener('submit', event => {
    event.preventDefault();
    commit(addTodo(items, input.value));
    input.value = '';
    input.focus();
  });

  for (const button of filterButtons) {
    button.addEventListener('click', () => {
      filter = button.dataset.filter;
      for (const option of filterButtons) {
        option.setAttribute('aria-pressed', String(option === button));
      }
      render();
    });
  }

  render();
}

if (typeof document !== 'undefined') {
  startApp();
}
