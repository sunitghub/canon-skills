// t-565f: the Cockpit shell's sessions code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initSessions(), which cockpit-main.js runs in order once every module has loaded.
import { esc, escAttr, toast } from './cockpit-core.js';
import { fmtUptime, renderAdminSessions } from './cockpit-admin.js';
import { _removeTab, openSessionInTab, openTabs, renderTabs } from './cockpit-tabs.js';
import { getProjects } from './cockpit-projects.js';

export let liveTabIds=new Set();   // t-0db3: open tab ids whose project has a live agent session
export let needsTabIds=new Set();  // t-824e: open tab ids whose project has a session waiting on you
let lastSessions=[];        // t-824e: last /api/cockpit-sessions rows, shared by every surface
let pendingCloseId=null;    // tab awaiting the close-warn decision
let closingTabs=new Set();  // tabs told to Save&End/End — removed once their session ends

// ── Live agent-session guard (t-0db3) ──────────────────────────────────────
// Detect which open tabs have a running agent by polling the existing
// /api/cockpit-sessions (daemon truth across all projects) and matching a
// session's project_root to the tab's registered project path. No cross-origin
// messaging needed for detection. Drives the tab .live dot + the close/refresh
// guard. Idle tabs are never trapped.
export function _normPath(p){ return String(p||'').replace(/[\\/]+$/,''); }
export async function pollSessions(){
  let sessions=[];
  try{ const s=await fetch('/api/cockpit-sessions'); if(s.ok) sessions=await s.json(); }catch(e){}
  if(!Array.isArray(sessions)) sessions=[];
  const liveRoots=new Set(sessions.map(s=>_normPath(s&&s.project_root)).filter(Boolean));
  const needRoots=new Set(sessions.filter(s=>sessionView(s).state==='needs-you').map(s=>_normPath(s.project_root)).filter(Boolean));
  const byId=new Map(getProjects().map(p=>[p.id,_normPath(p.path)]));
  const next=new Set(), nextNeeds=new Set();
  for(const t of openTabs){
    const path=byId.get(t.id);
    if(path && liveRoots.has(path)) next.add(t.id);
    if(path && needRoots.has(path)) nextNeeds.add(t.id);
  }
  // only re-render if the live or needs-you set actually changed
  const differs=(a,b)=>a.size!==b.size || [...a].some(id=>!b.has(id));
  const changed = differs(next,liveTabIds) || differs(nextNeeds,needsTabIds);
  liveTabIds=next; needsTabIds=nextNeeds;
  lastSessions=sessions;
  renderSessionSurfaces();
  notifyNeedsYou(sessions.map(sessionView));
  // A tab awaiting close (Save&End/End) is removed once its session has ended
  // — the daemon finished the save/end turn, so no orphan and no premature
  // iframe teardown.
  for(const id of [...closingTabs]){ if(!next.has(id)){ closingTabs.delete(id); _removeTab(id); } }
  if(changed) renderTabs();
}
export function startSessionPoll(){ pollSessions(); setInterval(pollSessions, 5000); pollInterrupted(); setInterval(pollInterrupted, 15000); }

