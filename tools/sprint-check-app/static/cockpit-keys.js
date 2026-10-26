// t-565f: the Cockpit shell's keys code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initKeys(), which cockpit-main.js runs in order once every module has loaded.
import { esc, toast } from './cockpit-core.js';
import { TICKET_ID_RE, liveTabIds } from './cockpit-sessions.js';
import { toggleSide } from './cockpit-sidebar.js';
import { showView } from './cockpit-views.js';
import { openFactoryGithub } from './cockpit-factory.js';
import { logbookOpened } from './cockpit-logbook.js';
import { openTabSessionMenu } from './cockpit-end.js';
import { activeTab, applySplit, closeSplit, closeTab, goTab, isProjectTab, onScratchTabs, openSessionInTab, openSplit, openTabs, prevTab, renderTabs, saveSplit, senderTab, split, splitShown } from './cockpit-tabs.js';

  // ── Keyboard prefix (t-a198) ─────────────────────────────────────────────
  // Press the prefix (default ctrl+., rebind with localStorage "canon-prefix"), release, then one key. Keys typed in
  // this page are handled here; keys typed inside a board or its terminal arrive as validated messages (below).
  // Ignored in fields and under a dialog, so typing is never hijacked.
// canon:prefix-keys:begin (t-a198) — identical in cockpit.html, static/board-cockpit-rail.js and cockpit-daemon/web/cockpit.html; tests/prefix-keys-parity.sh pins the copies
function canonPrefixLabel() {
  var v = 'ctrl+.';
  try { var s = localStorage.getItem('canon-prefix'); if (s && /^ctrl\+[^A-Za-z0-9\s\\+]$/.test(s)) v = s; } catch (e) {}
  return v;
}
function canonPrefixKeys(emit) {
  var armed = false, sub = false, timer = null, swallow = null;   // sub: `P` was pressed, one more key follows (t-ccf5)
  function disarm() { armed = false; sub = false; if (timer) { clearTimeout(timer); timer = null; } }
  function arm() { if (timer) clearTimeout(timer); timer = setTimeout(function () { if (armed) { disarm(); emit('cancel', ''); } }, 1500); }
  function handle(e) {
    var t = e.type, k = e.key;
    if (swallow !== null && e.code === swallow && (t === 'keypress' || t === 'keyup')) {
      if (t === 'keyup') swallow = null;
      e.preventDefault(); e.stopPropagation();
      return true;
    }
    if (t !== 'keydown' || e.isComposing) return false;
    if (k === 'Control' || k === 'Shift' || k === 'Alt' || k === 'Meta' || k === 'AltGraph' || k === 'CapsLock') return false;
    swallow = null;
    if (armed) {
      var was = sub;
      swallow = e.code;
      e.preventDefault(); e.stopPropagation();
      if (k === 'Escape') { disarm(); emit('cancel', ''); return true; }
      if (!was && k === 'P') { sub = true; arm(); emit('armed', 'P'); return true; }   // the project-view namespace: P then one key
      disarm();
      emit('key', was ? 'P' + k : k);
      return true;
    }
    var altgr = e.getModifierState && e.getModifierState('AltGraph');
    if (e.ctrlKey && !e.altKey && !altgr && !e.metaKey && !e.shiftKey && !e.repeat && k === canonPrefixLabel().slice(5)) {
      armed = true; swallow = e.code;
      arm();
      e.preventDefault(); e.stopPropagation();
      emit('armed', '');
      return true;
    }
    return false;
  }
  return { handle: handle, cancel: function () { if (armed) { disarm(); emit('cancel', ''); } } };
}
// canon:prefix-keys:end
let keyHintTimer=null;
function showKeyHint(on,sub){
  const h=document.getElementById('keyhint'); if(!h) return;
  clearTimeout(keyHintTimer);
  if(on&&sub==='P'){ h.innerHTML='<kbd>P</kbd> this project\u2019s tabs — <kbd>n</kbd> next, <kbd>b</kbd> previous, <kbd>f</kbd> first, <kbd>l</kbd> last, <kbd>Esc</kbd> cancel'; h.classList.add('show'); keyHintTimer=setTimeout(()=>showKeyHint(false),1500); }
  else if(on){ h.innerHTML='<kbd>'+esc(canonPrefixLabel())+'</kbd> then a key — <kbd>?</kbd> help, <kbd>Esc</kbd> cancel'; h.classList.add('show'); keyHintTimer=setTimeout(()=>showKeyHint(false),2000); }
  else h.classList.remove('show');
}
export function toggleKeysSheet(open){
  const s=document.getElementById('keys-sheet'); if(!s) return;
  const want=open===undefined?!s.classList.contains('show'):open;
  if(want) document.getElementById('keys-prefix').textContent=canonPrefixLabel();
  s.classList.toggle('show',want);
}
let wAsk=null;   // the tab whose board was asked to fold its side panel; an answer of "nothing open" folds the Workspace sidebar instead
let xAsk=null;   // t-57ab: the tab whose board was asked whether a Terminal is open
function prefixAction(key){
  if(key===canonPrefixLabel().slice(5)){ toggleKeysSheet(true); return; }   // the prefix twice opens the sheet, even if it is rebound to a key below
  const all=['projects'].concat(openTabs.map(t=>t.id));
  if(/^[1-9]$/.test(key)){ const t=openTabs[+key-1]; if(t) goTab(t.id); return; }
  if(key==='n'||key==='b'){ const i=Math.max(0,all.indexOf(activeTab)); goTab(all[(i+(key==='n'?1:-1)+all.length)%all.length]); return; }
  if(key==='p'){ goTab('projects'); return; }
  if(key==='w'){   // the open tab's side panel when it has one on screen, else the Workspace sidebar (t-4077)
    const f=activeTab!=='projects'&&document.querySelector('#view-'+activeTab+' iframe');
    if(!f){ toggleSide(); return; }
    wAsk=activeTab;
    try{ f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'toggle-rail-request'},location.origin); }catch(e){ wAsk=null; toggleSide(); return; }
    const asked=wAsk; setTimeout(()=>{ if(wAsk===asked){ wAsk=null; toggleSide(); } },250);   // a board that is still loading never answers
    return;
  }
  if(key==='c'){ toggleSide(); return; }   // always the Workspace sidebar
  if(key==='a'){ showView('admin'); try{ window.focus(); }catch(e){} return; }   // Admin, like clicking it in the sidebar
  if(key==='f'||key==='l'){ if(openTabs.length) goTab(openTabs[key==='f'?0:openTabs.length-1].id); return; }   // first / last project tab
  if(key==='e'){
    // Only asks the active board to open its own end-session confirmation; ending is never done from here.
    const f=activeTab!=='projects'&&document.querySelector('#view-'+activeTab+' iframe');
    if(f){ try{ f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'end-session-request'},location.origin); }catch(e){} }
    return;
  }
  if(key==='t'){   // t-3c9a: the session menu (Reap now / Kill) for this tab's agent; the tab's board says which session is open
    const f=activeTab!=='projects'&&document.querySelector('#view-'+activeTab+' iframe');
    if(!f){ toast('Open a project tab first \u2014 or right-click a row under Agents'); return; }
    try{ f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'session-menu-request'},location.origin); }catch(e){}
    return;
  }
  if(key==='m'||key==='M'){   // t-57ab: a Terminal in the active project; t-ccf5: as a pane below (m) or beside (M) the tab you are on
    const f=activeTab!=='projects'&&document.querySelector('#view-'+activeTab+' iframe');
    if(!f){ toast('Open a project tab first, then press the prefix and m for a Terminal'); return; }
    try{ f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'open-terminal-request',placement:key==='m'?'below':'beside'},location.origin); }catch(e){}
    return;
  }
  if(key.length===2&&key[0]==='P'&&'nbfl'.includes(key[1])){   // t-ccf5: the project-view keys: next / previous / first / last tab of THIS project
    const f=activeTab!=='projects'&&document.querySelector('#view-'+activeTab+' iframe');
    if(!f){ toast('Open a project tab first, then use P n / b / f / l to move between its tabs'); return; }
    try{ f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'project-tab-request',action:key[1]},location.origin); }catch(e){}
    return;
  }
  if(key==='x'){
    if(activeTab==='projects') return;
    // t-57ab: a live Terminal in this project's board is closed on its own (with its own confirm); with none, the tab closes as before
    const pid=activeTab, f=document.querySelector('#view-'+pid+' iframe');
    if(!f){ closeTab(pid); return; }
    xAsk=pid; setTimeout(()=>{ if(xAsk===pid){ xAsk=null; closeTab(pid); } },800);   // a board that never answers must not make x do nothing
    try{ f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'close-terminal-request'},location.origin); }catch(e){ xAsk=null; closeTab(pid); }
    return;
  }
  if(key==='/'){
    const f=document.querySelector('#view-'+activeTab+' iframe');
    if(f){ try{ f.focus(); f.contentWindow.postMessage({source:'canon-cockpit-shell',type:'focus-search'},location.origin); }catch(e){} }
    return;
  }
  if(key==='v'||key==='-'||key==='V'||key==='_'){   // t-416c: v - take the tab you came from; V _ take the next project tab in the strip
    const beside=key==='v'||key==='V', next=key==='V'||key==='_';
    let other=prevTab;
    if(next){ const i=openTabs.findIndex(t=>t.id===activeTab); other=(i>=0&&openTabs.length>1)?openTabs[(i+1)%openTabs.length].id:null; }
    if(!isProjectTab(activeTab)||!other||other===activeTab||!isProjectTab(other)){ toast('No '+(next?'next':'previous')+' project tab to open '+(beside?'beside':'below')); return; }
    openSplit(activeTab,other,beside?'h':'v'); return;
  }
  if(key==='u'){ if(!split){ toast('No split to close'); return; } closeSplit(); return; }
  if(key==='o'||key==='s'||key==='r'){   // t-416c: act on the split that is on screen
    if(!splitShown()){ toast('No split on screen'); return; }
    if(key==='o'){ goTab(activeTab===split.a?split.b:split.a); return; }
    if(key==='s'){ const t=split.a; split.a=split.b; split.b=t; split.ratio=1-split.ratio; }
    else split.dir=split.dir==='v'?'h':'v';
    saveSplit(); applySplit(); renderTabs(); return;
  }
  if(key==='?') toggleKeysSheet(true);
}
const shellKeys=canonPrefixKeys((type,key)=>{
  if(type==='armed'){ showKeyHint(true,key); return; }
  showKeyHint(false);
  if(type==='key') prefixAction(key);
});
function shellDialogOpen(){ return !!document.querySelector('.scrim.show,.help-overlay.open'); }
function shellKeyBlocked(e){
  const t=e.target;
  if(t&&(t.isContentEditable||/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return true;
  return shellDialogOpen();
}
// t-565f: keys's load-time code, run once at the end (the module version keeps it in initKeys()).
export function initKeys(){
document.addEventListener('DOMContentLoaded',()=>document.getElementById('keys-btn').addEventListener('click',()=>toggleKeysSheet(true)));
['keydown','keypress','keyup'].forEach(type=>document.addEventListener(type,e=>{
  if(type==='keydown'&&shellKeyBlocked(e)){ shellKeys.cancel(); return; }
  shellKeys.handle(e);
},true));
document.addEventListener('DOMContentLoaded',()=>{
  const c=document.getElementById('keys-close'); if(c) c.addEventListener('click',()=>toggleKeysSheet(false));
  const kb=document.getElementById('keys-btn'); if(kb) kb.title='Keyboard shortcuts — '+canonPrefixLabel()+' then ?';
  const s=document.getElementById('keys-sheet'); if(s) s.addEventListener('click',e=>{ if(e.target===s) toggleKeysSheet(false); });
});
window.addEventListener('message',function(e){
  if(e.origin!==location.origin) return;
  const d=e.data;
  if(!d||d.source!=='canon-board') return;
  const pid=senderTab(d);
  if(!pid) return;   // only a project tab's own board
  if(d.type==='scratch-tabs'){ onScratchTabs(d,pid); return; }
  if(d.type==='toggle-rail-ack'){ if(wAsk===pid){ wAsk=null; if(d.handled!==true) toggleSide(); } return; }
  if(d.type==='close-terminal-ack'){ if(xAsk===pid){ xAsk=null; if(d.handled!==true&&pid===activeTab&&!shellDialogOpen()) closeTab(pid); } return; }   // t-57ab
  if(d.type==='logbook-opened'){ logbookOpened(pid); return; }   // t-c6bb: the board has opened its Logbook; stop asking
  if(d.type==='open-factory-github'){ openFactoryGithub(pid); return; }   // t-24b1, t-9641: the picker's "set up first" row
  if(d.type==='session-menu'){ if(pid===activeTab&&!shellDialogOpen()) openTabSessionMenu(pid, typeof d.id==='string'?d.id:''); return; }   // t-3c9a: the reply to prefix then t
  if(d.type==='prefix-armed'||d.type==='prefix-cancel'||d.type==='prefix-key'){   // t-a198: only the visible tab's board speaks
    if(pid!==activeTab||shellDialogOpen()) return;   // a dialog in the shell swallows it, whichever frame had focus
    if(d.type==='prefix-armed'){ showKeyHint(true); return; }
    showKeyHint(false);
    if(d.type==='prefix-key'&&typeof d.key==='string'&&d.key.length<=2) prefixAction(d.key);
    return;
  }
  if(d.type!=='open-session') return;
  if(typeof d.ticket!=='string'||!TICKET_ID_RE.test(d.ticket)) return;
  if(typeof d.project_root!=='string') return;
  openSessionInTab({proot:d.project_root, ticket:d.ticket});
});

// Scoped refresh/close guard: prompt the browser's leave confirmation ONLY when
// at least one open tab has a live agent session. With no live tab, refresh and
// close stay seamless (never a blanket trap); tabs restore from localStorage.
window.addEventListener('beforeunload', function(e){
  if(liveTabIds.size>0){ e.preventDefault(); e.returnValue=''; return ''; }
});
}
