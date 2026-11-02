// t-8381: the one reader of LEARNINGS.md (and the markers helper), shared by the board's Logbook (board-logbook.js) and the Cockpit's
// Projects card (cockpit-projects.js). Pure text in, data out: no DOM, no fetch. The text can come from a PR or a clone, so callers
// escape every value they render.
export function between(text, begin, end) {
  const a = text.indexOf(begin);
  if (a < 0) return text;
  const from = a + begin.length;
  const b = text.indexOf(end, from);
  return b < 0 ? text.slice(from) : text.slice(from, b);
}

// A table row's cells: `\|` is a literal pipe, a bare `|` ends a cell.
export function splitRow(line) {
  const cells = [];
  let cur = '';
  const s = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '\\' && s[i + 1] === '|') { cur += '|'; i++; } else if (s[i] === '|') { cells.push(cur.trim()); cur = ''; } else cur += s[i];
  }
  cells.push(cur.trim());
  return cells;
}

export function statusOf(raw) {
  const s = raw.replace(/`/g, '').trim();
  if (/^unpromoted/i.test(s)) return { kind: 'un', label: 'unpromoted', target: '' };
  if (/^promoted/i.test(s)) return { kind: 'pr', label: 'promoted', target: s.replace(/^promoted\s*(?:→|->)?\s*/i, '') };
  if (/^dismissed/i.test(s)) return { kind: 'dm', label: 'dismissed', target: '' };
  return { kind: 'ot', label: 'unknown', target: '', raw: s };   // t-5036: a malformed row's text never sizes the pill
}

// Rows of the LEARNINGS.md table between its markers: | date | [t-id](path) | finding | status |
export function parseLearnings(text) {
  const rows = [];
  for (const line of between(text, '<!-- canon:learnings:BEGIN -->', '<!-- canon:learnings:END -->').split('\n')) {
    if (!line.trim().startsWith('|')) continue;
    const c = splitRow(line);
    if (c.length < 4 || /^date$/i.test(c[0]) || /^-+$/.test(c[0].replace(/[:\s]/g, ''))) continue;
    const id = /\[?(t-[0-9a-z]+)\]?/i.exec(c[1]);
    rows.push({ date: c[0], id: id ? id[1] : '', finding: c[2], ...statusOf(c.slice(3).join(' | ')) });
  }
  return rows;
}

const STAMP_RE = /^learnings-sweep last run:\s*(\d{2})-(\d{2})-(\d{4})\b/m;

// learningsSummary(text): { rows, pending, swept } for a Projects card. rows counts the table's rows, pending the UNPROMOTED ones;
// swept is the sweep stamp's date as YYYY-MM-DD, or '' when the file has none.
export function learningsSummary(text) {
  const rows = parseLearnings(text || '');
  const m = STAMP_RE.exec(text || '');
  return { rows: rows.length, pending: rows.filter(r => r.kind === 'un').length, swept: m ? `${m[3]}-${m[1]}-${m[2]}` : '' };
}