// ── t-d9e6: sessions that were running when the daemon stopped ─────────────
// The board server lists them (resumable, or why not); Resume dismisses the entry and
// opens the ticket's cockpit, where Resume is one click — nothing starts by itself.
export let interrupted=[];
let adminViews=null;   // last live rows (null until the first sessions poll), so the Admin card can redraw when stopped ones change
// A project banner's Dismiss only hides the entry there (remembered per browser); Admin keeps it
// until it is dismissed there, which is the one real dismissal (plus Resume). Keyed id|started.
const HIDE_KEY='ck-intr-hidden';
let hiddenHere=new Set();
const intrKey=e=>e.id+'|'+e.started;
function saveHidden(){ try{ localStorage.setItem(HIDE_KEY,JSON.stringify([...hiddenHere])); }catch(e){} }
function pruneHidden(){ const live=new Set(interrupted.map(intrKey)), kept=[...hiddenHere].filter(k=>live.has(k)); if(kept.length===hiddenHere.size) return; hiddenHere=new Set(kept); saveHidden(); }
function hideInterrupted(e){ hiddenHere.add(intrKey(e)); saveHidden(); renderInterrupted(); }
export async function pollInterrupted(){
  let list=[], ok=false;
  try{ const r=await fetch('/api/cockpit-interrupted'); if(r.ok){ list=await r.json(); ok=true; } }catch(e){}
  interrupted=(Array.isArray(list)?list:[]).filter(e=>e && (TICKET_ID_RE.test(e.id)||SCRATCH_ID_RE.test(e.id)) && typeof e.project_root==='string');
  if(ok) pruneHidden();
  refreshInterrupted();
}
export async function dismissInterrupted(id){
  try{
    const r=await fetch('/api/cockpit-interrupted-dismiss',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})});
    if(!r.ok) throw new Error();
  }catch(e){ toast('Could not dismiss '+id); return false; }
  interrupted=interrupted.filter(e=>e.id!==id);
  refreshInterrupted();
  return true;
}
export async function resumeInterrupted(e){
  const proj=getProjects().find(p=>_projKey(p.path)===_projKey(e.project_root));
  if(!proj){ toast('Project not registered: '+e.project_root); return; }
  if(await dismissInterrupted(e.id)) openSessionInTab({proot:e.project_root, ticket:e.id});
}
export const intrProj=e=>getProjects().find(p=>_projKey(p.path)===_projKey(e.project_root));
export const intrSince=e=>{ const d=new Date(e.started); return isNaN(d)?'':d.toLocaleString([],{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}); };
// A stopped session belongs to its project: the banner sits in that project's tab, and the
// Admin card lists every one (an unregistered project has no tab, so Admin is its only home).
export function renderInterrupted(){
  ensureTicketTitles(interrupted.map(e=>({pid:(intrProj(e)||{}).id||'', ticket:TICKET_ID_RE.test(e.id)?e.id:''})));
  for(const t of openTabs){
    const v=document.getElementById('view-'+t.id); if(!v) continue;
    let box=v.querySelector(':scope > .intr-banner');
    const mine=interrupted.filter(e=>(intrProj(e)||{}).id===t.id && !hiddenHere.has(intrKey(e)));
    if(!mine.length){ if(box) box.remove(); v.classList.remove('has-intr'); continue; }
    if(!box){ box=document.createElement('div'); box.className='intr-banner'; v.insertBefore(box,v.firstChild); }
    v.classList.add('has-intr');
    fillInterrupted(box,mine,t.id);
  }
}
function refreshInterrupted(){ renderInterrupted(); if(adminViews) renderAdminSessions(adminViews); paintStopped(); }
// Attention outside the banner: a count bubble on the Admin nav item, and a Stopped row on each
// project's card. Both count every entry the daemon still lists, hidden-in-project or not.
function paintStopped(){
  const b=document.getElementById('admin-bubble');
  if(b){ b.hidden=interrupted.length===0; b.textContent=interrupted.length; b.title=interrupted.length+' stopped agent session'+(interrupted.length===1?'':'s')+' waiting for you'; }
  for(const p of getProjects()){
    const sel=window.CSS&&CSS.escape?CSS.escape(p.id):p.id;
    const meta=document.querySelector('.meta[data-stats="'+sel+'"]');
    const row=meta&&meta.querySelector('[data-f="stopped-row"]'); if(!row) continue;
    const n=interrupted.filter(e=>_projKey(e.project_root)===_projKey(p.path)).length;
    row.hidden=n===0;
    row.querySelector('[data-f="stopped"]').textContent=n?String(n):'';
  }
}
function fillInterrupted(box,list,pid){
  box.textContent='';
  const el=(tag,cls,text)=>{ const n=document.createElement(tag); if(cls) n.className=cls; if(text!=null) n.textContent=text; return n; };
  const head=el('div','intr-head');
  const n=list.length;
  head.append(el('span','',n+' session'+(n===1?' was':'s were')+' running when the daemon stopped'));
  const resumable=list.filter(e=>e.resumable===true);
  if(resumable.length>1){
    const all=el('button','intr-btn primary','Resume all');
    all.dataset.act='resume-all';
    all.addEventListener('click',async()=>{ for(const e of resumable) await resumeInterrupted(e); });
    head.append(all);
  }
  box.append(head);
  for(const e of list){
    const row=el('div','intr-row'); row.dataset.id=e.id;
    const what=el('div','intr-what');
    what.append(el('b','',e.id));
    const title=TICKET_ID_RE.test(e.id)?ticketTitle(pid,e.id):'';
    if(title) what.append(document.createTextNode(title));
    what.append(el('span','intr-meta',[e.agent,intrSince(e)&&'since '+intrSince(e)].filter(Boolean).join(' \u00b7 ')));
    if(e.resumable!==true && e.reason) what.append(el('span','intr-reason','Can\u2019t resume: '+e.reason));
    row.append(what);
    if(e.resumable===true){
      const b=el('button','intr-btn primary','Resume'); b.dataset.act='resume';
      b.addEventListener('click',()=>resumeInterrupted(e)); row.append(b);
    }
    const d=el('button','intr-btn','Dismiss'); d.dataset.act='dismiss';
    d.title='Hides it here \u2014 Admin keeps it until you dismiss it there.';
    d.addEventListener('click',()=>hideInterrupted(e)); row.append(d);
    box.append(row);
  }
}

