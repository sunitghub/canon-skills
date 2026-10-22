// t-eb92: ticket ids and ticket-folder deletes for tests/sprint-check-app.spec.js.
// The spec writes tickets under a project root and later deletes them; an id that collided with a real ticket would
// delete that ticket's folder (.tickets is gitignored, so there is no undo). So a spec makes every id with
// newTicketId (never one that exists) and deletes only through removeTestTicket (only an id this run created).
// Kept free of Playwright so tests/board-spec-ids.test.js can load it.
const fs = require('fs');
const path = require('path');

const created = new Set();   // absolute ticket-folder paths made by newTicketId or adopted from the board in this run
const dirOf = (root, id) => path.resolve(root, '.tickets', id);
const defaultExists = (root, id) => fs.existsSync(dirOf(root, id));

// No label: a random t-xxxx id. With a label: t-<label>-<timestamp> (a retry adds a random tail).
// `exists` is injectable so a unit check can force a collision.
function newTicketId(root, label, exists = defaultExists) {
  for (let attempt = 0; ; attempt++) {
    const rand = Math.random().toString(36).slice(2, 6).padEnd(4, '0');
    const id = label ? `t-${label}-${Date.now()}${attempt ? '-' + rand : ''}` : `t-${rand}`;
    if (created.has(dirOf(root, id)) || exists(root, id)) continue;
    created.add(dirOf(root, id));
    return id;
  }
}

// A fixed id a test must spell out (a numeric id, a shape probe). Refused, not deleted, if it is already a ticket.
function claimTicketId(root, id, exists = defaultExists) {
  if (exists(root, id) || created.has(dirOf(root, id))) throw new Error(`claimTicketId: ${id} already exists under ${root}/.tickets; the test would clobber it`);
  created.add(dirOf(root, id));
  return id;
}

// An id the board made for a ticket the test created through the UI. Accepted only if the folder's ticket.md holds the
// test's own unique title, so a wrong data-id can never put a real ticket on the delete list.
function adoptBoardTicket(root, id, title) {
  const md = path.join(dirOf(root, id), 'ticket.md');
  if (!id || !title || !fs.existsSync(md) || !fs.readFileSync(md, 'utf8').includes(title)) {
    throw new Error(`adoptBoardTicket: ${id || '(empty id)'} is not a ticket this test created (no ticket.md holding the title)`);
  }
  created.add(dirOf(root, id));
  return id;
}

// The only delete of a ticket folder in the spec. Throws for an id this run did not create.
function removeTestTicket(root, id) {
  const dir = dirOf(root, id);
  if (!created.has(dir)) throw new Error(`removeTestTicket: ${id} was not created by newTicketId in this run; refusing to delete ${dir}`);
  fs.rmSync(dir, { recursive: true, force: true });   // stays registered: a test may clear its fixture again (force: true)
}

module.exports = { newTicketId, claimTicketId, adoptBoardTicket, removeTestTicket };
