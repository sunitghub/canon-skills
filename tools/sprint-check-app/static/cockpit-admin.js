// t-565f: the Cockpit shell's admin code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initAdmin(), which cockpit-main.js runs in order once every module has loaded.
import { cockpitConfirm, esc, escAttr, toast } from './cockpit-core.js';
import { SCRATCH_ICON, TICKET_ID_RE, _projKey, dismissInterrupted, fmtDur, interrupted, intrProj, intrSince, onNotifyToggleChange, renderNotifySetting, renderSessionSurfaces, resumeInterrupted, sessionTime, sessionView, setLastSessions, ticketTitle } from './cockpit-sessions.js';
import { activeTab, isProjectTab, openSessionInTab, openTabs } from './cockpit-tabs.js';
import { getProjects } from './cockpit-projects.js';
import { canKill, canReap, confirmEnd } from './cockpit-end.js';

export function renderAdminSessions(views){
  const box=document.getElementById('ad-sessions');
  if(!box) return;
  const needs=views.filter(v=>v.state==='needs-you').length;
  document.getElementById('ad-tile-agents').textContent=views.length;
  document.getElementById('ad-tile-needs').textContent=needs;
  if(!views.length && !interrupted.length){ box.innerHTML='<div class="srow snone">No active agent sessions.</div>'; return; }
  // The board holds no session token (t-391a): Answer/Open jumps to the session's tab, and Reap now / Kill go
  // through the daemon's /relay page (t-3c9a), never a token here.
  box.innerHTML='<div class="ad-table-wrap"><table class="ad-table"><thead><tr>'+
    '<th>State</th><th>Session</th><th>Reaper</th><th></th></tr></thead><tbody>'+
    views.map((v,i)=>{
      const title=ticketTitle(v.pid,v.ticket);
      const dur=sessionTime(v).dur, inSession=dur ? ' \u00b7 '+dur+' in session' : '';
      const dir=!v.cwd || _projKey(v.cwd)===_projKey(v.proot) ? 'main checkout' : (v.cwd.split(/[\\/]/).filter(Boolean).pop()||v.cwd);
      const since=v.since!==null ? ' \u00b7 '+fmtDur(v.since) : '';
      return `<tr class="st st-${v.state}">`+
      `<td title="${escAttr(v.label+(v.signal?' \u00b7 state from: '+v.signal:''))}"><span class="stcell"><span class="sdot"></span>${esc(v.short+since)}</span></td>`+
      `<td class="sess"><div class="s1" title="${escAttr(title)}">${v.ticket?`<span class="ag-id">${esc(v.ticket)}</span>${esc(title)}`:(v.scratch?`${SCRATCH_ICON}${esc(v.scrTitle||'Scratch session')}`:'no ticket')}</div>`+
      `<div class="s2" title="${escAttr(v.proot+' \u00b7 '+v.agent+' \u00b7 '+v.cwd+inSession)}">${esc((v.projName||v.name)+' \u00b7 '+v.agent+' \u00b7 '+dir+inSession)}</div></td>`+
      `<td class="reap">${esc(v.reaper||'\u2014')}</td>`+
      `<td><div class="acts"><button class="ad-open${v.state==='needs-you'?' answer':''}" data-i="${i}">${v.state==='needs-you'?'Answer':'Open'}</button>`+
      (canReap(v)?`<button class="ad-end" data-end="reap" data-i="${i}" title="Do now what the idle reaper would do">Reap now</button>`:'')+
      (canKill(v)?`<button class="ad-end kill" data-end="kill" data-i="${i}" title="End now, without saving">Kill</button>`:'')+`</div></td></tr>`;
    }).join('')+
    interrupted.map(e=>{
      const proj=intrProj(e), pid=(proj||{}).id||'';
      const title=TICKET_ID_RE.test(e.id)?ticketTitle(pid,e.id):'';
      const who=TICKET_ID_RE.test(e.id)?`<span class="ag-id">${esc(e.id)}</span>${esc(title)}`:`${SCRATCH_ICON}${esc('Scratch session')} <span class="ag-id">${esc(e.id)}</span>`;
      const meta=[proj?proj.name:e.project_root,e.agent,intrSince(e)&&'since '+intrSince(e)].filter(Boolean).join(' \u00b7 ');
      return `<tr class="st st-stopped" data-id="${escAttr(e.id)}">`+
      `<td><span class="stcell"><span class="sdot"></span>stopped</span></td>`+
      `<td class="sess" colspan="2"><div class="s1" title="${escAttr(e.project_root)}">${who}<span class="s1meta">${esc(meta)}</span></div>`+
      (e.resumable!==true&&e.reason?`<div class="s3">${esc('Can\u2019t resume: '+e.reason)}</div>`:'')+`</td>`+
      `<td><div class="acts">${e.resumable===true?`<button class="intr-btn primary" data-act="resume" data-id="${escAttr(e.id)}">Resume</button>`:''}<button class="intr-btn" data-act="dismiss" data-id="${escAttr(e.id)}">Dismiss</button></div></td></tr>`;
    }).join('')+
    '</tbody></table></div>';
  box.querySelectorAll('.ad-open').forEach(b=>b.addEventListener('click',()=>openSessionInTab(views[+b.dataset.i])));
  box.querySelectorAll('.ad-end').forEach(b=>b.addEventListener('click',()=>confirmEnd(views[+b.dataset.i],b.dataset.end)));
  box.querySelectorAll('.intr-btn[data-id]').forEach(b=>b.addEventListener('click',()=>{
    const e=interrupted.find(x=>x.id===b.dataset.id); if(!e) return;
    if(b.dataset.act==='resume') resumeInterrupted(e); else dismissInterrupted(e.id);
  }));
}

