// t-565f: the Cockpit shell's admin code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initAdmin(), which cockpit-main.js runs in order once every module has loaded.
import { cockpitConfirm, esc, escAttr, fillVersions, toast } from './cockpit-core.js';
import { scratchIcon, TICKET_ID_RE, _projKey, dismissInterrupted, fmtDur, interrupted, intrProj, intrSince, renderSessionSurfaces, resumeInterrupted, sessionTime, sessionView, setLastSessions, ticketTitle } from './cockpit-sessions.js';
import { openSessionInTab, openTabs } from './cockpit-tabs.js';
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
      `<td class="sess"><div class="s1" title="${escAttr(title)}">${v.ticket?`<span class="ag-id">${esc(v.ticket)}</span>${esc(title)}`:(v.scratch?`${scratchIcon(v.agent)}${esc(v.scrTitle||'Scratch session')}`:'no ticket')}</div>`+
      `<div class="s2" title="${escAttr(v.proot+' \u00b7 '+v.agent+' \u00b7 '+v.cwd+inSession)}">${esc((v.projName||v.name)+' \u00b7 '+v.agent+' \u00b7 '+dir+inSession)}</div></td>`+
      `<td class="reap">${esc(v.reaper||'\u2014')}</td>`+
      `<td><div class="acts"><button class="ad-open b-accent${v.state==='needs-you'?' answer':''}" data-i="${i}">${v.state==='needs-you'?'Answer':'Open'}</button>`+
      (canReap(v)?`<button class="ad-end b-danger" data-end="reap" data-i="${i}" title="Do now what the idle reaper would do">Reap now</button>`:'')+
      (canKill(v)?`<button class="ad-end kill b-danger" data-end="kill" data-i="${i}" title="End now, without saving">Kill</button>`:'')+`</div></td></tr>`;
    }).join('')+
    interrupted.map(e=>{
      const proj=intrProj(e), pid=(proj||{}).id||'';
      const title=TICKET_ID_RE.test(e.id)?ticketTitle(pid,e.id):'';
      const who=TICKET_ID_RE.test(e.id)?`<span class="ag-id">${esc(e.id)}</span>${esc(title)}`:`${scratchIcon(e.agent)}${esc(e.agent==='term'?'Terminal':'Scratch session')} <span class="ag-id">${esc(e.id)}</span>`;
      const meta=[proj?proj.name:e.project_root,e.agent,intrSince(e)&&'since '+intrSince(e)].filter(Boolean).join(' \u00b7 ');
      return `<tr class="st st-stopped" data-id="${escAttr(e.id)}">`+
      `<td><span class="stcell"><span class="sdot"></span>stopped</span></td>`+
      `<td class="sess" colspan="2"><div class="s1" title="${escAttr(e.project_root)}">${who}<span class="s1meta">${esc(meta)}</span></div>`+
      (e.resumable!==true&&e.reason?`<div class="s3">${esc('Can\u2019t resume: '+e.reason)}</div>`:'')+`</td>`+
      `<td><div class="acts">${e.resumable===true?`<button class="intr-btn b-accent" data-act="resume" data-id="${escAttr(e.id)}">Resume</button>`:''}<button class="intr-btn b-neutral" data-act="dismiss" data-id="${escAttr(e.id)}">Dismiss</button></div></td></tr>`;
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
  mtLoad();   // t-d40b: first, not last: the registry is a local file read, and it used to wait behind the daemon, version and session requests below
  const projects=getProjects();
  const setTxt=(id,val)=>{const e=document.getElementById(id); if(e) e.textContent=val;};
  setTxt('ad-tile-projects',projects.length);
  // daemon health + version + uptime from /api/cockpit (+ /api/version)
  let ck={}; try{ ck=await (await fetch('/api/cockpit')).json(); }catch(e){}
  const st=document.getElementById('ad-status');
  if(!ck.running){ st.className='dstatus down'; st.textContent='Not running'; }
  else if(ck.stale){ st.className='dstatus stale'; st.textContent='Out of date'; }
  else { st.className='dstatus healthy'; st.textContent='Healthy'; }
  fillVersions({canon:'ad-ver-canon', board:'ad-ver-board', daemon:'ad-ver-daemon'});   // not awaited: the uptime rows below must not wait behind two fetches
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
      const models=mtActive(prov);
      const cur=(mtData.defaults[tier]||{})[prov]||'';
      const opts=models.map(m=>`<option value="${escAttr(m.id)}"${m.id===cur?' selected':''}>${esc(m.name)}</option>`).join('');
      return `<div class="mt-picker"><select data-tier="${tier}" data-prov="${prov}">${opts}</select><span class="mt-prov">${prov}${prov==='openai'?' · per-ticket':''}</span></div>`;
    }).join('');
    row.querySelectorAll('select').forEach(sel=>sel.addEventListener('change',()=>mtSetDefault(sel)));
  });
  // Provider tabs
  const tabs=document.getElementById('mt-tabs');
  tabs.innerHTML=Object.entries(MT_PROVIDER_LABEL).map(([prov,label])=>
    `<div class="mt-tab${prov===mtProvider?' active':''}" data-prov="${prov}">${label} <span style="color:var(--text-dim);font-weight:400">· ${mtActive(prov).length}</span></div>`
  ).join('');
  tabs.querySelectorAll('.mt-tab').forEach(t=>t.addEventListener('click',()=>mtSwitchProvider(t.dataset.prov)));
  // Card grid
  const grid=document.getElementById('mt-grid');
  const models=mtActive(mtProvider);
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
        <div class="mt-card-actions"><button type="button" class="mt-edit b-neutral"${mtEditing?' disabled':''} aria-label="Edit ${escAttr(m.name)}">Edit</button><a class="b-danger">Remove</a></div>
      </div>`;
  }).join('') + `<div class="mt-add-card b-accent">+ Add ${esc(MT_PROVIDER_LABEL[mtProvider])} model</div>`;
  // t-783a: wired after each render; the ids come back from data-id, so no JS sits inside an attribute.
  grid.querySelectorAll('.mt-card:not(.editing)').forEach(card=>{
    card.querySelector('.mt-edit').addEventListener('click',()=>mtStartEdit(card.dataset.id));
    card.querySelector('.b-danger').addEventListener('click',()=>mtRemoveModel(card.dataset.id));
  });
  const editing=grid.querySelector('.mt-card.editing');
  if(editing){
    editing.addEventListener('keydown',e=>mtEditKey(e));
    editing.querySelector('.mt-cancel').addEventListener('click',()=>mtCancelEdit());
    editing.querySelector('.mt-save').addEventListener('click',()=>mtSaveEdit());
  }
  grid.querySelector('.mt-add-card').addEventListener('click',()=>mtAddModel());
  mtRenderSources(); mtRenderProposal(); mtRenderAlert(); mtRenderMove(); mtRenderLegacy();
}

function mtSwitchProvider(prov){ mtProvider=prov; mtEditing=null; mtMoving=null; mtRender(); }

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
      <div class="mt-card-actions"><button type="button" class="mt-cancel b-close">Cancel</button><button type="button" class="mt-save b-primary">Save</button></div>
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

const MT_ID_RE=/^[A-Za-z0-9._-]+$/; // mirrors main.go's modelIDRe

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

// t-d40b: a model that is not legacy and holds an alias or a default is not removed until the user says which model
// takes them over (the board does the move: POST /api/admin/model-tiers/remove or /retire); one that holds nothing,
// or a legacy one, is deleted outright after a confirm.
let mtMoving=null;
const MT_ALIASES=['fable','opus','sonnet','haiku'];   // the names Claude Code resolves; only Anthropic entries carry one
const mtActive=prov=>(mtData.models[prov]||[]).filter(m=>!m.legacy);
const mtLegacy=prov=>(mtData.models[prov]||[]).filter(m=>m.legacy);
function mtHeld(prov,m){
  const held=[]; if(m.alias) held.push('the alias '+m.alias);
  ['eval','light'].forEach(t=>{ if(((mtData.defaults[t]||{})[prov])===m.id) held.push('the '+(t==='eval'?'Review & Eval':'Simple / Light')+' default'); });
  return held;
}
// The newest active Anthropic model of an alias's line (claude-<alias>-<version>), if none holds the alias yet.
function mtLineModel(alias){
  const ver=id=>(id.match(/\d+/g)||[]).map(Number).filter(n=>n<100);
  const cmp=(a,b)=>{ for(let i=0;i<Math.max(a.length,b.length);i++){ const d=(a[i]||0)-(b[i]||0); if(d) return d; } return 0; };
  const c=mtActive('anthropic').filter(m=>m.id.startsWith('claude-'+alias+'-')&&!m.alias);
  return c.sort((x,y)=>cmp(ver(y.id),ver(x.id)))[0]||null;
}
function mtUnbound(){ const held=new Set(mtActive('anthropic').map(m=>m.alias).filter(Boolean)); return MT_ALIASES.filter(a=>!held.has(a)); }
function mtRenderAlert(){
  const el=document.getElementById('mt-alias-alert'); if(!el) return;
  const ub=mtUnbound();
  if(!ub.length){ el.innerHTML=''; return; }
  el.innerHTML=`<div class="mt-alert" role="status"><b>${ub.length} alias${ub.length>1?'es':''} unbound: ${ub.map(esc).join(', ')}</b><p>No active model answers to ${ub.length>1?'these aliases':'this alias'}, so the per-ticket Gate model dropdown does not offer ${ub.length>1?'them':'it'} and a gate falls back to the model its agent definition names.</p><div class="mt-alert-acts">${ub.map(a=>{ const m=mtLineModel(a); return m?`<button type="button" class="b-neutral" data-bind="${escAttr(a)}">Bind ${esc(a)} \u2192 ${esc(m.name)}</button>`:`<span>${esc(a)}: no ${esc(a)} model in the registry; add one first.</span>`; }).join('')}</div></div>`;
  el.querySelectorAll('[data-bind]').forEach(b=>b.addEventListener('click',()=>mtBind(b.dataset.bind)));
}
async function mtBind(alias){
  const m=mtLineModel(alias); if(!m) return;
  m.alias=alias;
  if(await mtSave()){ mtRender(); toast('Alias '+alias+' now points at '+m.name); }
}
function mtRenderLegacy(){
  const el=document.getElementById('mt-legacy'); if(!el) return;
  const old=mtLegacy(mtProvider);
  if(!old.length){ el.innerHTML=''; return; }
  el.innerHTML=`<details class="mt-legacy"><summary>Legacy \u00b7 ${old.length}</summary><p>Replaced by a newer model. A ticket that pins one of these ids still runs; they just no longer appear in the pickers or as a default.</p><div class="mt-legacy-grid">${old.map(m=>`<div class="mt-card legacy" data-id="${escAttr(m.id)}"><div class="mt-card-top"><span class="mt-card-name">${esc(m.name)}</span></div><div class="mt-card-id">${esc(m.id)}</div><div class="mt-card-price"><span>Input/MTok</span><span>$${esc(m.input_price)}</span></div><div class="mt-card-price"><span>Output/MTok</span><span>$${esc(m.output_price)}</span></div><div class="mt-card-actions"><button type="button" class="mt-restore b-neutral">Restore</button><a class="b-danger">Remove</a></div></div>`).join('')}</div></details>`;
  el.querySelectorAll('.mt-card').forEach(card=>{
    card.querySelector('.mt-restore').addEventListener('click',()=>mtRestore(card.dataset.id));
    card.querySelector('.b-danger').addEventListener('click',()=>mtRemoveModel(card.dataset.id));
  });
}
async function mtRestore(id){
  const m=(mtData.models[mtProvider]||[]).find(x=>x.id===id); if(!m) return;
  delete m.legacy;
  if(await mtSave()){ mtRender(); toast('Restored '+m.name); }
}
async function mtMove(action,body){
  try{
    const res=await mtPost('/api/admin/model-tiers/'+action,body);
    if(res.old){ toast(MT_OLD_BOARD); return false; }
    if(!res.ok){ toast(res.error||"Couldn't change the registry"); await mtLoad(); return false; }
    mtData=res.data; mtMoving=null; return true;
  }catch(e){ toast("Couldn't reach the board"); await mtLoad(); return false; }
}
function mtRenderMove(){
  const el=document.getElementById('mt-move'); if(!el) return;
  const m=mtMoving&&(mtData.models[mtProvider]||[]).find(x=>x.id===mtMoving);
  if(!m){ el.innerHTML=''; return; }
  const held=mtHeld(mtProvider,m);
  // an alias holder may only move to a model with no alias of its own: one entry carries one alias
  const others=mtActive(mtProvider).filter(x=>x.id!==m.id&&!(m.alias&&x.alias));
  el.innerHTML=`<div class="mt-move" role="group" aria-label="Move before removing ${escAttr(m.name)}"><b>${esc(m.name)} holds ${esc(held.join(' and '))}.</b><p>${others.length?'Pick the model that takes over before it goes. A ticket that pins this id keeps running.':'No other '+esc(MT_PROVIDER_LABEL[mtProvider])+' model can take '+(m.alias?'the alias':'it')+', so it stays. Add a model first.'}</p><div class="mt-move-acts">${others.length?`<select aria-label="Move to">${others.map(x=>`<option value="${escAttr(x.id)}">${esc(x.name)}</option>`).join('')}</select><button type="button" class="mt-move-retire b-neutral">Move, keep in Legacy</button><button type="button" class="mt-move-remove b-danger-main">Move and remove</button>`:''}<button type="button" class="mt-move-cancel b-close">Cancel</button></div></div>`;
  const to=()=>el.querySelector('select').value;
  const go=async(action,body,msg)=>{ if(await mtMove(action,body)){ mtRender(); toast(msg); } };
  const rt=el.querySelector('.mt-move-retire'), rm=el.querySelector('.mt-move-remove');
  if(rt) rt.addEventListener('click',()=>go('retire',{old:m.id,new:to()},m.name+' moved to Legacy'));
  if(rm) rm.addEventListener('click',()=>go('remove',{id:m.id,move_to:to()},'Removed '+m.name));
  el.querySelector('.mt-move-cancel').addEventListener('click',()=>{ mtMoving=null; mtRender(); });
}
// t-d40b: these calls only exist in a board built after this page. An older board answers 404 (plain text, not JSON), which must not read as
// "unreachable": it means the board needs updating and restarting.
const MT_OLD_BOARD="This board is older than this page and can't do that yet. Update canon and restart the board.";
async function mtPost(url,body){
  const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  if(r.status===404||r.status===405) return {old:true};
  return await r.json();
}
// t-d40b: Sources and Refresh. Refresh only PROPOSES; nothing is written until Apply. The sources come from the saved registry (the request
// never carries a URL), the board does the fetching, and a Models API key stays in the board's environment.
let mtStatus={}, mtBusy=false, mtProp=null, mtSel={};
const MT_SRC_KIND=s=>s.kind==='api'?'Models API \u00b7 reads '+(s.provider==='openai'?'OPENAI_API_KEY':'ANTHROPIC_API_KEY')+' from the environment':'Docs page \u00b7 '+(s.provider==='openai'?'OpenAI':'Anthropic');
// When a source was last checked and how it went is kept with the source (the board records it on every Refresh), so it survives a reload.
function mtAgo(iso){
  const t=Date.parse(iso); if(isNaN(t)) return '';
  const m=Math.round((Date.now()-t)/60000);
  if(m<1) return 'just now'; if(m<60) return m+' min ago';
  const h=Math.round(m/60); if(h<24) return h+' h ago';
  return new Date(t).toLocaleDateString(undefined,{month:'short',day:'numeric'});
}
function mtSaved(s){
  if(!s.checked_at) return {status:'never checked',ok:false,checked:false};
  const when=mtAgo(s.checked_at), full=new Date(s.checked_at).toLocaleString();
  if(s.last_ok) return {status:'checked '+when,ok:true,checked:true,title:'checked '+full};
  const why=/^key not set/.test(s.last_status||'')?'key not set':'failed';
  return {status:why+' \u00b7 '+when,ok:false,checked:true,title:(s.last_status||why)+' \u00b7 '+full};
}
function mtRenderSources(){
  const el=document.getElementById('mt-sources'); if(!el) return;
  const srcs=mtData.sources||[];
  const row=(s,i)=>{ const st=mtStatus[i]||mtSaved(s); const cls=st.ok?'ok':(st.checked?'warn':'');
    return `<div class="mt-src-row"><div><div class="mt-src-u">${esc(s.url)}</div><span class="mt-src-k">${esc(MT_SRC_KIND(s))}</span></div><span class="mt-tag ${cls}" title="${escAttr(st.title||st.status)}">${esc(st.status.length>34?st.status.slice(0,32)+'\u2026':st.status)}</span><button type="button" class="mt-src-rf b-neutral" data-i="${i}" aria-label="Refresh ${escAttr(s.url)}"${mtBusy?' disabled':''}>\u21bb</button><button type="button" class="mt-src-rm b-close" data-i="${i}" aria-label="Remove ${escAttr(s.url)}">\u2715</button></div>`; };
  el.innerHTML=`<div class="mt-sources"><header><h3>Sources</h3><span class="mt-tag">checked only when you press Refresh</span><button type="button" class="mt-rf-all b-primary"${mtBusy?' disabled':''}>${mtBusy?'<span class="mt-spin"></span>Checking\u2026':'\u21bb Refresh all'}</button></header>${srcs.map(row).join('')}<div class="mt-src-add"><input type="text" id="mt-src-url" placeholder="https://\u2026 a docs page that lists models and prices" aria-label="Source URL"><select id="mt-src-kind" aria-label="Source type"><option value="anthropic">Docs page \u00b7 Anthropic</option><option value="openai">Docs page \u00b7 OpenAI</option></select><button type="button" class="mt-src-addbtn b-neutral">+ Add source</button></div></div>`;
  el.querySelector('.mt-rf-all').addEventListener('click',()=>mtRefresh(-1));
  el.querySelectorAll('.mt-src-rf').forEach(b=>b.addEventListener('click',()=>mtRefresh(Number(b.dataset.i))));
  el.querySelectorAll('.mt-src-rm').forEach(b=>b.addEventListener('click',()=>mtRemoveSource(Number(b.dataset.i))));
  el.querySelector('.mt-src-addbtn').addEventListener('click',mtAddSource);
}
async function mtAddSource(){
  const inp=document.getElementById('mt-src-url'), url=inp.value.trim();
  if(!/^https:\/\//.test(url)){ inp.value=''; inp.placeholder='Use an https:// address'; return; }
  mtData.sources=(mtData.sources||[]).concat([{url,kind:'docs',provider:document.getElementById('mt-src-kind').value}]);
  if(await mtSave()){ mtRender(); toast('Source added'); }
}
async function mtRemoveSource(i){
  mtData.sources=(mtData.sources||[]).filter((_,k)=>k!==i); mtStatus={};
  if(await mtSave()) mtRender();
}
async function mtRefresh(index){
  if(mtBusy) return;
  mtBusy=true; mtRender();
  try{
    const res=await mtPost('/api/admin/model-tiers/refresh',index>=0?{index}:{});
    if(res.old){ toast(MT_OLD_BOARD); }
    else if(!res.ok){ toast(res.error||"Couldn't refresh"); }
    else{
      if(res.data){ mtData=res.data; mtStatus={}; }   // the registry now carries when each source was checked
      else (res.sources||[]).forEach(s=>{ mtStatus[s.index]={status:s.status,ok:s.ok,checked:true}; });
      mtProp=res.proposal||null; mtSel={};
      if(mtProp){ mtProp.add.forEach(a=>{ mtSel['a:'+a.id]=true; if(a.replaces) mtSel['r:'+a.id]=true; }); mtProp.retire.forEach(x=>{ mtSel['t:'+x.old]=true; }); }
    }
  }catch(e){ toast("Couldn't reach the board"); }
  mtBusy=false; mtRender();
}
function mtPriceNote(a){ return a.price_known?(a.price_from?'the page says "from $'+a.input_price+' / $'+a.output_price+'"':'$'+a.input_price+' in / $'+a.output_price+' out per MTok'):'no price found; set it with Edit after adding'; }
function mtRenderProposal(){
  const el=document.getElementById('mt-proposal'); if(!el) return;
  if(!mtProp){ el.innerHTML=''; return; }
  const n=mtApplyCount(), none=!mtProp.add.length&&!mtProp.retire.length;
  const addRows=mtProp.add.map(a=>`<label class="mt-chg"><input type="checkbox" data-sel="a:${escAttr(a.id)}"${mtSel['a:'+a.id]?' checked':''}><span><b>Add ${esc(a.name)}</b>${(a.price_from||!a.price_known)?' <span class="mt-tag warn">confirm price</span>':''}<small>${esc(a.id)} \u00b7 ${esc(mtPriceNote(a))}</small></span></label>${a.replaces?`<label class="mt-chg sub"${mtSel['a:'+a.id]?'':' style="opacity:.45"'}><input type="checkbox" data-sel="r:${escAttr(a.id)}"${mtSel['r:'+a.id]&&mtSel['a:'+a.id]?' checked':''}${mtSel['a:'+a.id]?'':' disabled'}><span><b>Replaces ${esc(a.replaces_name)}</b>${a.changes_gate_model?' <span class="mt-tag warn">changes the gate model</span>':''}<small>Moves its alias and any default to ${esc(a.name)}; the old entry goes to Legacy.</small></span></label>`:''}`).join('');
  const retRows=mtProp.retire.map(x=>`<label class="mt-chg"><input type="checkbox" data-sel="t:${escAttr(x.old)}"${mtSel['t:'+x.old]?' checked':''}><span><b>Retire ${esc(x.old_name)}</b>${x.changes_gate_model?' <span class="mt-tag warn">changes the gate model</span>':''}<small>${esc(x.new_name)} is already in your registry; its alias and defaults move there and the old entry goes to Legacy.</small></span></label>`).join('');
  const cur=mtProp.current.length?`<div class="mt-prop-h">Already current</div>${mtProp.current.map(c=>`<div class="mt-chg"><span>\u2713</span><span><b>${esc(c)}</b><small>no newer model of its line</small></span></div>`).join('')}`:'';
  el.innerHTML=`<div class="mt-prop" role="group" aria-label="Refresh proposal"><header><b>${none?'Nothing new found':[mtProp.add.length?mtProp.add.length+' new model'+(mtProp.add.length===1?'':'s'):'',mtProp.retire.length?mtProp.retire.length+' to retire':''].filter(Boolean).join(', ')}</b><span class="mt-tag">nothing is saved until you apply</span></header>${addRows}${retRows}${cur}<footer><span>Adding comes first, so a model exists before anything moves to it. A ticket that pins a model id is never changed. Saved to this machine's registry, not the tracked seed.</span><button type="button" class="mt-prop-dismiss b-close">Dismiss</button>${none?'':`<button type="button" class="mt-prop-apply b-primary"${n?'':' disabled'}>Apply ${n} selected</button>`}</footer></div>`;
  el.querySelectorAll('[data-sel]').forEach(b=>b.addEventListener('change',()=>{ mtSel[b.dataset.sel]=b.checked; if(b.dataset.sel.startsWith('a:')&&!b.checked) mtSel['r:'+b.dataset.sel.slice(2)]=false; mtRenderProposal(); }));
  el.querySelector('.mt-prop-dismiss').addEventListener('click',()=>{ mtProp=null; mtRenderProposal(); });
  const ap=el.querySelector('.mt-prop-apply'); if(ap) ap.addEventListener('click',mtApply);
}
function mtApplyCount(){
  if(!mtProp) return 0;
  const adds=mtProp.add.filter(a=>mtSel['a:'+a.id]);
  return adds.length+adds.filter(a=>a.replaces&&mtSel['r:'+a.id]).length+mtProp.retire.filter(x=>mtSel['t:'+x.old]).length;
}
async function mtApply(){
  const adds=mtProp.add.filter(a=>mtSel['a:'+a.id]);
  const seen=new Set(), retire=[];
  const pair=(o,nw)=>{ if(!seen.has(o)){ seen.add(o); retire.push({old:o,new:nw}); } };
  adds.forEach(a=>{ if(a.replaces&&mtSel['r:'+a.id]) pair(a.replaces,a.id); });
  mtProp.retire.forEach(x=>{ if(mtSel['t:'+x.old]) pair(x.old,x.new); });
  const n=mtApplyCount();
  try{
    const res=await mtPost('/api/admin/model-tiers/apply',{add:adds.map(a=>({id:a.id,provider:a.provider,name:a.name,input_price:a.input_price,output_price:a.output_price})),retire});
    if(res.old){ toast(MT_OLD_BOARD); return; }
    if(!res.ok){ toast(res.error||"Couldn't apply"); await mtLoad(); return; }
    mtData=res.data; mtProp=null; mtSel={}; mtRender(); toast('Saved '+n+' change'+(n===1?'':'s'));
  }catch(e){ toast("Couldn't reach the board"); await mtLoad(); }
}
async function mtRemoveModel(id){
  const m=(mtData.models[mtProvider]||[]).find(x=>x.id===id); if(!m) return;
  if(!m.legacy&&(MT_ALIASES.includes(m.alias)||mtHeld(mtProvider,m).some(h=>h.endsWith('default')))){ mtMoving=id; mtRender(); const g=document.getElementById('mt-move'); if(g) g.scrollIntoView({block:'nearest'}); return; }
  const ok=await cockpitConfirm({title:'Remove model?',body:'Removes "'+id+'" from the registry. Any ticket whose Gate model: still names it keeps that value as a hand-edit override.',okLabel:'Remove',danger:true});
  if(!ok) return;
  if(await mtMove('remove',{id})) mtRender();
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
// ── Admin > Integrity (t-2af0): read-only. GET /api/integrity; "Check again" re-reads getcanon.dev (?refresh=1). No write route.
const IG_STATE={
  'verified':['ok','Verified','These files were compared with the hashes published for this release.'],
  'not-from-release':['mute','Not a release install','There is no released copy to compare with, so nothing is shown as checked.'],
  'not-checked':['warn','Not checked','The published hashes could not be read or did not verify, so nothing is shown as checked.'],
  'list-pending':['mute','List pending','This release has no published hash list yet.'],
};
const igCardFiles=r=>new Set((r.agents||[]).map(a=>a.graded_by));   // a protocol file shown in an agent's card is not listed twice
const IG_GROUPS=[['agents','Agents'],['prompts','Prompts and protocol'],['tools','Gate files'],['programs','Programs']];
async function igLoad(refresh){
  const box=document.getElementById('ig-body'); if(!box) return;
  box.innerHTML='<div class="setting-d">Checking\u2026</div>';
  let r; try{ r=await (await fetch('/api/integrity'+(refresh?'?refresh=1':''))).json(); }catch(e){ box.innerHTML='<div class="setting-d">Could not reach the board.</div>'; return; }
  const [cls,label,note]=IG_STATE[r.state]||['mute',r.state,''];
  let h=`<div class="ig-strip ig-${cls}"><b>${esc(label)}</b>${r.tag?' \u00b7 '+esc(r.tag):''}${r.state==='verified'?` \u00b7 ${r.match} of ${r.total} files match${r.source==='cached'?' \u00b7 saved list':''}`:''}`+
    `<button type="button" class="ig-again b-accent" id="ig-again">Check again</button></div>`+
    `<div class="setting-d">${esc(r.reason||note)}</div>`;
  {
    const files=r.files||[];
    const stateLabel=(IG_STATE[r.state]||[0,r.state])[1];
    const pill=rows=>{ if(r.state!=='verified') return `<span class="ig-pill ig-pill-mute">${esc(stateLabel)}</span>`; const bad=rows.filter(x=>x.status!=='match').length; return bad?`<span class="ig-pill ig-pill-bad">${bad} differ${bad===1?'s':''}</span>`:`<span class="ig-pill ig-pill-ok">Matches ${esc(r.tag)}</span>`; };
    const fileRow=x=>`<div class="ig-frow ig-${x.status}"><span class="ig-dot"></span><code>${esc(x.path)}</code>`+(x.gate?'<span class="ig-gate">gate file</span>':'')+
      (x.status!=='match'?`<span class="ig-st">${esc(x.status)}</span>`:'')+
      (x.restore?`<div class="ig-fix">Put it back: <code>${esc(x.restore)}</code> <button type="button" class="ig-copy b-neutral" data-cmd="${escAttr(x.restore)}">Copy</button></div>`:'')+`</div>`;
    h+=IG_GROUPS.map(([g,name])=>{
      const rows=files.filter(x=>x.group===g&&!(g==='prompts'&&igCardFiles(r).has(x.path))); if(!rows.length) return '';
      let body;
      if(g==='agents'){
        body=(r.agents||[]).map(a=>{
          const own=rows.filter(x=>x.path===a.file)[0];
          const extra=files.filter(x=>x.path===a.graded_by);
          const list=[own].concat(extra).filter(Boolean);
          const kv=(k,v)=>v?`<div class="ig-kv"><span class="ig-k">${k}</span><span>${v}</span></div>`:'';
          return `<div class="ig-card"><div class="ig-card-h"><b class="ig-name">${esc(a.name)}</b>`+
            (a.role?`<span class="ig-badge">${esc(a.role)}</span>`:'')+(a.read_only?'<span class="ig-badge" title="No Edit or Write tool. The shell can still write.">read-only</span>':'')+
            `<span class="ig-card-pill">${pill(list)}</span></div>`+
            kv('Model',esc(a.model))+kv('Effort',esc(a.effort))+kv('Tools',esc(a.tools))+kv('Writes',a.writes?`<code>${esc(a.writes)}</code> only`:'')+
            `<div class="ig-files">${list.map(fileRow).join('')}</div>`+
            (a.prompt?`<details class="ig-prompt"><summary>Prompt \u00b7 ${esc(a.file)}</summary><pre>${esc(a.prompt)}</pre></details>`:'')+`</div>`;
        }).join('')||rows.map(fileRow).join('');
        const shown=new Set((r.agents||[]).flatMap(a=>[a.file,a.graded_by]));
        const rest=rows.filter(x=>!shown.has(x.path)); if(rest.length) body+=`<div class="ig-files">${rest.map(fileRow).join('')}</div>`;
      } else body=`<div class="ig-files">${rows.map(fileRow).join('')}</div>`;
      const inAgents=g==='agents'?rows.concat(files.filter(x=>(r.agents||[]).some(a=>a.graded_by===x.path))):rows;
      return `<div class="ig-ghead"><span class="ig-group">${esc(name)}</span><span class="ig-count">${rows.length} file${rows.length===1?'':'s'}</span>${pill(inAgents)}</div>${body}`;
    }).join('');
    if(r.state==='verified'&&r.blocking) h+='<div class="setting-d ig-block">A gate file or gate prompt differs, so <code>sprint complete</code> will refuse to close until it is put back.</div>';
  }
  box.innerHTML=h;
  document.getElementById('ig-again').addEventListener('click',()=>igLoad(true));
  box.querySelectorAll('.ig-copy').forEach(b=>b.addEventListener('click',async()=>{
    try{ await navigator.clipboard.writeText(b.dataset.cmd); toast('Copied'); }catch(e){ toast('Select the command and copy it'); }
  }));
}
// t-565f: admin's load-time code, run once at the end (the module version keeps it in initAdmin()).
export function initAdmin(){

// Restart/Stop both reuse the daemon's token-free /api/cockpit-restart|-stop
// (busy-confirm + re-poll) — OS pid-kill only, never the daemon's own
// token-gated shutdown route (t-ddc8).
// t-d40b: Admin's own tabs. The daemon panel and the agent list above stay on every tab; Model tiers is the default.
const AD_TABS=['tiers','logging','integrity'];
function adminTab(name){
  document.querySelectorAll('.ad-tab').forEach(b=>{ const on=b.dataset.adtab===name; b.classList.toggle('active',on); b.setAttribute('aria-selected',String(on)); b.tabIndex=on?0:-1; });
  AD_TABS.forEach(n=>{ const p=document.getElementById('ad-panel-'+n); if(p) p.hidden=n!==name; });
  if(name==='integrity') igLoad(false);
}
function initAdminTabs(){
  const strip=document.querySelector('.ad-tabs'); if(!strip) return;
  strip.addEventListener('click',e=>{ const b=e.target.closest('.ad-tab'); if(b) adminTab(b.dataset.adtab); });
  strip.addEventListener('keydown',e=>{   // the tablist keys: arrows step, Home and End jump
    const cur=AD_TABS.indexOf((strip.querySelector('.ad-tab.active')||{dataset:{}}).dataset.adtab); let n=cur;
    if(e.key==='ArrowRight') n=(cur+1)%AD_TABS.length; else if(e.key==='ArrowLeft') n=(cur-1+AD_TABS.length)%AD_TABS.length;
    else if(e.key==='Home') n=0; else if(e.key==='End') n=AD_TABS.length-1; else return;
    e.preventDefault(); adminTab(AD_TABS[n]); document.getElementById('ad-tab-'+AD_TABS[n]).focus();
  });
}
document.addEventListener('DOMContentLoaded',()=>{
  initAdminTabs();
  const rb=document.getElementById('ad-restart');
  if(rb) rb.addEventListener('click',restartDaemon);
  const sb=document.getElementById('ad-stop');
  if(sb) sb.addEventListener('click',stopDaemon);
  const db=document.getElementById('ad-debug-toggle');
  if(db) db.addEventListener('change',onDebugToggleChange);
});
}
