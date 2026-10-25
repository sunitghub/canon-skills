// markdown.js (t-43ba) — the one markdown renderer: md() for every ticket doc. Its only import is html-escape.js.
// board-helpers.js re-exports everything here, so board modules and tests keep importing it from there.

// esc/escAttr live in html-escape.js (shared with the board's other modules and the Cockpit shell); re-exported so importers keep one path.
import { esc, escAttr } from './html-escape.js';
export { esc, escAttr };
// The inverse of esc(), for text md() has already escaped (only the five entities esc() produces).
function unescapeHtml(s) {
  return s.replace(/&(amp|lt|gt|quot|#39);/g, (_, e) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[e]);
}

function sortChecklistRuns(text) {
  const lines = text.split('\n');
  const out = [];
  for (let i = 0; i < lines.length;) {
    if (!/^- \[[ xX]\] /.test(lines[i])) {
      out.push(lines[i]);
      i++;
      continue;
    }
    const run = [];
    while (i < lines.length && /^- \[[ xX]\] /.test(lines[i])) {
      run.push(lines[i]);
      i++;
    }
    out.push(...run.filter(line => /^- \[ \] /.test(line)));
    out.push(...run.filter(line => !/^- \[ \] /.test(line)));
  }
  return out.join('\n');
}

// Resolve a markdown image src against the open ticket's own folder via the
// /api/ticket-image route — absolute/protocol-relative URLs pass through untouched.
export function resolveMockupSrc(src, ticketId) {
  if (/^(https?:)?\/\//.test(src) || src.startsWith('/')) return src;
  const relpath = src.split('/').map(encodeURIComponent).join('/');
  // An <img> is loaded by the browser directly, so the fetch wrapper (t-a55a) never sees it —
  // scope it here or a Cockpit project tab reads the server's default project (t-7d83).
  const proj = window.__canonProject ? `?project=${encodeURIComponent(window.__canonProject)}` : '';
  return `/api/ticket-image/${encodeURIComponent(ticketId)}/${relpath}${proj}`;
}

// Render a fenced Gherkin block as a styled scenario panel. Keyword-highlights
// Gherkin lines and escapes all text — raw doc content is never interpolated into
// HTML (esc() is applied to every fragment), so a scenario cannot inject markup.
const GHERKIN_KW = /^(\s*)(Scenario Outline|Scenario|Feature|Background|Examples|Rule|Given|When|Then|And|But|\*)/;
export function renderGherkinFence(fence) {
  const indent = (fence && fence.indent) || '';
  const html = String(fence && fence.body != null ? fence.body : '').split('\n').map(rawLine => {
    const line = indent && rawLine.startsWith(indent) ? rawLine.slice(indent.length) : rawLine;
    if (/^\s*#/.test(line)) return `<span class="doc-scenario-comment">${esc(line)}</span>`;
    const m = line.match(GHERKIN_KW);
    if (m) {
      const lead = m[1], kw = m[2], rest = line.slice(lead.length + kw.length);
      return `${esc(lead)}<span class="doc-scenario-kw">${esc(kw)}</span>${esc(rest)}`;
    }
    return esc(line);
  }).join('\n');
  return `<div class="doc-scenario">${html}</div>`;
}

// A ```gherkin-file reference points at a ticket-local .feature path, and MAY carry
// an optional `runner: <cmd>` line naming the command that validates it. md() emits
// this placeholder synchronously; hydrateFeatureRefs() fetches + fills it after render.

// Split a ```gherkin-file body into { src, runner }: exactly one .feature path line
// plus an optional `runner:` line, order-independent, blank lines ignored. The first
// non-runner line is the path candidate (validated by the caller).
export function parseFeatureRefBody(body) {
  const runnerLine = /^runner:\s*(.*)$/i;
  let src = '', runner = '';
  String(body == null ? '' : body).split('\n').forEach(raw => {
    const line = raw.trim();
    if (!line) return;
    const m = line.match(runnerLine);
    if (m) { runner = m[1].trim(); return; }
    if (!src) src = line;
  });
  return { src, runner };
}

// Non-executable display of the runner command a scenario-backed criterion names.
// The board never runs this — the fresh evaluator executes `<runner> <feature>` at
// sprint complete (see skills/sprint/reference/eval.md). Every fragment is esc()'d and
// the value never reaches a shell, subprocess, or eval on any board code path.
export function renderRunnerLabel(runner, src) {
  const cmd = String(runner == null ? '' : runner).trim();
  if (!cmd) return '';
  const full = src ? `${cmd} ${src}` : cmd;
  return `<div class="doc-scenario-runner"><span class="doc-scenario-runner-label">Runner</span><code>${esc(full)}</code></div>`;
}

export function renderFeatureRefPlaceholder(body) {
  const featureRefRe = /^features\/[A-Za-z0-9._\-\/]+\.feature$/;
  const { src, runner } = parseFeatureRefBody(body);
  const raw = String(src == null ? '' : src).trim();
  if (!featureRefRe.test(raw) || raw.includes('..')) {
    return `<div class="doc-scenario doc-scenario-ref doc-scenario-error">Invalid feature reference: ${esc(raw)} (expected features/&lt;name&gt;.feature)</div>`;
  }
  const attr = esc(raw);
  const runnerAttr = esc(runner);
  return `<div class="doc-scenario doc-scenario-ref" data-feature-src="${attr}" data-runner="${runnerAttr}">Loading ${esc(raw)}…</div>`;
}

// Minimal markdown: headers, bold, _italic_, inline code, > quotes, checklist items, bullet lists, images
export function md(raw, ticketId) {
  if (!raw) return '';
  // Pre-stamp each checkbox line with its source position using a null-byte
  // marker that survives esc() and sortChecklistRuns(), so the rendered index
  // matches the source file regardless of sort order.
  let srcIdx = 0;
  const stamped = raw.replace(/<!--[\s\S]*?-->/g, '').replace(/\n{3,}/g, '\n\n').trim()
    .replace(/^(- \[[ xX]\] )/gm, m => m + `\x00${srcIdx++}\x00`);

  // Extract ```gherkin-file references (body = a ticket-local .feature path) first —
  // these render asynchronously: md() emits a placeholder that hydrateFeatureRefs()
  // fetches and fills after the HTML is in the DOM (md() itself is synchronous).
  const featureRefs = [];
  const deRef = stamped.replace(
    /^([ \t]*)```[ \t]*gherkin-file[ \t]*\n([\s\S]*?)\n[ \t]*```[ \t]*$/gim,
    (_m, _indent, body) => { featureRefs.push(body.trim()); return `\x03${featureRefs.length - 1}\x03`; }
  );

  // Extract fenced Gherkin blocks (```gherkin / ```feature) before escaping or any
  // other transform, so their content renders as a scenario panel and is never
  // reinterpreted as markdown. Non-gherkin fences are left untouched (behavior unchanged).
  const fences = [];
  const deFenced = deRef.replace(
    /^([ \t]*)```[ \t]*(?:gherkin|feature)[ \t]*\n([\s\S]*?)\n[ \t]*```[ \t]*$/gim,
    (_m, indent, body) => {
      fences.push({ body, indent });
      return `\x02${fences.length - 1}\x02`;
    }
  );

  // Protect inline-code spans before any other syntax transform sees them —
  // otherwise markdown shown *as a code example* (e.g. `![alt](src)` or
  // `**bold**`) gets reinterpreted as real syntax instead of staying literal.
  const codeSpans = [];
  const withCodePlaceholders = sortChecklistRuns(esc(deFenced)).replace(/`((?:\\`|[^`\n])+)`/g, (_, code) => {
    codeSpans.push(code.replace(/\\`/g, '`'));
    return `\x01${codeSpans.length - 1}\x01`;
  });

  return withCodePlaceholders
    .replace(/^# (.+)$/gm,  '<strong class="doc-heading-1">$1</strong>')
    .replace(/^## (.+)$/gm, '<strong class="doc-heading-2">$1</strong>')
    .replace(/^### (.+)$/gm,'<strong class="doc-heading-3">$1</strong>')
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (m, alt, src) => {
      // t-d2e1: md() escaped the whole doc above, so the path is decoded back to its real characters before it is
      // URL-encoded, then escaped once for the attribute (it's.png, a&b.png). alt is already escaped text.
      const raw = unescapeHtml(src);
      const url = esc(ticketId ? resolveMockupSrc(raw, ticketId) : raw);
      return `<img class="doc-visual-img" src="${url}" alt="${alt}" loading="lazy">`;
    })
    .replace(/\*\*(.+?)\*\*/g,'<strong style="color:var(--text)">$1</strong>')
    .replace(/^\*\*([^*\n][^\n]*)$/gm,'<strong style="color:var(--text)">$1</strong>')
    .replace(/^- \[([ xX])\] \x00(\d+)\x00(.+)$/gm, (_, checked, si, text) => {
      const done = checked.toLowerCase() === 'x';
      return `<span class="doc-bullet${done ? '' : ' doc-check-open'}" data-src-idx="${si}"><span class="doc-check-marker${done ? '' : ' open'}">${done ? '✓' : ''}</span><span>${text}</span></span>`;
    })
    .replace(/^- (.+)$/gm,  '<span class="doc-bullet"><span class="doc-bullet-marker">·</span><span>$1</span></span>')
    // t-43ba: a `> ` line (escaped to `&gt; ` above) is a quote; adjacent quote lines merge into one block.
    .replace(/^&gt; ?(.*)$/gm, '<blockquote class="doc-quote">$1</blockquote>')
    .replace(/<\/blockquote>\n<blockquote class="doc-quote">/g, '<br>')
    // Blank lines between table rows are a common LLM-markdown quirk — swallow
    // them with \n+ so the block still groups as one table; row extraction
    // below already filters blank lines out via `.filter(r => r.trim())`.
    .replace(/((?:\|[^\n]+(?:\n+|$))+)/g, block => {
      const rows = block.trim().split('\n').filter(r => r.trim());
      if (rows.length < 2) return block;
      const [headerRow, sepRow, ...bodyRows] = rows;
      if (!/^\|[\s|:-]+\|$/.test(sepRow?.trim() || '')) return block;
      const cells = row => row.trim().split(/(?<!\\)\|/).slice(1, -1)
          .map(c => c.trim().replace(/\\\|/g, '|'));
      const thead = '<thead><tr>' + cells(headerRow).map(c => `<th>${c}</th>`).join('') + '</tr></thead>';
      const STATUS_CLASSES = { pass: 'status-pass', fail: 'status-fail', partial: 'status-partial', 'not-run': 'status-not-run' };
      const tbody = bodyRows.length
        ? '<tbody>' + bodyRows.map(r => '<tr>' + cells(r).map(c => {
            const cls = STATUS_CLASSES[c.trim().toLowerCase()];
            return `<td${cls ? ` class="${cls}"` : ''}>${c}</td>`;
          }).join('') + '</tr>').join('') + '</tbody>'
        : '';
      return `<div class="doc-table-wrap"><table class="doc-table">${thead}${tbody}</table></div>`;
    })
    // t-43ba: _italic_ only at word edges, so snake_case and a_b.png stay literal; code spans are still placeholders here.
    .replace(/(^|[\s(>])_(?=\S)([^_\n]+?)_(?=$|[\s.,;:!?)<])/gm, '$1<em>$2</em>')
    // Restore protected code spans last, after every other transform has run,
    // so backtick-wrapped text is never reinterpreted as image/bold/table/etc.
    .replace(/\x01(\d+)\x01/g, (_, i) => `<code class="doc-code">${codeSpans[+i]}</code>`)
    // Restore fenced Gherkin blocks as styled scenario panels.
    .replace(/\x02(\d+)\x02/g, (_, i) => renderGherkinFence(fences[+i]))
    // Restore ```gherkin-file references as async placeholders (hydrated post-render).
    .replace(/\x03(\d+)\x03/g, (_, i) => renderFeatureRefPlaceholder(featureRefs[+i]));
}

// md() with images off. md() turns ![alt](url) into an <img> (its src and alt come from the file), and its later transforms (stripping
// <!-- --> comments, restoring code spans) can rebuild that syntax or put markup inside the tag, so a filter over its source or a
// regex over its output can be bypassed (`!<!-- c -->[x](url)`, a code span inside an alt). The result is the thing to check: parse it
// into an inert <template> (it loads and runs nothing) and replace every <img> by its alt text, so no request is made and none of
// the file's attributes survive. md() escapes everything else first, so no other element can come from the file's text.
export const safeMd = text => {
  const t = document.createElement('template');
  t.innerHTML = md(text, '');
  t.content.querySelectorAll('img').forEach(i => i.replaceWith('[image: ' + (i.getAttribute('alt') || '') + ']'));
  return t.innerHTML;
};