export function fmtUptime(secs){
  secs=parseInt(secs||0,10); if(!secs||secs<0) return '—';
  const h=Math.floor(secs/3600), m=Math.floor((secs%3600)/60);
  if(h>0) return h+'h '+m+'m';
  if(m>0) return m+'m';
  return secs+'s';
}

export async function loadAdmin(){
  const projects=getProjects();
  const setTxt=(id,val)=>{const e=document.getElementById(id); if(e) e.textContent=val;};
  setTxt('ad-tile-projects',projects.length);
  // daemon health + version + uptime from /api/cockpit (+ /api/version)
  let ck={}; try{ ck=await (await fetch('/api/cockpit')).json(); }catch(e){}
  const st=document.getElementById('ad-status');
  if(!ck.running){ st.className='dstatus down'; st.textContent='Not running'; }
  else if(ck.stale){ st.className='dstatus stale'; st.textContent='Out of date'; }
  else { st.className='dstatus healthy'; st.textContent='Healthy'; }
  let ver='—';
  try{ const v=await (await fetch('/api/version')).json(); if(v&&v.version) ver='v'+v.version+(v.commit?(' ('+v.commit+')'):''); }catch(e){}
  document.getElementById('ad-version').textContent=ver;
  document.getElementById('ad-shell-uptime').textContent=fmtUptime(ck.shell_uptime_secs);
  const up=(ck.running_build&&ck.running_build.uptime_secs);
  document.getElementById('ad-uptime').textContent=ck.running?fmtUptime(up):'—';
  // t-ffb9: reflect the daemon's REAL debug_enabled value (from /version via
  // /api/cockpit's running_build) on every poll — never trust only this
  // browser tab's last action, since another tab or a daemon restart could
  // have changed it. Disabled with no running daemon to toggle.
  const dbgToggle=document.getElementById('ad-debug-toggle');
  if(dbgToggle && !dbgToggle.dataset.pending){
    dbgToggle.checked=!!(ck.running_build&&ck.running_build.debug_enabled);
    dbgToggle.disabled=!ck.running;
  }
  // sessions (cross-project) → running agents count + list
  let sessions=[]; try{ const s=await fetch('/api/cockpit-sessions'); if(s.ok) sessions=await s.json(); }catch(e){}
  if(!Array.isArray(sessions)) sessions=[];
  setLastSessions(sessions);
  renderSessionSurfaces();
  // Reaper settings, read-only (a daemon older than t-824e doesn't report them).
  const rb=ck.running_build||{}, rp=document.getElementById('ad-reaper');
  rp.hidden=!(rb.idle_timeout_secs>0 && rb.idle_timeout_main_secs>0);
  rp.textContent=rp.hidden?'':('Idle sessions auto-save & end after '+fmtUptime(rb.idle_timeout_secs)+' in a worktree and '+fmtUptime(rb.idle_timeout_main_secs)+' in a project\u2019s main checkout; any activity resets the timer, and a session that needs you is never ended.');
  // t-ade9: a per-state hint under the daemon panel \u2014 "Healthy" alone doesn't
  // say whether any agent is actually running, which reads as a contradiction
  // once you know the daemon spawns lazily on first Start/Resume.
  const hint=document.getElementById('ad-daemon-hint');
  if(!ck.running){
    hint.textContent='No agents running in any project \u2014 the daemon spawns lazily on first Start/Resume.';
  } else if(sessions.length===0){
    hint.textContent='Daemon is idle \u2014 no agents currently running.';
  } else {
    const needs=sessions.filter(s=>sessionView(s).state==='needs-you').length;
    hint.textContent=sessions.length+' agent'+(sessions.length===1?'':'s')+' running \u00b7 '+needs+' needs you';
  }
  // Active projects = projects currently open in a tab (shell state).
  document.getElementById('ad-tile-active').textContent = openTabs.length;
  mtLoad();
  ghLoad(false);
}

