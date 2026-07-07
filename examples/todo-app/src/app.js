let seq = 0;

export function createTodo(title, now = Date.now(), uniq = seq++) {
  const cleanTitle = title.trim();
  if (!cleanTitle) return null;
  return {
    id: `todo-${now}-${uniq}-${cleanTitle.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}`,
    title: cleanTitle,
    done: false,
    createdAt: now
  };
}

export function addTodo(items, title, now = Date.now(), uniq = seq++) {
  const todo = createTodo(title, now, uniq);
  return todo ? [...items, todo] : items;
}

export function toggleTodo(items, id) {
  return items.map(item => item.id === id ? { ...item, done: !item.done } : item);
}

export function remainingCount(items) {
  return items.filter(item => !item.done).length;
}

function startApp() {
  const form = document.querySelector('#todo-form');
  const input = document.querySelector('#todo-input');
  const list = document.querySelector('#todo-list');
  const count = document.querySelector('#remaining-count');

  let items = [];

  function commit(nextItems) {
    items = nextItems;
    render();
  }

  function render() {
    count.value = `${remainingCount(items)} open`;
    list.innerHTML = '';

    if (items.length === 0) {
      const empty = document.createElement('li');
      empty.className = 'empty';
      empty.textContent = 'No tasks yet.';
      list.append(empty);
      return;
    }

    for (const item of items) {
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

      li.append(checkbox, title);
      list.append(li);
    }
  }

  form.addEventListener('submit', event => {
    event.preventDefault();
    commit(addTodo(items, input.value));
    input.value = '';
    input.focus();
  });

  render();
}

if (typeof document !== 'undefined') {
  startApp();
}
