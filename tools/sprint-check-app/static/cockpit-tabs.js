// t-565f: the Cockpit shell's tabs code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initTabs(), which cockpit-main.js runs in order once every module has loaded.
import { esc, toast } from './cockpit-core.js';
import { SCRATCH_ID_RE, TICKET_ID_RE, _projKey, boardScratch, interrupted, liveTabIds, needsTabIds, openCloseWarn, renderInterrupted, renderSessionSurfaces } from './cockpit-sessions.js';
import { getProjects, registerSkill } from './cockpit-projects.js';

// ── Tabs (t-a55a) ────────────────────────────────────────────────────────
// Pinned Projects tab + closable, folder-named project tabs. Each project tab
// is an <iframe src="/?project=<id>"> (read-only board). State {openIds,active}
// persists to localStorage; restore drops ids no longer registered.
const LS_TABS='canon-cockpit-tabs';
export let openTabs=[];            // [{id,name}]
export let activeTab='projects';
export function goTab(id){
  if(split&&splitShown()&&id!==activeTab) startPulse(id);
  activateTab(id);
  const f=id===upkeepPane?null:document.querySelector('#view-'+id+' iframe');   // t-bcce: a board covered by Upkeep is inert, so there is nothing to focus
  lastScriptFocus=Date.now();
  if(f) focusWant={id,until:Date.now()+1500,warned:false};   // t-f769: after the grace below, syncFocusedPane keeps asking for this focus until it lands
  // A click into a pane is the user's own choice: stop asking for the wanted pane (the boards are same-origin).
  if(split) [split.a,split.b].forEach(pid=>{ try{ document.querySelector('#view-'+pid+' iframe').contentDocument.addEventListener('pointerdown',()=>{ focusWant=null; },{capture:true,once:true}); }catch(e){} });
  try{ if(f) f.focus(); else window.focus(); }catch(e){}
}
// t-67ab: which tab's board sent a message. Each tab's iframe gets a random token in its URL
// (ensureView) and its board echoes it; a page without the token can't pose as a tab. Not
// event.source: Safari/WebKit reports this page itself as the source of a board's message.
export const tabTokens=new Map();
export function senderTab(d){ return d && typeof d.tab==='string' ? tabTokens.get(d.tab) || null : null; }
// The project is the sender's own tab, never the message's word for it.
export function onScratchTabs(d,pid){
  if(!Array.isArray(d.tabs)) return;
  const tabs=d.tabs.filter(t=>t&&typeof t.id==='string'&&SCRATCH_ID_RE.test(t.id)).slice(0,20)
    .map(t=>({id:t.id, title:typeof t.title==='string'?t.title.slice(0,80):''}));
  if(tabs.length) boardScratch.set(pid,tabs); else boardScratch.delete(pid);
  renderSessionSurfaces();
}
// Open a session's project tab, then hand its ticket (if any) to that tab's board.
// Shared by the board's open-session message and the t-824e session surfaces.
export function openSessionInTab(v){
  const want=_projKey(v.proot);
  const proj=getProjects().find(p=>_projKey(p.path)===want);
  if(!proj){ toast('Project not registered: '+v.proot); return; }
  openProject(proj.id,proj.name,{nudge:true,quiet:true});   // t-5a4b: Scratch / Continue / rail rows nudge too
  let msg=null;
  if(typeof v.ticket==='string'&&TICKET_ID_RE.test(v.ticket)) msg={source:'canon-cockpit-shell',type:'open-ticket',ticket:v.ticket};
  else if(typeof v.scratch==='string'&&SCRATCH_ID_RE.test(v.scratch)) msg={source:'canon-cockpit-shell',type:'open-scratch',id:v.scratch};
  if(!msg) return;
  const ifr=document.getElementById('view-'+proj.id).querySelector('iframe');
  const send=()=>{ try{ ifr.contentWindow.postMessage(msg, location.origin); }catch(err){} };
  // A just-created tab's iframe is still loading; its board's listener isn't up yet. A fresh iframe
  // reports readyState 'complete' for its initial about:blank, hence the href check.
  if(ifr.contentDocument&&ifr.contentDocument.readyState==='complete'&&ifr.contentWindow.location.href!=='about:blank') send();
  else ifr.addEventListener('load',send,{once:true});
}

