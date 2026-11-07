// t-ae96: the one busy-button helper, for the board and the Cockpit shell (both pages import it). The spinner is CSS
// (button[aria-busy="true"]::before in tokens.css), so the button's own nodes are kept aside and put back as they were; the label
// is a text node, nothing here parses HTML. A second call on a button already busy (two requests at once) shares the first's
// state and the last one to finish restores it. A thrown or rejected action restores it too.
const busy = new WeakMap();

export async function withBusy(btn, busyLabel, action) {
  let st = busy.get(btn);
  if (!st) {
    st = { n: 0, kept: [...btn.childNodes], disabled: btn.disabled };
    busy.set(btn, st);
    btn.replaceChildren(document.createTextNode(busyLabel || ''));
    btn.disabled = true;
    btn.setAttribute('aria-busy', 'true');
  }
  st.n++;
  try {
    return await action();
  } finally {
    if (--st.n === 0) {
      busy.delete(btn);
      btn.replaceChildren(...st.kept);
      btn.disabled = st.disabled;
      btn.removeAttribute('aria-busy');
    }
  }
}
