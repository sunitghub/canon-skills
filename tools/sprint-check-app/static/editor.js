// Doc-editor key helpers (t-9b2d: moved verbatim out of app.html). The board modules import them (t-1543).

export function continuationPrefix(line) {
  let match = line.match(/^(\s*)-\s+\[([ xX])\]\s+(.*)$/);
  if (match) return { prefix: `${match[1]}- [${match[2]}] `, content: match[3] };

  match = line.match(/^(\s*)-\s+(.*)$/);
  if (match) return { prefix: `${match[1]}- `, content: match[2] };

  match = line.match(/^(\s*)\*\*(\d+)\.\s+(.*)$/);
  if (match) return { prefix: `${match[1]}**${Number(match[2]) + 1}. `, content: match[3] };

  match = line.match(/^(\s*)(\d+)\.\s+(.*)$/);
  if (match) return { prefix: `${match[1]}${Number(match[2]) + 1}. `, content: match[3] };

  return null;
}

// Pure Tab / Shift+Tab indent transform for a textarea — unit-tested in
// tests/sprint-check-editor.js. Two spaces per level (matches the gherkin skeleton's step
// indent and markdown list nesting). Returns the new value + the selection to restore.
export function computeTabEdit(value, selStart, selEnd, shiftKey) {
  const INDENT = '  ';
  value = String(value ?? '');
  // Plain Tab with no selection: insert two spaces at the cursor.
  if (!shiftKey && selStart === selEnd) {
    const next = value.slice(0, selStart) + INDENT + value.slice(selStart);
    const pos = selStart + INDENT.length;
    return { value: next, selStart: pos, selEnd: pos };
  }
  // Otherwise operate on every line the selection spans.
  const blockStart = value.lastIndexOf('\n', selStart - 1) + 1;
  // Don't pull in a trailing empty line when the selection ends exactly at a line start.
  let blockEnd = selEnd;
  if (blockEnd > blockStart && value[blockEnd - 1] === '\n') blockEnd -= 1;
  const block = value.slice(blockStart, blockEnd);
  const OUTDENT = /^( {1,2}|\t)/; // strip up to two leading spaces or one tab
  const out = block
    .split('\n')
    .map((l) => (shiftKey ? l.replace(OUTDENT, '') : INDENT + l))
    .join('\n');
  return { value: value.slice(0, blockStart) + out + value.slice(blockEnd), selStart: blockStart, selEnd: blockStart + out.length };
}

// Make Tab indent inside the editor instead of moving focus out of the textarea.
export function handleTabIndent(event, textarea) {
  if (event.key !== 'Tab' || event.altKey || event.ctrlKey || event.metaKey) return;
  event.preventDefault();
  // Simple Tab, no selection: insert two spaces via execCommand so native undo is preserved.
  if (!event.shiftKey && textarea.selectionStart === textarea.selectionEnd) {
    document.execCommand('insertText', false, '  ');
    return;
  }
  // Multi-line indent, or Shift+Tab outdent: apply the pure transform and restore the selection.
  const r = computeTabEdit(textarea.value, textarea.selectionStart, textarea.selectionEnd, event.shiftKey);
  textarea.value = r.value;
  textarea.setSelectionRange(r.selStart, r.selEnd);
}

export function handleMarkdownEnter(event, textarea) {
  if (event.key !== 'Enter' || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return;
  if (textarea.selectionStart !== textarea.selectionEnd) return;

  const cursor = textarea.selectionStart;
  const value = textarea.value;
  const lineStart = value.lastIndexOf('\n', cursor - 1) + 1;
  const lineEndAtCursor = value.slice(lineStart, cursor);
  const line = lineEndAtCursor;
  const next = continuationPrefix(line);
  if (!next) return;

  event.preventDefault();
  if (next.content.trim()) {
    textarea.setSelectionRange(cursor, cursor);
    document.execCommand('insertText', false, `\n${next.prefix}`);
  } else {
    textarea.setSelectionRange(lineStart, cursor);
    document.execCommand('insertText', false, '');
    const nextChar = textarea.value[textarea.selectionStart];
    if (nextChar === '\n') {
      const pos = textarea.selectionStart;
      textarea.setSelectionRange(pos, pos + 1);
      document.execCommand('insertText', false, '');
    }
  }
}
