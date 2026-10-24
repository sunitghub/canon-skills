// t-37e8: ticket tags — the catalog (GET /api/tags), the chips on cards and in the modal, and one dropdown (openTagMenu) shared by
// the New Ticket dialog and the ticket modal. A tag is typed by a user and written into a ticket file, so the server decides what is
// valid (tools/canon-go/internal/board/tags.go); TAG_RE here only gives a hint before a round trip. All tag text reaches the page
// through esc() or textContent, never as markup.
import { esc, escAttr, titleCase } from './board-helpers.js';
import { postWrite, renderBoard } from './board-render.js';

const TAG_RE = /^[a-z0-9][a-z0-9-]{0,23}$/;
const MAX_TAGS = 8;
let catalog = { starter: [], project: [], error: '' };

// A starter tag has its own label (GitHub, NodeJs, CLI); any other is shown in Title Case (the stored form stays lowercase).
function tagLabel(tag) {
  const s = catalog.starter.find(x => x.tag === tag);
  return s ? s.label : titleCase(tag);
}

async function loadTagCatalog() {
  // A board started before tags existed answers 404: say so in the dropdown, never show an empty list as if there were no starters.
  try {
    const r = await fetch('/api/tags');
    if (r.ok) catalog = await r.json();
    else catalog = { ...catalog, error: r.status === 404 ? 'This board is older than tags. Restart it (canon) to load the new version.' : `The tag list could not be loaded (HTTP ${r.status}).` };
  } catch (e) {
    catalog = { ...catalog, error: `The tag list could not be loaded: ${(e && e.message) || e}` };
  }
  return catalog;
}

// Chips for a list of tags: at most `max` of them, then "+n". Empty list: nothing.
export function tagChipsHTML(tags, max = 3) {
  if (!tags.length) return '';
  const shown = tags.slice(0, max).map(t => `<span class="tag-chip" data-tag="${escAttr(t)}">${esc(tagLabel(t))}</span>`).join('');
  return shown + (tags.length > max ? `<span class="tag-more" title="${escAttr(tags.slice(max).map(tagLabel).join(', '))}">+${tags.length - max}</span>` : '');
}

let menu = null;
function closeTagMenu() {
  if (!menu) return;
  const { el, anchor, off } = menu;
  menu = null;
  off();
  el.remove();
  anchor.setAttribute('aria-expanded', 'false');
  if (document.contains(anchor)) anchor.focus();
}

// A checklist under `anchor`. onChange(newTags) answers true when the change was kept (the modal saves it to the server); a
// refused change puts the box back. "Add tag" takes one new tag, saves it to the project's list and ticks it.
export function openTagMenu({ anchor, selected, onChange }) {
  closeTagMenu();
  let sel = selected.slice();
  const el = document.createElement('div');
  el.className = 'tag-menu';
  el.setAttribute('role', 'group');
  el.setAttribute('aria-label', 'Tags');
  const list = document.createElement('div');
  list.className = 'tag-menu-list';
  const msg = document.createElement('div');
  msg.className = 'tag-menu-msg';
  msg.setAttribute('role', 'status');
  const add = document.createElement('input');
  add.className = 'tag-menu-add';
  add.placeholder = 'Add tag…';
  add.maxLength = 24;
  add.setAttribute('aria-label', 'Add a new tag');
  add.autocomplete = 'off';
  el.append(list, msg, add);

  const options = () => [...catalog.starter.map(s => s.tag), ...catalog.project.filter(p => !catalog.starter.some(s => s.tag === p))];
  const paint = () => {
    list.replaceChildren();
    // A to Z by the label the user sees (starters, the project's own and any ticked tag alike); ticking one does not move it
    const byLabel = (a, b) => tagLabel(a).localeCompare(tagLabel(b), undefined, { sensitivity: 'base' });
    for (const tag of [...new Set([...options(), ...sel])].sort(byLabel)) {
      const row = document.createElement('label');
      row.className = 'tag-menu-row';
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = sel.includes(tag);
      box.disabled = !box.checked && sel.length >= MAX_TAGS;
      box.addEventListener('change', async () => {
        const next = box.checked ? [...sel, tag] : sel.filter(x => x !== tag);
        const kept = await onChange(next);
        if (kept === false) { box.checked = !box.checked; msg.textContent = 'That change could not be saved.'; return; }
        sel = next;
        msg.textContent = sel.length >= MAX_TAGS ? `At most ${MAX_TAGS} tags.` : '';
        paint();
      });
      const text = document.createElement('span');
      text.textContent = tagLabel(tag);
      row.append(box, text);
      list.append(row);
    }
    if (catalog.error) msg.textContent = catalog.error;
  };
  add.addEventListener('keydown', async e => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    const tag = add.value.trim().replace(/\s+/g, '-').toLowerCase();   // trimmed; inner spaces become dashes
    if (!tag) return;
    if (!TAG_RE.test(tag)) { msg.textContent = 'Use lowercase letters, digits and dashes (1 to 24 characters).'; return; }
    if (sel.length >= MAX_TAGS) { msg.textContent = `At most ${MAX_TAGS} tags.`; return; }
    const res = await postWrite('/api/tags', { tag }, 'add the tag');
    if (!res.ok) { msg.textContent = (res.data && res.data.error) || 'The tag could not be added.'; return; }
    catalog = res.data;
    add.value = '';
    const next = sel.includes(tag) ? sel : [...sel, tag];
    if (await onChange(next) !== false) sel = next;
    paint();
  });

  const place = () => {
    const r = anchor.getBoundingClientRect();
    el.style.left = Math.max(8, Math.min(r.left, window.innerWidth - el.offsetWidth - 8)) + 'px';
    el.style.top = Math.max(8, Math.min(r.bottom + 4, window.innerHeight - el.offsetHeight - 8)) + 'px';
  };
  const onDown = e => { if (!el.contains(e.target) && !anchor.contains(e.target)) closeTagMenu(); };
  // Escape closes the menu only: stop it before the ticket modal's own Escape handler (a document listener) sees it.
  const onKey = e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeTagMenu(); } };
  document.addEventListener('pointerdown', onDown, true);
  document.addEventListener('keydown', onKey, true);
  const off = () => { document.removeEventListener('pointerdown', onDown, true); document.removeEventListener('keydown', onKey, true); window.removeEventListener('resize', closeTagMenu); };
  window.addEventListener('resize', closeTagMenu);
  menu = { el, anchor, off };
  anchor.setAttribute('aria-expanded', 'true');
  document.body.append(el);
  paint();
  place();
  // a fresh catalog repaints the list only when its options changed: a repaint under the pointer would swallow a click
  const shownOptions = JSON.stringify(options());
  loadTagCatalog().then(() => { if (menu && menu.el === el && JSON.stringify(options()) !== shownOptions) { paint(); place(); } });
  (list.querySelector('input') || add).focus();
}

// Saves a ticket's tags (the modal's change handler). True when the server kept them.
export async function saveTicketTags(t, tags) {
  const res = await postWrite(`/api/ticket/${t.id}/tags`, { tags }, `tag ${t.id}`);
  if (!res.ok) return false;
  t.tags = tags.join(',');
  renderBoard();
  return true;
}

export function initTags() {
  loadTagCatalog().then(() => renderBoard());
}
