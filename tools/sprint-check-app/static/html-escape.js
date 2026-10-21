// The one owner of esc/escAttr: board-helpers.js and cockpit-core.js re-export these, so the board and the shell share them.
// t-d2e1: esc() escapes quotes too, so its output is safe in text AND in a quoted attribute. escAttr is the same.
export function esc(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
export function escAttr(s) {
  return esc(s);
}