function saveTabs(){
  try{localStorage.setItem(LS_TABS,JSON.stringify({openIds:openTabs.map(t=>t.id),active:activeTab}));}catch(e){}
}
export function updateActiveCount(){
  const n=openTabs.length;
  const el=document.getElementById('ncount');
  if(el) el.textContent = getProjects().length+' registered \u00b7 '+(n===0 ? 'none open' : n+' active');
}
let placedPaneTab='';
export function renderTabs(){
  const strip=document.getElementById('tabstrip');
  // keep the pinned Projects tab (first child), rebuild the rest
  document.querySelectorAll('#tabstrip .tab.project,#panebar .tab.project').forEach(n=>n.remove());
  const paneB=splitShown()?split.b:'';   // t-9a6c: pane 2's tab goes in the bar over pane 2
  placedPaneTab=paneB;
  for(const t of openTabs){
    const el=document.createElement('div');
    el.className='tab project'+(activeTab===t.id?' active':'')+(split&&(t.id===split.a||t.id===split.b)?' insplit':'');
    if(split&&(t.id===split.a||t.id===split.b)) el.title='In split view';
    el.addEventListener('contextmenu',ev=>{ ev.preventDefault(); openTabMenu(t.id,ev.clientX,ev.clientY); });
    el.dataset.tab=t.id;
    const liveCls = liveTabIds.has(t.id) ? (needsTabIds.has(t.id) ? ' on needs' : ' on') : '';
    el.innerHTML='<span class="live'+liveCls+'"></span> '+esc(t.name)+' <span class="tx b-neutral" title="Close tab">&#10005;</span>';
    el.addEventListener('click',(ev)=>{ if(ev.target.classList.contains('tx')){closeTab(t.id);} else if(split&&splitShown()){goTab(t.id);} else {activateTab(t.id);} });
    (t.id===paneB?document.getElementById('panebar'):strip).appendChild(el);
  }
  strip.appendChild(document.getElementById('split-close'));   // keep it last, after the rebuilt tabs
  strip.querySelector('.tab.pinned').classList.toggle('active',activeTab==='projects');
  updateActiveCount();
}
function currentTheme(){ return document.documentElement.dataset.theme==='light'?'light':'dark'; }
export function ensureView(id,name){
  const views=document.getElementById('views');
  let v=document.getElementById('view-'+id);
  if(!v){
    v=document.createElement('section');
    v.className='view'; v.id='view-'+id;
    const f=document.createElement('iframe');
    const tok=[...crypto.getRandomValues(new Uint8Array(16))].map(b=>b.toString(16).padStart(2,'0')).join('');
    tabTokens.set(tok,id);
    f.src='/?project='+encodeURIComponent(id)+'&theme='+currentTheme()+'&tab='+tok;
    f.setAttribute('aria-label',name||id);   // t-e523: a title would show as a tooltip over the whole board
    f.addEventListener('load',()=>{ delete paneSent[id]; sendPaneState(); });   // t-416c: a board that loads late still learns its pane state
    v.appendChild(f);
    views.appendChild(v);
    if(interrupted.length) renderInterrupted();   // a project's stopped-session banner belongs in its tab
  }
  return v;
}
// ── Split view (t-416c): two project panes side by side or stacked ───────────
// split = {a,b,dir:'h'|'v',ratio}: pane1 is `a` (left/top), pane2 is `b`. `activeTab` stays the FOCUSED pane. Both views
// are shown by CSS classes only (see .pane1/.pane2); nothing is ever moved in the DOM, because that reloads an iframe.
const LS_SPLIT='canon-cockpit-split';
export let split=null, prevTab=null, lastScriptFocus=0, focusWant=null, upkeepPane=null;   // upkeepPane: the tab whose pane shows Upkeep (t-bcce)
// t-565f: Views and Upkeep set upkeepPane, and the spec resets prevTab; the owner exports these instead of the bindings.
export function setUpkeepPane(id){ upkeepPane=id; }
export function resetPrevTab(){ prevTab=null; }
const SPLIT_MIN={h:280,v:220};
// Each visible board is told whether it is in a split and whether it is the focused pane; `pulse` marks a pane that took
// focus by a tab click or a key (not by a click inside it), which the board shows as a pulsing header until its first interaction.
let pulseTab=null, pulseTimer=null;
const paneSent={};
function sendPaneState(){
  const on=splitShown(), ids=new Set(Object.keys(paneSent));
  if(split){ ids.add(split.a); ids.add(split.b); }
  ids.forEach(id=>{
    const inPair=on&&(id===split.a||id===split.b);
    const st={split:inPair,focused:inPair&&id===activeTab,pulse:inPair&&id===activeTab&&id===pulseTab};
    const key=JSON.stringify(st);
    if(paneSent[id]===key) return;
    const f=document.querySelector('#view-'+id+' iframe');
    if(!f||!f.contentWindow){ delete paneSent[id]; return; }
    try{ f.contentWindow.postMessage(Object.assign({source:'canon-cockpit-shell',type:'pane-state'},st),location.origin); paneSent[id]=key; }catch(e){}
    if(!inPair) delete paneSent[id];
  });
}
function startPulse(id){
  pulseTab=id; clearTimeout(pulseTimer);
  pulseTimer=setTimeout(()=>{ pulseTab=null; sendPaneState(); },4000);
}
export const isProjectTab=id=>openTabs.some(t=>t.id===id);
export function splitShown(){
  if(!split||(activeTab!==split.a&&activeTab!==split.b)) return false;
  const v=document.getElementById('view-'+activeTab);
  return !!v&&v.classList.contains('active');
}
function clampRatio(r){
  const views=document.getElementById('views');
  const total=split.dir==='v'?views.clientHeight:views.clientWidth, edge=SPLIT_MIN[split.dir]+3;
  if(!(total>2*edge)) return .5;
  return Math.min(1-edge/total,Math.max(edge/total,r));
}
export function saveSplit(){
  try{ if(split) localStorage.setItem(LS_SPLIT,JSON.stringify(split)); else localStorage.removeItem(LS_SPLIT); }catch(e){}
}
function restoreSplit(){
  let s=null; try{ s=JSON.parse(localStorage.getItem(LS_SPLIT)||'null'); }catch(e){}
  if(!s||typeof s!=='object'||!isProjectTab(s.a)||!isProjectTab(s.b)||s.a===s.b) return;
  split={a:s.a,b:s.b,dir:s.dir==='v'?'v':'h',ratio:(typeof s.ratio==='number'&&s.ratio>.05&&s.ratio<.95)?s.ratio:.5};
}
export function applySplit(){
  if((splitShown()?split.b:'')!==placedPaneTab) renderTabs();   // t-9a6c: the pane-2 tab moves with the split
  const views=document.getElementById('views'), handle=document.getElementById('split-handle');
  document.querySelectorAll('.view.pane1,.view.pane2').forEach(v=>v.classList.remove('pane1','pane2'));
  document.querySelectorAll('.view[inert]').forEach(v=>v.removeAttribute('inert'));
  views.classList.remove('split-h','split-v');
  const sc=document.getElementById('split-close'); if(sc) sc.hidden=!splitShown();
  if(!splitShown()){ upkeepPane=null; sendPaneState(); return; }
  const va=document.getElementById('view-'+split.a), vb=document.getElementById('view-'+split.b);
  if(!va||!vb){ split=null; upkeepPane=null; saveSplit(); sendPaneState(); return; }
  va.classList.add('pane1'); vb.classList.add('pane2');
  const uv=document.getElementById('view-upkeep');   // t-bcce: Upkeep sits over its own pane
  if(upkeepPane===split.a) uv.classList.add('pane1'); else if(upkeepPane===split.b) uv.classList.add('pane2'); else upkeepPane=null;
  if(upkeepPane) document.getElementById('view-'+upkeepPane).setAttribute('inert','');   // the board under Upkeep takes no focus or keys
  views.classList.add(split.dir==='v'?'split-v':'split-h');
  split.ratio=clampRatio(split.ratio);
  views.style.setProperty('--r',split.ratio);
  const total=split.dir==='v'?views.clientHeight:views.clientWidth, edge=SPLIT_MIN[split.dir]+3;
  handle.setAttribute('aria-orientation',split.dir==='v'?'horizontal':'vertical');
  handle.setAttribute('aria-valuenow',Math.round(split.ratio*100));
  handle.setAttribute('aria-valuemin',total>2*edge?Math.ceil(edge/total*100):50);
  handle.setAttribute('aria-valuemax',total>2*edge?Math.floor((1-edge/total)*100):50);
  sendPaneState();
}
export function openSplit(a,b,dir){
  // A project is never in two panes: the same tab, or one that is not open, is refused.
  if(a===b||!isProjectTab(a)||!isProjectTab(b)){ toast('Pick another open project tab'); return false; }
  const same=split&&((split.a===a&&split.b===b)||(split.a===b&&split.b===a));
  split=same?Object.assign({},split,{dir}):{a,b,dir,ratio:.5};
  saveSplit(); activateTab(a); return true;
}
export function closeSplit(){ split=null; pulseTab=null; saveSplit(); applySplit(); renderTabs(); }
const tabMenu=document.getElementById('tabmenu');
let menuOpener=null;
export function closeTabMenu(){
  if(!tabMenu||tabMenu.hidden) return;
  const back=tabMenu.contains(document.activeElement)?menuOpener:null;
  tabMenu.hidden=true; menuOpener=null;
  if(back&&back.isConnected) back.focus();   // Esc from the keyboard returns to the row or tab it opened from
}
// t-3c9a: the one shell menu (tabs, Agents rows). items: {label, fn, disabled, hint, title, danger}, {sep:true}, or
// {head, sub}: a non-focusable heading naming what the menu acts on.
export function openMenu(items,x,y){
  if(!tabMenu) return;
  menuOpener=document.activeElement;
  tabMenu.innerHTML='';
  for(const it of items){
    if(it.sep){ const d=document.createElement('div'); d.className='sep'; tabMenu.appendChild(d); continue; }
    if(it.head){
      const d=document.createElement('div'); d.className='head'; d.textContent=it.head; d.title=it.head+(it.sub?'\n'+it.sub:'');
      if(it.sub){ const s=document.createElement('small'); s.textContent=it.sub; d.appendChild(s); }
      tabMenu.appendChild(d); continue;
    }
    const b=document.createElement('button'); b.type='button'; b.setAttribute('role','menuitem'); b.disabled=!!it.disabled;
    if(it.danger) b.classList.add('b-danger');
    if(it.title) b.title=it.title;
    const l=document.createElement('span'); l.textContent=it.label; b.appendChild(l);
    if(it.hint){ const h=document.createElement('span'); h.className='hint'; h.textContent=it.hint; b.appendChild(h); }
    b.addEventListener('click',()=>{ closeTabMenu(); it.fn(); }); tabMenu.appendChild(b);
  }
  tabMenu.hidden=false;
  tabMenu.style.left=Math.max(4,Math.min(x,window.innerWidth-tabMenu.offsetWidth-4))+'px';
  tabMenu.style.top=Math.max(4,Math.min(y,window.innerHeight-tabMenu.offsetHeight-4))+'px';
  const first=tabMenu.querySelector('button:not(:disabled)'); if(first) first.focus();
}
function openTabMenu(tid,x,y){
  const canPair=isProjectTab(activeTab)&&tid!==activeTab;
  const paired=!!split&&(split.a===tid||split.b===tid);   // already in the split: nothing is added, the direction changes and that pane takes focus
  const open=dir=>{ if(openSplit(activeTab,tid,dir)&&paired) goTab(tid); };
  const items=[{label:'Open beside the active tab',fn:()=>open('h'),disabled:!canPair},{label:'Open below the active tab',fn:()=>open('v'),disabled:!canPair}];
  if(split) items.push({label:'Close split',fn:closeSplit});
  openMenu(items,x,y);
}
export function activateTab(id){
  const from=activeTab;
  if(from!==id&&isProjectTab(from)) prevTab=from;   // where "v" and "-" take the second pane from
  // While the split is on screen, a project tab outside the pair takes over the focused pane.
  if(split&&splitShown()&&isProjectTab(id)&&id!==split.a&&id!==split.b){
    if(from===split.a) split.a=id; else if(from===split.b) split.b=id;
    saveSplit();
  }
  activeTab=id;
  document.querySelectorAll('.view').forEach(v=>v.classList.remove('active'));
  const v=document.getElementById('view-'+id) || document.getElementById('view-projects');
  v.classList.add('active');
  // activating any tab means we're in the Projects workspace, not Admin/Factory/Upkeep (t-5dc2, t-7ae6, t-9641)
  const np=document.getElementById('nav-projects');
  if(np) np.classList.add('active');
  ['nav-admin','nav-factory'].forEach(n=>{ const a=document.getElementById(n); if(a) a.classList.remove('active'); });
  renderTabs();
  saveTabs();
  applySplit();
}
export function openProject(id,name,opts){
  opts=opts||{};
  if(!openTabs.some(t=>t.id===id)){ openTabs.push({id,name}); ensureView(id,name); }
  activateTab(id);
  if(opts.nudge) maybeNudgeSkill(id,name,opts.quiet);   // t-5c3c: only on explicit open, never on restore
}
async function hasSprintSkill(id){
  try{ const s=await fetch('/api/project-stats?project='+encodeURIComponent(id)); if(s.ok) return ((await s.json()).skills||[]).includes('sprint'); }catch(e){}
  return false;   // fetch failed → assume sprintless (fail toward showing/keeping the nudge)
}
// t-5c3c: soft nudge — when a project opened via the card lacks the sprint
// skill, show an inline banner offering to register it. The board still opens;
// Dismiss hides it for this open (reopening nudges again). Never a hard block.
const nudgeDismissed=new Set();   // t-5a4b: a banner dismissed once isn't re-shown by session-driven opens (until reload)
async function maybeNudgeSkill(id,name,quiet){
  const v=document.getElementById('view-'+id);
  if(!v || v.querySelector('.skill-nudge')) return;
  if(quiet && nudgeDismissed.has(id)) return;
  if(await hasSprintSkill(id)) return;
  if(v.querySelector('.skill-nudge')) return;   // re-check post-await: a concurrent open may have inserted one
  const proj=getProjects().find(p=>p.id===id)||{};
  const bar=document.createElement('div');
  bar.className='skill-nudge';
  const msg=document.createElement('span'); msg.className='sn-msg';
  msg.textContent='This project doesn’t have the canon “sprint” skill registered.';
  const actions=document.createElement('span'); actions.className='sn-actions'; actions.setAttribute('aria-live','polite');
  const reg=document.createElement('button'); reg.className='btn b-primary sn-reg'; reg.textContent='Register sprint';
  const x=document.createElement('button'); x.className='sn-x'; x.title='Dismiss'; x.textContent='✕';
  actions.appendChild(reg); actions.appendChild(x);
  bar.appendChild(msg); bar.appendChild(actions);
  v.classList.add('has-nudge');
  v.insertBefore(bar, v.firstChild);
  x.addEventListener('click',()=>{ bar.remove(); v.classList.remove('has-nudge'); nudgeDismissed.add(id); });
  reg.addEventListener('click',async()=>{
    await registerSkill(id, name, proj.path||'', 'sprint', reg);  // reuses the themed cockpitConfirm flow
    if(await hasSprintSkill(id)){ bar.remove(); v.classList.remove('has-nudge'); }
  });
}
export function _removeTab(id){
  openTabs=openTabs.filter(t=>t.id!==id);
  for(const [tok,pid] of tabTokens) if(pid===id) tabTokens.delete(tok);
  const v=document.getElementById('view-'+id); if(v) v.remove();
  // Closing either paired tab ends the split; the other one stays, full size.
  if(split&&(id===split.a||id===split.b)){
    const other=id===split.a?split.b:split.a;
    split=null; saveSplit();
    if(activeTab===id) activeTab=isProjectTab(other)?other:'projects';
  } else if(activeTab===id) activeTab='projects';
  activateTab(activeTab);
}
// t-0db3: closing a tab with a LIVE agent session warns first (Save & End /
// End without saving / Keep working) — never a silent orphan/kill (t-f6b6
// lineage). An idle tab closes straight to Projects, as before.
export function closeTab(id){
  if(liveTabIds.has(id)){ openCloseWarn(id); return; }
  _removeTab(id);
}
export function restoreTabs(){
  let saved=null;
  try{saved=JSON.parse(localStorage.getItem(LS_TABS)||'null');}catch(e){}
  if(!saved||!Array.isArray(saved.openIds)) return;
  // drop ids no longer registered (deregistered while closed)
  const byId=new Map(getProjects().map(p=>[p.id,p]));
  for(const id of saved.openIds){
    const p=byId.get(id);
    if(p && !openTabs.some(t=>t.id===id)){ openTabs.push({id:p.id,name:p.name}); ensureView(p.id,p.name); }
  }
  if(saved.active && (saved.active==='projects' || byId.has(saved.active))) activeTab=saved.active;
  restoreSplit();
  renderTabs(); activateTab(activeTab);
}
// t-565f: tabs's load-time code, run once at the end (the module version keeps it in initTabs()).
export function initTabs(){
(function wireSplitHandle(){
  const handle=document.getElementById('split-handle'), views=document.getElementById('views');
  if(!handle) return;
  let dragging=false;
  const move=e=>{
    if(!dragging||!split) return;
    const r=views.getBoundingClientRect();
    split.ratio=clampRatio(split.dir==='v'?(e.clientY-r.top)/r.height:(e.clientX-r.left)/r.width);
    applySplit();
  };
  handle.addEventListener('pointerdown',e=>{ dragging=true; handle.classList.add('drag'); try{ handle.setPointerCapture(e.pointerId); }catch(err){} e.preventDefault(); });
  handle.addEventListener('pointermove',move);
  const stop=()=>{ if(!dragging) return; dragging=false; handle.classList.remove('drag'); saveSplit(); };
  handle.addEventListener('pointerup',stop); handle.addEventListener('pointercancel',stop);
  handle.addEventListener('dblclick',()=>{ if(!split) return; split.ratio=.5; applySplit(); saveSplit(); });
  handle.addEventListener('keydown',e=>{
    if(!split) return;
    const step=e.shiftKey?.1:.02, back=split.dir==='v'?'ArrowUp':'ArrowLeft', fwd=split.dir==='v'?'ArrowDown':'ArrowRight';
    if(e.key===back||e.key===fwd){ e.preventDefault(); split.ratio+=(e.key===fwd?step:-step); }
    else if(e.key==='Home'){ e.preventDefault(); split.ratio=.5; }
    else return;
    applySplit(); saveSplit();
  });
  window.addEventListener('resize',applySplit);
  // Which pane has focus: ask each pane's own document (the boards are same-origin; a nested terminal frame counts as inside it).
  // document.activeElement here is NOT reliable: after the shell focuses a pane by script, a later click into the other pane
  // leaves it pointing at the old iframe. The first entry into a frame blurs this window; moving between two panes fires
  // nothing at all, so a light poll runs while a split is on screen.
  const paneHasFocus=id=>{ try{ const f=document.querySelector('#view-'+id+' iframe'); return !!(f&&f.contentDocument&&f.contentDocument.hasFocus()); }catch(e){ return false; } };
  const syncFocusedPane=()=>{
    if(!splitShown()||Date.now()-lastScriptFocus<500) return;   // a focus the shell just set takes a moment to land
    if(focusWant){   // a focus the shell just set can land late (seen on Windows): keep asking for it instead of following the old pane back
      if(Date.now()>focusWant.until||paneHasFocus(focusWant.id)) focusWant=null;
      else {
        if(!focusWant.warned){ focusWant.warned=true; console.warn('canon: pane focus did not land yet, retrying (t-f769)'); }
        try{ const f=document.querySelector('#view-'+focusWant.id+' iframe'); if(f) f.focus(); }catch(e){}
        return;
      }
    }
    const id=[split.a,split.b].find(paneHasFocus);
    if(id&&id!==activeTab){ pulseTab=null; activateTab(id); }
  };
  window.addEventListener('blur',()=>setTimeout(syncFocusedPane,0));
  setInterval(syncFocusedPane,200);
})();
document.getElementById('split-close').addEventListener('click',closeSplit);
document.addEventListener('pointerdown',e=>{ if(tabMenu&&!tabMenu.hidden&&!tabMenu.contains(e.target)) closeTabMenu(); },true);
window.addEventListener('blur',()=>closeTabMenu());   // t-3c9a: a click into a board iframe never reaches the pointerdown above
if(tabMenu) tabMenu.addEventListener('keydown',e=>{   // t-3c9a: arrow keys move between the enabled items
  if(e.key!=='ArrowDown'&&e.key!=='ArrowUp') return;
  e.preventDefault();
  const bs=[...tabMenu.querySelectorAll('button:not(:disabled)')]; if(!bs.length) return;
  const i=bs.indexOf(document.activeElement), n=bs.length;
  bs[(i<0?0:i+(e.key==='ArrowDown'?1:n-1))%n].focus();
});
document.addEventListener('DOMContentLoaded',()=>document.querySelector('#tabstrip .tab.pinned').addEventListener('click',()=>activateTab('projects')));
}
