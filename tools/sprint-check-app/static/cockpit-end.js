// t-3c9a: Reap now / Kill a session from the shell (the Agents row menu and Admin). The shell holds no daemon token
// (t-ddc8): it frames the daemon's /relay page hidden and asks it, by postMessage, to call /end-session. The daemon
// re-checks everything; the shell re-checks the session after the confirm so an answer about one state can't act on another.
import { cockpitConfirm, toast } from './cockpit-core.js';
import { openMenu, openSessionInTab } from './cockpit-tabs.js';
import { fmtDur, pollSessions, sessionView, ticketTitle } from './cockpit-sessions.js';

let relay=null;          // {frame, origin, ready: Promise}
const pending=new Map(); // request id \u2192 resolve
let seq=0;
const RELAY_TIMEOUT=10000;

function mountRelay(){
  if(relay) return relay.ready;
  const ready=(async()=>{
    const ck=await (await fetch('/api/cockpit')).json();
    if(!ck||!ck.running||!ck.addr) throw new Error('The Cockpit daemon isn\u2019t running.');
    const frame=document.createElement('iframe');
    frame.id='end-relay'; frame.hidden=true; frame.setAttribute('aria-hidden','true'); frame.tabIndex=-1;
    frame.src='http://'+ck.addr+'/relay';
    relay.frame=frame; relay.origin='http://'+ck.addr;
    await new Promise((res,rej)=>{ frame.addEventListener('load',res,{once:true}); frame.addEventListener('error',rej,{once:true}); document.body.appendChild(frame); });
  })();
  relay={frame:null, origin:'', ready};
  ready.catch(dropRelay);   // try again next time
  return ready;
}
window.addEventListener('message',e=>{
  if(!relay||!relay.frame||e.source!==relay.frame.contentWindow||e.origin!==relay.origin) return;
  const d=e.data;
  if(!d||d.source!=='canon-relay'||d.type!=='end-session-result'||!pending.has(d.id)) return;
  pending.get(d.id)({status:d.status, text:String(d.text||'')}); pending.delete(d.id);
});
function dropRelay(){ if(relay&&relay.frame) relay.frame.remove(); relay=null; }
function sendOnce(v,mode){
  const id='e'+(++seq)+'-'+Date.now();
  return new Promise(res=>{
    const t=setTimeout(()=>{ if(pending.delete(id)) res({status:0, text:'The Cockpit daemon didn\u2019t answer. If it is older than this page, restart it from Admin.'}); },RELAY_TIMEOUT);
    pending.set(id,r=>{ clearTimeout(t); res(r); });
    relay.frame.contentWindow.postMessage({source:'canon-cockpit-shell', type:'end-session', id, session:v.sid, ticket:v.ticket||v.scratch, project_root:v.proot, mode}, relay.origin);
  });
}
async function sendEnd(v,mode){
  for(let attempt=0;;attempt++){
    try{ await mountRelay(); }catch(err){ return {status:0, text:err.message||'The Cockpit daemon isn\u2019t reachable.'}; }
    const r=await sendOnce(v,mode);
    // A relay framed before a daemon restart holds the old boot token (401), or belongs to a daemon that is gone (no
    // answer): drop it and try once more with a fresh one (break-it).
    if((r.status===401||r.status===0)&&attempt===0){ dropRelay(); continue; }
    return r;
  }
}

// What the idle reaper would act on: a live session at its prompt. Never needs-you or working (the daemon says why).
export function canReap(v){ return !!v.sid && (v.state==='idle'||v.state==='done'); }
export function canKill(v){ return !!v.sid; }
function reapWhyNot(v){
  if(!v.sid) return 'Not started yet';
  if(v.state==='needs-you') return 'Waiting on you \u2014 answer it first';
  if(v.state==='working') return 'Working \u2014 the agent isn\u2019t at its prompt';
  return '';
}
function sessionName(v){
  if(v.ticket){ const t=ticketTitle(v.pid,v.ticket); return v.ticket+(t?' '+t:''); }
  return v.scrTitle||'Scratch session';
}

export async function confirmEnd(v,mode){
  const name=sessionName(v), where=(v.projName||v.name)+' \u00b7 '+v.agent;
  const scratchNote=' Uncommitted changes stay in the folder and are noted in HANDOFF.md ## Scratch.';
  const ok=mode==='kill'
    ? await cockpitConfirm({title:'Kill \u201c'+name+'\u201d?', okLabel:'Kill', danger:true, focusCancel:true,
        body:'Ends '+where+' now, without saving.'+(v.scratch?scratchNote:' Anything the agent hasn\u2019t written down is lost.')})
    : await cockpitConfirm({title:'Reap \u201c'+name+'\u201d now?', okLabel:'Reap now',
        body:v.scratch ? 'Ends '+where+' now, as the idle reaper would.'+scratchNote
          : 'Asks '+where+' to save its state, then ends it \u2014 what the idle reaper would do'+(v.reapIn!==null?' in '+fmtDur(v.reapIn):'')+'.'});
  if(!ok) return;
  // Re-check after the confirm: the session may have ended, or started working or asking, while the dialog was open.
  let rows=null;
  try{ const r=await fetch('/api/cockpit-sessions'); if(r.ok) rows=await r.json(); }catch(e){}
  if(!Array.isArray(rows)){ toast('Couldn\u2019t check \u201c'+name+'\u201d with the Cockpit daemon; nothing was ended.'); return; }
  const now=rows.map(sessionView).find(x=>x.sid===v.sid);
  if(!now){ toast('\u201c'+name+'\u201d has already ended.'); pollSessions(); return; }
  if(mode==='reap'&&!canReap(now)){ toast('Can\u2019t reap \u201c'+name+'\u201d now: '+reapWhyNot(now).toLowerCase()+'.'); pollSessions(); return; }
  const r=await sendEnd(now,mode);
  let msg;
  if(r.status===200||r.status===202){
    let note='';
    try{ note=JSON.parse(r.text).note_error||''; }catch(e){}
    msg=mode==='kill' ? 'Killed \u201c'+name+'\u201d.'+(note?' '+note:'') : 'Reaping \u201c'+name+'\u201d: saving, then ending.';
  } else msg=r.status===0 ? r.text : 'Didn\u2019t '+(mode==='kill'?'kill':'reap')+' \u201c'+name+'\u201d: '+(r.text.trim()||('error '+r.status));
  toast(msg);
  pollSessions();
}

// The Agents row menu (right-click, Shift+F10 or the ContextMenu key).
export function openSessionMenu(v,x,y){
  const why=reapWhyNot(v);
  openMenu([
    {label:'Open', fn:()=>openSessionInTab(v)},
    {label:'Reap now', hint:'save & end', disabled:!canReap(v), title:why||'Do now what the idle reaper would do', fn:()=>confirmEnd(v,'reap')},
    {sep:true},
    {label:'Kill\u2026', hint:'no save', danger:true, disabled:!canKill(v), title:canKill(v)?'End now, without saving':'Not started yet', fn:()=>confirmEnd(v,'kill')},
  ],x,y);
}
