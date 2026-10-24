// t-c6bb: the Cockpit shell's side of the Logbook. The Logbook itself lives in each project's board (board-logbook.js); the Projects
// card's Logbook row opens that project's tab and asks its board to open it. The board may still be loading, so the shell repeats
// the request every 250 ms for up to 5 s until the board answers `logbook-opened` (cockpit-keys.js hands that answer to logbookOpened).
import { getProjects } from './cockpit-projects.js';
import { activeTab, openProject } from './cockpit-tabs.js';

const asking = new Map();   // project id -> interval

export function logbookOpened(pid) {
  clearInterval(asking.get(pid));
  asking.delete(pid);
}

export function openLogbookFor(pid) {
  const p = getProjects().find(x => x.id === pid);
  if (!p) return;
  if (activeTab !== pid) openProject(pid, p.name);
  logbookOpened(pid);
  let tries = 0;
  const t = setInterval(() => {
    const f = document.querySelector('#view-' + pid + ' iframe');
    if (f && f.contentWindow) {
      try { f.contentWindow.postMessage({ source: 'canon-cockpit-shell', type: 'open-logbook' }, location.origin); } catch { /* not ready yet */ }
    }
    if (++tries >= 20) logbookOpened(pid);
  }, 250);
  asking.set(pid, t);
}