// ── Admin > GitHub (t-90a3) ─────────────────────────────────────────────
// Renders `tkt github-doctor --json` for one project, via GET /api/github/doctor (both boards). The doctor owns every
// title, detail and fix shown here (the worktree picker's GitHub row, t-24b1, reads the same JSON); this only lays it out.
// gh runs per check, so it loads when Admin first opens or the project changes, and on Check again, never on a poll.
let ghPid=null, ghDoctor=null, ghGen=0;
function ghPickProject(){
  const sel=document.getElementById('ad-gh-project'), projects=getProjects();
  const want=sel.value||(isProjectTab(activeTab)?activeTab:'')||(projects[0]&&projects[0].id)||'';
  sel.innerHTML=projects.map(p=>`<option value="${escAttr(p.id)}">${esc(p.name)}</option>`).join('');
  if(projects.some(p=>p.id===want)) sel.value=want;
  return sel.value;
}
async function ghLoad(force){
  const pid=ghPickProject();
  if(!pid || (!force && pid===ghPid)) return;
  ghPid=pid; const gen=++ghGen;
  document.getElementById('ad-gh-count').textContent='Checks \u00b7 checking\u2026';
  let res;
  try{ const r=await fetch('/api/github/doctor?project='+encodeURIComponent(pid)); res=r.ok?await r.json():{ok:false,output:'HTTP '+r.status}; }
  catch(e){ res={ok:false,output:String(e.message||e)}; }
  if(gen!==ghGen) return;
  ghDoctor=res.ok&&res.doctor?res.doctor:null;
  if(!ghDoctor) ghPid=null;   // a failed read is tried again the next time Admin opens
  ghRender(res);
}
function ghRender(res){
  const box=document.getElementById('ad-gh-checks'), count=document.getElementById('ad-gh-count');
  if(!ghDoctor){ count.textContent='Checks'; document.getElementById('ad-gh-copy-domains').disabled=document.getElementById('ad-gh-copy-script').disabled=true; box.innerHTML=`<div class="gh-row gh-bad"><i></i><div><b>Could not run the checks</b><pre>${esc(res.output||'')}</pre></div></div>`; return; }
  const checks=ghDoctor.checks||[];
  count.textContent=`Checks \u00b7 ${checks.filter(c=>c.status!=='bad').length} of ${checks.length} ready`;
  box.innerHTML=checks.map(c=>{
    const f=c.fix||{};
    const fix=f.cmd?`<code>${esc(f.cmd)}</code><button type="button" class="btn" data-gh-copy="${escAttr(f.cmd)}">Copy</button>`
      :/^https:\/\//.test(f.url||'')?`<a href="${escAttr(f.url)}" target="_blank" rel="noopener">${esc(f.url)} \u2197</a>`:'';
    return `<div class="gh-row gh-${escAttr(c.status)}" data-check="${escAttr(c.id)}"><i></i><div><b>${esc(c.title)}</b><span>${esc(c.detail||'')}</span></div><div class="gh-fix">${fix}</div></div>`;
  }).join('');
  const cloud=ghDoctor.cloud||{};
  document.getElementById('ad-gh-copy-domains').disabled=!(cloud.domains||[]).length;
  document.getElementById('ad-gh-copy-script').disabled=!cloud.setup_script;
  document.getElementById('ad-gh-domains').innerHTML=(cloud.domains||[]).map(d=>`<code>${esc(d)}</code>`).join('');
}
function ghCopy(text){
  try{ navigator.clipboard.writeText(text).then(()=>toast('Copied'),()=>toast('Copy failed')); }catch(e){ toast('Copy failed'); }
}