// ── Session state (t-824e) ─────────────────────────────────────────────────
// The daemon owns each session's state (/sessions "state"); every surface below
// reads it through sessionView. A daemon older than t-824e sends only "status",
// so fall back to needs-you / running with no working/idle split or countdown.
const STATE_LABEL={'needs-you':'needs you','done':'done \u00b7 waiting for your next prompt','working':'working','idle':'idle','running':'running'};
const STATE_SHORT={'needs-you':'needs you','done':'done','working':'working','idle':'idle','running':'running'};
const SIGNAL_LABEL={'hook':'Claude Code notification hook','copilot-menu':'Copilot approval menu','activity':'terminal activity only (no question signal)'};
// Session durations: unlike fmtUptime (where 0 means "no value"), 0 s is a real time here.
export function fmtDur(secs){ return secs<60 ? Math.floor(secs)+'s' : fmtUptime(secs); }
// t-e69b: ticket titles, fetched once per (project, ticket) from the ticket's own
// ticket.md — /api/tickets carries every body and is far too big to poll. A failed
// lookup caches '' (the row shows the id alone); null marks one in flight.
const ticketTitles=new Map();
export function ticketTitle(pid, ticket){ return ticketTitles.get(pid+'/'+ticket)||''; }
function ensureTicketTitles(views){
  for(const v of views){
    if(!v.pid || !v.ticket) continue;
    const key=v.pid+'/'+v.ticket;
    if(ticketTitles.has(key)) continue;
    ticketTitles.set(key,null);
    fetch('/api/doc/'+encodeURIComponent(v.ticket)+'/ticket.md?project='+encodeURIComponent(v.pid))
      .then(r=>r.ok?r.json():null)
      .then(j=>{
        // Frontmatter `title:` wins (as the board reads it), else the first `# ` heading.
        const text=String((j&&j.content)||'');
        const fm=text.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
        const fmTitle=fm && fm[1].match(/^title:[ \t]*(.+)$/m);
        const h1=text.slice(fm?fm[0].length:0).match(/^# +(.+)$/m);
        const title=((fmTitle?fmTitle[1].trim().replace(/^(['"])(.*)\1$/,'$2'):'') || (h1?h1[1]:'')).trim().slice(0,200);
        ticketTitles.set(key, title);
        if(title) renderSessionSurfaces();
      })
      .catch(()=>ticketTitles.set(key,''));
  }
}
export function sessionView(s){
  s=s||{};
  const state=(typeof s.state==='string' && STATE_LABEL[s.state]) ? s.state : (s.status==='needs-you' ? 'needs-you' : 'running');
  const num=v=>(typeof v==='number' && isFinite(v) && v>=0) ? v : null;
  const since=num(s.state_secs), idle=num(s.idle_secs), limit=num(s.idle_limit_secs);
  const reapIn=(limit!==null && idle!==null) ? Math.max(0,limit-idle) : null;
  let reaper='';
  if(state==='needs-you') reaper='paused \u00b7 waiting on you';
  else if(reapIn!==null) reaper='auto-save & end in '+(reapIn>0 ? fmtDur(reapIn) : 'under a minute');
  const proot=String(s.project_root||''), ticket=String(s.ticket||'');
  const proj=getProjects().find(p=>_projKey(p.path)===_projKey(proot));
  const startMs=Date.parse(s.started);   // t-aca6: the daemon's session start (RFC 3339); missing on old daemons
  return {
    elapsed:isNaN(startMs)?null:Math.max(0,Math.round((Date.now()-startMs)/1000)), startMs:isNaN(startMs)?null:startMs,
    state, label:STATE_LABEL[state], short:STATE_SHORT[state], since, reaper, reapIn, pid:proj?proj.id:'', projName:proj?proj.name:'',
    signal:SIGNAL_LABEL[s.signal]||'',
    ticket:TICKET_ID_RE.test(ticket)?ticket:'',
    scratch:SCRATCH_ID_RE.test(ticket)?ticket:'',   // t-47f1: a scratch session (s-xxxx), no ticket
    scrTitle:SCRATCH_ID_RE.test(ticket)?String(s.title||'').slice(0,80):'',   // t-f553: its user-given title
    proot, name:proot.split(/[\\/]/).filter(Boolean).pop()||proot,
    agent:String(s.agent||''), cwd:String(s.cwd||''), sid:String(s.session||''),
    shared:s.shared===true,   // t-5a4b: another live session works in this same folder, and there is no git to keep them apart
  };
}
// t-f553: open scratch tabs the daemon doesn't report yet — the agent picker is still up.
function notStartedScratch(live){
  const out=[];
  for(const [pid,tabs] of boardScratch){
    const proj=getProjects().find(p=>p.id===pid);
    if(!proj) continue;
    for(const t of tabs) if(!live.has(t.id)) out.push({
      state:'not-started', label:'not started \u00b7 pick an agent to start it', short:'not started', since:null, reaper:'', reapIn:null, elapsed:null, startMs:null,
      pid, projName:proj.name, signal:'', ticket:'', scratch:t.id, scrTitle:t.title, proot:proj.path,
      name:String(proj.path).split(/[\\/]/).filter(Boolean).pop()||proj.path, agent:'', cwd:'', sid:'',
    });
  }
  return out;
}
// t-aca6: the sidebar's third line and Admin's sub-line: the project and the time spent in the session so far.
// full fits most rows; short drops "in session" when full would be cut off; tip spells everything out.
export function sessionTime(v){
  const proj=v.projName||v.name;
  if(v.elapsed===null) return { full:proj, short:proj, tip:proj, dur:'' };
  const dur=fmtDur(v.elapsed);
  const at=new Date(v.startMs).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
  return { full:proj+' \u00b7 '+dur+' in session', short:proj+' \u00b7 '+dur, tip:proj+' \u2014 '+dur+' in session (started '+at+')', dur };
}
// Sidebar state line: short, with the countdown where the reaper applies.
// Sidebar state line, Herdr-style: state (+ age), the agent, then the reap countdown where it applies.
function agentLine(v){
  const since=v.since!==null ? fmtDur(v.since) : '';
  const agent=v.agent ? ' \u00b7 '+v.agent : '';
  const reaps=v.reapIn!==null ? ' \u00b7 reaps in '+fmtDur(v.reapIn) : '';
  if(v.state==='needs-you') return 'needs you'+(since?' \u00b7 '+since:'')+agent;
  if(v.state==='not-started') return 'not started';
  if(v.state==='idle' || v.state==='done') return v.short+(since?' '+since:'')+agent+reaps;
  return v.short+agent;
}
// t-5a4b: two sessions in one folder without git can overwrite each other — say so, once, under
// the project. Dismissing hides it until the sharing stops and starts again.
const sharedDismissed=new Set();
function syncSharedWarnings(views){
  const sharing=new Set(views.filter(v=>v.shared&&v.pid).map(v=>v.pid));
  for(const id of [...sharedDismissed]) if(!sharing.has(id)) sharedDismissed.delete(id);
  document.querySelectorAll('.shared-warn').forEach(b=>{ if(!sharing.has(b.dataset.pid)||sharedDismissed.has(b.dataset.pid)){ const v=b.parentElement; b.remove(); if(v) v.classList.remove('has-shared'); } });
  for(const id of sharing){
    const v=document.getElementById('view-'+id);
    if(!v||sharedDismissed.has(id)||v.querySelector('.shared-warn')) continue;
    const bar=document.createElement('div'); bar.className='shared-warn'; bar.dataset.pid=id; bar.setAttribute('role','status');
    const msg=document.createElement('span'); msg.className='sn-msg';
    msg.textContent='More than one agent is working in this folder. They can overwrite each other\u2019s changes \u2014 fine for reading and running tests, risky if both edit the same files.';
    const x=document.createElement('button'); x.className='sn-x'; x.title='Dismiss'; x.textContent='\u2715';
    x.addEventListener('click',()=>{ sharedDismissed.add(id); bar.remove(); v.classList.remove('has-shared'); });
    bar.appendChild(msg); bar.appendChild(x);
    v.classList.add('has-shared'); v.insertBefore(bar,v.firstChild);
  }
}
// t-565f: lastSessions is written from Admin's refresh too; the owner exports this instead of the binding.
export function setLastSessions(rows){ lastSessions=rows; }
export function renderSessionSurfaces(){
  const views=lastSessions.map(sessionView);
  ensureTicketTitles(views);
  // Sidebar Agents, grouped by project.
  const live=new Set(views.map(v=>v.scratch).filter(Boolean));
  const rail=views.concat(notStartedScratch(live));
  const groups=new Map();
  for(const v of rail){ const k=_projKey(v.proot); if(!groups.has(k)) groups.set(k,[]); groups.get(k).push(v); }
  const list=document.getElementById('ag-list');
  list.innerHTML=rail.length===0 ? '<div class="ag-empty">No agents running</div>' : [...groups.values()].map(g=>
    `<div class="ag-proj" title="${escAttr(g[0].proot)}"><b>${esc(g[0].projName||g[0].name)}</b><span>${g.length}</span>${g[0].pid?`<button class="ag-plus" data-scratch="${escAttr(g[0].pid)}" title="New scratch session in ${escAttr(g[0].projName||g[0].name)}" aria-label="New scratch session">+</button>`:''}</div>`+g.map(v=>{
      const title=ticketTitle(v.pid,v.ticket), time=sessionTime(v);
      return `<button class="ag-row st st-${v.state}" data-i="${rail.indexOf(v)}" title="${escAttr((title?title+' \u2014 ':'')+v.label+(v.signal?(' \u00b7 state from: '+v.signal):''))}">`+
      `<span class="sdot"></span>`+
      `<span class="ag-t1">${v.ticket?`<span class="ag-id">${esc(v.ticket)}</span>${esc(title)}`:(v.scratch?`${SCRATCH_ICON}${esc(v.scrTitle||'Scratch session')}`:'<span class="ag-none">no ticket</span>')}</span>`+
      `<span class="ag-s">${esc(agentLine(v))}</span>`+
      `<span class="ag-p" title="${escAttr(time.tip)}" data-short="${escAttr(time.short)}">${esc(time.full)}</span></button>`;
    }).join('')
  ).join('');
  // t-aca6 (user): when "<project> · <dur> in session" would be cut off, show "<project> · <dur>"; the title has it all.
  // Measure every line before changing any, so the browser lays out once, not once per row.
  [...list.querySelectorAll('.ag-p')].filter(el=>el.scrollWidth>el.clientWidth).forEach(el=>{ el.textContent=el.dataset.short; });
  syncSharedWarnings(views);
  list.querySelectorAll('.ag-row').forEach(b=>b.addEventListener('click',()=>openSessionInTab(rail[+b.dataset.i])));
  list.querySelectorAll('.ag-plus').forEach(b=>b.addEventListener('click',()=>startScratch(b.dataset.scratch)));
  // Projects cards: counts by state.
  for(const p of getProjects()){
    const sel=window.CSS&&CSS.escape?CSS.escape(p.id):p.id;
    const meta=document.querySelector('.meta[data-stats="'+sel+'"]');
    if(!meta) continue;
    const mine=views.filter(v=>_projKey(v.proot)===_projKey(p.path));
    const counts=new Map();
    for(const v of mine) counts.set(v.short,(counts.get(v.short)||0)+1);
    meta.querySelector('[data-f="sessions-row"]').hidden=mine.length===0;
    meta.querySelector('[data-f="sessions"]').textContent=[...counts].map(([k,n])=>n+' '+k).join(' \u00b7 ');
  }
  paintStopped();
  adminViews=views;
  renderAdminSessions(views);
  if(interrupted.length) renderInterrupted();   // t-d9e6: ticket titles arrive late
}
// ── Desktop notification (t-28ec) ──────────────────────────────────────────
// The shell is the one page that sees every project, so it alone notifies (a board
// per tab would repeat it). Opt-in per browser; permission is asked only from the
// Admin switch's click. Fires on a move into needs-you while you aren't looking at the
// cockpit — its tab hidden or its window unfocused (another app in front) — never for
// sessions already waiting when the page loaded (first poll = baseline).
const LS_NOTIFY='canon-cockpit-notify';
let prevStates=null;
function notifyEnabled(){ try{ return localStorage.getItem(LS_NOTIFY)==='on'; }catch(e){ return false; } }
function notifyNeedsYou(views){
  const prev=prevStates;
  prevStates=new Map(views.map(v=>[v.sid,v.state]));
  const inView=!document.hidden && document.hasFocus();
  if(!prev || inView || !notifyEnabled() || typeof Notification==='undefined' || Notification.permission!=='granted') return;
  for(const v of views){
    if(!v.sid || v.state!=='needs-you' || prev.get(v.sid)==='needs-you') continue;
    try{
      const n=new Notification((v.ticket||(v.scratch?(v.scrTitle||'A scratch session'):'A session'))+' needs you',{
        body:[ticketTitle(v.pid,v.ticket), v.projName||v.name].filter(Boolean).join(' \u00b7 '),
        tag:'canon-cockpit-'+v.sid,
      });
      n.onclick=()=>{ try{ window.focus(); }catch(e){} openSessionInTab(v); n.close(); };
    }catch(e){}
  }
}
export function renderNotifySetting(){
  const t=document.getElementById('ad-notify-toggle'), note=document.getElementById('ad-notify-note');
  if(!t) return;
  if(typeof Notification==='undefined'){
    t.checked=false; t.disabled=true;
    note.hidden=false; note.textContent='This browser doesn\u2019t support desktop notifications.';
    return;
  }
  const denied=Notification.permission==='denied';
  t.disabled=false;
  t.checked=notifyEnabled() && Notification.permission==='granted';
  note.hidden=!denied;
  note.textContent=denied?'Blocked in the browser\u2019s site settings for this page \u2014 allow notifications there, then turn this on.':'';
}
export async function onNotifyToggleChange(e){
  let perm=typeof Notification==='undefined' ? 'denied' : Notification.permission;
  if(e.target.checked && perm==='default'){ try{ perm=await Notification.requestPermission(); }catch(err){ perm='denied'; } }
  try{ localStorage.setItem(LS_NOTIFY, e.target.checked && perm==='granted' ? 'on' : 'off'); }catch(err){}
  renderNotifySetting();
}

export function openCloseWarn(id){
  pendingCloseId=id;
  const t=openTabs.find(x=>x.id===id);
  const msg=document.getElementById('closeWarnMsg');
  if(msg && t) msg.textContent='“'+t.name+'” has a live agent session. Closing it will end the session. Save the sprint state first, or keep working.';
  document.getElementById('closeWarn').classList.add('show');
}
export function hideCloseWarn(){ pendingCloseId=null; document.getElementById('closeWarn').classList.remove('show'); }
// Save & End (save=true) or End without saving (save=false): drive the board's
// EXISTING daemon save-and-end / end flow via a same-origin postMessage into the
// tab's board iframe (the board owns the terminal + session token). The daemon
// stays the sole PTY owner — the shell never talks to the daemon session API.
export function confirmCloseTab(save){
  const id=pendingCloseId;
  document.getElementById('closeWarn').classList.remove('show');
  pendingCloseId=null;
  if(!id) return;
  const v=document.getElementById('view-'+id);
  const ifr=v&&v.querySelector('iframe');
  if(!(ifr&&ifr.contentWindow)){ _removeTab(id); return; }  // no board frame — just close
  try{ ifr.contentWindow.postMessage({source:'canon-cockpit-shell', type: save?'save-and-end':'end'}, location.origin); }catch(e){}
  // Do NOT remove the tab yet — the board runs the save/end turn against the
  // daemon (up to ~90s) inside this iframe; tearing it down now would orphan
  // the session (the exact bug this guard prevents). Mark it closing; the
  // poller removes the tab once its daemon session actually ends.
  closingTabs.add(id);
  toast(save?'Saving & ending session…':'Ending session…');
  setTimeout(pollSessions, 800);
}

// t-2d2e: a board's Cockpit-sessions row for ANOTHER project asks the shell to
// open that project's tab, then hands the ticket to that tab's board. Same-origin
// only, sender must be one of our tab iframes, and the ticket id shape is checked
// on both hops (the board re-checks before openCockpit).
export const TICKET_ID_RE=/^t-[a-z0-9]{4}$/;
// t-47f1: scratch sessions — an agent in a project with no ticket. The shell mints the id.
export const SCRATCH_ID_RE=/^s-[a-z0-9]{4}$/;
// t-8d72: the Git status icon on a project card (a branch: three nodes and a curve).
export const GIT_ICON='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/></svg>';
// t-f553: a scribble and a pencil, the scratch session mark on the rail, Admin and the Scratch buttons.
export const SCRATCH_ICON='<svg class="scr-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" role="img" aria-label="Scratch session"><path d="M1.5 19c1.2-1.5 2.3-1.5 3.3 0s2.2 1.5 3.3 0 2-1 2.9.2"/><path d="M19.3 3.9a1.9 1.9 0 0 1 2.7 2.7L12.3 16.3l-3.6 1 1-3.6z"/><path d="M17.6 5.6l2.7 2.7"/></svg>';
// t-f553: scratch tabs each board has open, keyed by project id — shown on the rail before
// their agent starts (the daemon only reports running sessions).
export const boardScratch=new Map();
function newScratchId(){
  const a='abcdefghijklmnopqrstuvwxyz0123456789', b=new Uint8Array(4);
  crypto.getRandomValues(b);
  return 's-'+[...b].map(x=>a[x%36]).join('');
}
export function startScratch(projectId){
  const proj=getProjects().find(p=>p.id===projectId);
  if(!proj) return;
  // t-e162: always a new session — several per project, each extra one in its own worktree;
  // reopening an existing scratch is the Agents row's job.
  openSessionInTab({proot:proj.path, scratch:newScratchId()});
}
export const _projKey=p=>String(p||'').replace(/\\/g,'/').replace(/\/+$/,'').toLowerCase();
// t-565f: sessions's load-time code, run once at the end (the module version keeps it in initSessions()).
export function initSessions(){
try{ hiddenHere=new Set(JSON.parse(localStorage.getItem(HIDE_KEY)||'[]')); }catch(e){}
}