// ── Admin > Model Tiers (t-7e36) ────────────────────────────────────────
// Board-wide registry (not per-project, not daemon state) backing this
// panel and the board's per-ticket Gate-model dropdown. Anthropic
// picks are dispatched by Claude Code; an OpenAI model runs close gates under
// Copilot CLI only via a per-ticket `Gate model: openai:<id>` (t-ef27) — the
// OpenAI defaults here stay recorded only. See #mt-openai-note.
let mtData=null, mtProvider='anthropic';
const MT_PROVIDER_LABEL={anthropic:'Anthropic',openai:'OpenAI'};

async function mtLoad(){
  try{ mtData=await (await fetch('/api/admin/model-tiers')).json(); }
  catch(e){ mtData={defaults:{eval:{},light:{}},models:{anthropic:[],openai:[]}}; }
  mtRender();
}

async function mtSave(){
  try{
    const r=await fetch('/api/admin/model-tiers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(mtData)});
    const res=await r.json();
    if(!res.ok){ toast(res.error||"Couldn't save — reverting"); await mtLoad(); return false; }
    return true;
  }catch(e){ toast("Couldn't reach the board"); await mtLoad(); return false; }
}

function mtSlugify(name,existing,field='id'){
  let base=String(name||'model').toLowerCase().replace(/[^a-z0-9._-]+/g,'-').replace(/^-+|-+$/g,'')||'model';
  let val=base, n=2;
  while(existing.some(m=>m[field]===val)){ val=base+'-'+n; n++; }
  return val;
}
// Only Anthropic's alias field feeds the per-ticket Gate-model dropdown
// (`models.filter(m => m.alias)` in static/board-docs.js) — OpenAI has no equivalent
// consumer yet (t-ef27), so its cards carry no alias field at all.
const MT_ALIAS_PROVIDERS=new Set(['anthropic']);

function mtRender(){
  if(!mtData) return;
  // Defaults pickers
  ['eval','light'].forEach(tier=>{
    const row=document.getElementById('mt-default-'+tier);
    if(!row) return;
    row.innerHTML=Object.keys(MT_PROVIDER_LABEL).map(prov=>{
      const models=mtData.models[prov]||[];
      const cur=(mtData.defaults[tier]||{})[prov]||'';
      const opts=models.map(m=>`<option value="${escAttr(m.id)}"${m.id===cur?' selected':''}>${esc(m.name)}</option>`).join('');
      return `<div class="mt-picker"><select data-tier="${tier}" data-prov="${prov}">${opts}</select><span class="mt-prov">${prov}${prov==='openai'?' · per-ticket':''}</span></div>`;
    }).join('');
    row.querySelectorAll('select').forEach(sel=>sel.addEventListener('change',()=>mtSetDefault(sel)));
  });
  // Provider tabs
  const tabs=document.getElementById('mt-tabs');
  tabs.innerHTML=Object.entries(MT_PROVIDER_LABEL).map(([prov,label])=>
    `<div class="mt-tab${prov===mtProvider?' active':''}" data-prov="${prov}">${label} <span style="color:var(--text-dim);font-weight:400">· ${(mtData.models[prov]||[]).length}</span></div>`
  ).join('');
  tabs.querySelectorAll('.mt-tab').forEach(t=>t.addEventListener('click',()=>mtSwitchProvider(t.dataset.prov)));
  // Card grid
  const grid=document.getElementById('mt-grid');
  const models=mtData.models[mtProvider]||[];
  const defaultIds=new Set(Object.values(mtData.defaults.eval||{}).concat(Object.values(mtData.defaults.light||{})));
  const hasAlias=MT_ALIAS_PROVIDERS.has(mtProvider);
  grid.innerHTML = models.map(m=>{
    const badge=defaultIds.has(m.id)?'<span class="mt-badge">Default</span>':'';
    if(m.id===mtEditing) return mtEditCard(m,badge,hasAlias);
    const aliasRow=hasAlias
      ? `<div class="mt-card-id"><span class="mt-alias-label">Gate-model alias</span> <span>${esc(m.alias||'')}</span></div>`
      : '';
    return `<div class="mt-card" data-id="${escAttr(m.id)}">
        <div class="mt-card-top"><span class="mt-card-name">${esc(m.name)}</span>${badge}</div>
        <div class="mt-card-desc">${esc(m.desc||'')}</div>
        <div class="mt-card-id">${esc(m.id)}</div>
        ${aliasRow}
        <div class="mt-card-price"><span>Input/MTok</span><span>$${esc(m.input_price)}</span></div>
        <div class="mt-card-price"><span>Output/MTok</span><span>$${esc(m.output_price)}</span></div>
        <div class="mt-card-actions"><button type="button" class="mt-edit"${mtEditing?' disabled':''} aria-label="Edit ${escAttr(m.name)}">Edit</button><a class="danger">Remove</a></div>
      </div>`;
  }).join('') + `<div class="mt-add-card">+ Add ${esc(MT_PROVIDER_LABEL[mtProvider])} model</div>`;
  // t-783a: wired after each render; the ids come back from data-id, so no JS sits inside an attribute.
  grid.querySelectorAll('.mt-card:not(.editing)').forEach(card=>{
    card.querySelector('.mt-edit').addEventListener('click',()=>mtStartEdit(card.dataset.id));
    card.querySelector('.danger').addEventListener('click',()=>mtRemoveModel(card.dataset.id));
  });
  const editing=grid.querySelector('.mt-card.editing');
  if(editing){
    editing.addEventListener('keydown',e=>mtEditKey(e));
    editing.querySelector('.mt-cancel').addEventListener('click',()=>mtCancelEdit());
    editing.querySelector('.mt-save').addEventListener('click',()=>mtSaveEdit());
  }
  grid.querySelector('.mt-add-card').addEventListener('click',()=>mtAddModel());
}

function mtSwitchProvider(prov){ mtProvider=prov; mtEditing=null; mtRender(); }

// t-294b: one card at a time is editable; nothing is saved until Save.
let mtEditing=null;
function mtEditCard(m,badge,hasAlias){
  const f=(key,label,val,type='text')=>`<label class="mt-field">${label}<input type="${type}" data-field="${key}"${type==='number'?' min="0" step="any"':''} value="${escAttr(val==null?'':String(val))}"></label>`;
  return `<div class="mt-card editing" data-id="${escAttr(m.id)}">
      <div class="mt-card-top"><span class="mt-card-name">Editing</span>${badge}</div>
      ${f('name','Name',m.name)}
      ${f('desc','Description',m.desc||'')}
      <div class="mt-card-id">${esc(m.id)}</div>
      ${hasAlias?f('alias','Gate-model alias',m.alias||''):''}
      <div class="mt-field-row">${f('input_price','Input $/MTok',m.input_price,'number')}${f('output_price','Output $/MTok',m.output_price,'number')}</div>
      <div class="mt-card-err" role="alert"></div>
      <div class="mt-card-actions"><button type="button" class="mt-cancel">Cancel</button><button type="button" class="mt-save">Save</button></div>
    </div>`;
}
function mtStartEdit(id){
  mtEditing=id; mtRender();
  const input=document.querySelector('.mt-card.editing input');
  if(input) input.focus();
}
function mtCancelEdit(){ mtEditing=null; mtRender(); }
function mtEditKey(e){
  if(e.key==='Escape'){ e.preventDefault(); mtCancelEdit(); }
  else if(e.key==='Enter' && e.target.tagName==='INPUT'){ e.preventDefault(); mtSaveEdit(); }
}
async function mtSaveEdit(){
  const card=document.querySelector('.mt-card.editing');
  const model=(mtData.models[mtProvider]||[]).find(m=>m.id===mtEditing);
  if(!card||!model) return;
  const v={};
  card.querySelectorAll('input[data-field]').forEach(i=>{ v[i.dataset.field]=i.value.trim(); });
  const price=x=>(x!==''&&isFinite(Number(x))&&Number(x)>=0)?Number(x):null;
  let err='';
  if(!v.name) err='Name can’t be empty.';
  else if('alias' in v && v.alias && !MT_ID_RE.test(v.alias)) err='Alias may only contain letters, digits, "." "_" "-".';
  else if(price(v.input_price)===null||price(v.output_price)===null) err='Prices must be numbers of 0 or more.';
  if(err){ card.querySelector('.mt-card-err').textContent=err; return; }
  model.name=v.name; model.desc=v.desc;
  if('alias' in v) model.alias=v.alias;
  model.input_price=price(v.input_price); model.output_price=price(v.output_price);
  mtEditing=null;
  if(await mtSave()){ mtRender(); toast('Saved'); }
}

async function mtSetDefault(sel){
  const tier=sel.dataset.tier, prov=sel.dataset.prov;
  mtData.defaults[tier]=mtData.defaults[tier]||{};
  mtData.defaults[tier][prov]=sel.value;
  if(await mtSave()) toast('Default updated');
}

const MT_ID_RE=/^[A-Za-z0-9._-]+$/; // mirrors server.py's MODEL_ID_RE / main.go's modelIDRe

async function mtAddModel(){
  mtData.models[mtProvider]=mtData.models[mtProvider]||[];
  const id=mtSlugify('new-model',mtData.models[mtProvider]);
  const entry={id,name:'New Model',desc:'',reasoning:[],input_price:0,output_price:0};
  // Seed a usable alias immediately so a UI-added Anthropic model reaches the
  // per-ticket Gate-model dropdown without a manual edit step (t-7e36 review
  // finding: a model added via this button previously had no alias at all,
  // so it could never appear there).
  if(MT_ALIAS_PROVIDERS.has(mtProvider)){
    entry.alias=mtSlugify('new-model',mtData.models[mtProvider],'alias');
  }
  mtData.models[mtProvider].push(entry);
  if(await mtSave()){ mtStartEdit(id); } else await mtLoad();
}

async function mtRemoveModel(id){
  const ok=await cockpitConfirm({title:'Remove model?',body:'Removes "'+id+'" from the registry. Any ticket whose Gate model: still names it keeps that value as a hand-edit override.',okLabel:'Remove',danger:true});
  if(!ok) return;
  mtData.models[mtProvider]=(mtData.models[mtProvider]||[]).filter(m=>m.id!==id);
  if(await mtSave()) mtRender(); else await mtLoad();
}
// t-ffb9: never assume the request succeeded — disable during the round
// trip, then set checked/disabled from the actual response (or the next
// loadAdmin poll on failure), matching this panel's existing
// don't-trust-client-state convention (see the poll's own reflect logic).
async function onDebugToggleChange(e){
  const box=e.target, wanted=box.checked, prior=!wanted;
  box.disabled=true; box.dataset.pending='1';
  try{
    const r=await fetch('/api/cockpit-debug',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled:wanted})});
    const res=await r.json();
    if(res&&res.ok){
      box.checked=!!res.enabled;
      toast(res.enabled?'Verbose logging on':'Verbose logging off');
    } else {
      box.checked=prior; // revert — the request didn't actually take effect
      toast("Couldn't reach the daemon — no change made");
    }
  }catch(err){
    box.checked=prior;
    toast("Couldn't reach the board");
  }
  delete box.dataset.pending;
  box.disabled=false;
}
async function _cockpitLiveSessionCount(){
  let sessions=[]; try{ const s=await fetch('/api/cockpit-sessions'); if(s.ok) sessions=await s.json(); }catch(e){}
  return Array.isArray(sessions)?sessions.length:0;
}
async function restartDaemon(){
  const n=await _cockpitLiveSessionCount();
  if(n>0 && !(await cockpitConfirm({title:'Restart the Cockpit daemon?', body:n+' active agent session'+(n===1?'':'s')+' across all projects will be ended.', okLabel:'Restart', danger:true}))) return;
  try{
    const r=await fetch('/api/cockpit-restart',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({force:n>0})});
    const res=await r.json();
    toast(res&&res.restarted ? '✓ Daemon restarted' : (res&&res.running ? 'Daemon still running (older build?)' : "Couldn't restart daemon"));
  }catch(e){ toast("Couldn't reach the board"); }
  setTimeout(loadAdmin,600);
}
// t-a30c: same shape as restartDaemon, minus the relaunch — the daemon comes
// back on its own next time a cockpit tab is opened (ensure_cockpit). Unlike
// Restart, Stop ALWAYS confirms (not just when sessions are live) — it's
// presented as a destructive action (red hover), so the confirm shouldn't
// disappear just because the daemon happens to be idle right now.
async function stopDaemon(){
  const n=await _cockpitLiveSessionCount();
  const body=n>0 ? (n+' active agent session'+(n===1?'':'s')+' across all projects will be ended.') : 'The daemon will exit. It restarts automatically next time a cockpit tab is opened.';
  if(!(await cockpitConfirm({title:'Stop the Cockpit daemon?', body, okLabel:'Stop', danger:true}))) return;
  try{
    const r=await fetch('/api/cockpit-stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({force:n>0})});
    const res=await r.json();
    toast(res&&res.stopped ? '✓ Daemon stopped' : (res&&res.running===false ? 'Daemon was not running' : "Couldn't stop daemon"));
  }catch(e){ toast("Couldn't reach the board"); }
  setTimeout(loadAdmin,600);
}
// t-565f: admin's load-time code, run once at the end (the module version keeps it in initAdmin()).
export function initAdmin(){

// Restart/Stop both reuse the daemon's token-free /api/cockpit-restart|-stop
// (busy-confirm + re-poll) — OS pid-kill only, never the daemon's own
// token-gated shutdown route (t-ddc8).
document.addEventListener('DOMContentLoaded',()=>{
  const rb=document.getElementById('ad-restart');
  if(rb) rb.addEventListener('click',restartDaemon);
  const sb=document.getElementById('ad-stop');
  if(sb) sb.addEventListener('click',stopDaemon);
  const db=document.getElementById('ad-debug-toggle');
  if(db) db.addEventListener('change',onDebugToggleChange);
  const nt=document.getElementById('ad-notify-toggle');
  if(nt){ nt.addEventListener('change',onNotifyToggleChange); renderNotifySetting(); }
  document.getElementById('ad-gh-project').addEventListener('change',()=>ghLoad(true));
  document.getElementById('ad-gh-recheck').addEventListener('click',()=>ghLoad(true));
  document.getElementById('ad-gh-checks').addEventListener('click',e=>{ const b=e.target.closest('[data-gh-copy]'); if(b) ghCopy(b.dataset.ghCopy); });
  document.getElementById('ad-gh-copy-domains').addEventListener('click',()=>ghCopy(((ghDoctor&&ghDoctor.cloud&&ghDoctor.cloud.domains)||[]).join('\n')));
  document.getElementById('ad-gh-copy-script').addEventListener('click',()=>ghCopy((ghDoctor&&ghDoctor.cloud&&ghDoctor.cloud.setup_script)||''));
});
}
