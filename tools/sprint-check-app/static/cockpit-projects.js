// t-565f: the Cockpit shell's projects code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initProjects(), which cockpit-main.js runs in order once every module has loaded.
import { cockpitConfirm, esc, escAttr, openHelp, toast } from './cockpit-core.js';
import { GIT_ICON, SCRATCH_ICON, renderSessionSurfaces, startScratch, startSessionPoll } from './cockpit-sessions.js';
import { showView } from './cockpit-views.js';
import { openSkillEvalFor } from './cockpit-skill-eval.js';
import { openLogbookFor } from './cockpit-logbook.js';
import { LOGBOOK_ICON } from './logbook-icon.js';
import { learningsSummary } from './learnings-parse.js';
import { fillCardFactory, openFactoryGithub } from './cockpit-factory.js';
import { closeTab, openProject, openTabs, restoreTabs, updateActiveCount } from './cockpit-tabs.js';

// t-96c3: the "important" onboarding skills the card offers to register, in
// display order. Single source of truth — the card buttons are generated from
// this (mirrors the server-side REGISTERABLE_SKILLS allowlist).
const IMPORTANT_SKILLS=['efficiency','sprint'];
// Per-skill confirm() copy for the register action (co-located with the list).
const REG_SKILL_DETAIL={
  sprint:'wires the sprint workflow into the project — updates AGENTS.md/CLAUDE.md, installs a git pre-commit hook, creates .tickets/, and links the skills dir',
  efficiency:'is optional (sprint doesn’t need it): it adds canon’s coding and git conventions for all agent work — updates AGENTS.md/CLAUDE.md and links the skills dir'
};
let knownIds=new Set();     // registered project ids (for restore filtering)

// t-565f: the registered projects, owned here (no longer a window property); readers use getProjects().
let registeredProjects=[];
export function getProjects(){ return registeredProjects; }
export async function load(){
  let projects=[];
  try{const r=await fetch('/api/projects');projects=await r.json();}catch(e){}
  registeredProjects=projects;
  knownIds=new Set(projects.map(p=>p.id));
  document.getElementById('pcount').textContent=projects.length;

  updateActiveCount(); // open-tab count; the registered count is in the sidebar too

  const grid=document.getElementById('grid');
  if(!projects.length){
    grid.innerHTML='<div class="empty">No projects registered yet.<br>Click <strong>+ Add Project</strong> to register a project folder.</div>';
    return;
  }
  grid.innerHTML=projects.map(p=>`
      <div class="card">
        <div class="cardhead"><h3 title="${escAttr(p.name)}">${esc(p.name)}</h3><button type="button" class="gitstate" hidden data-id="${escAttr(p.id)}" data-name="${escAttr(p.name)}">${GIT_ICON}</button></div>
        <div class="path" title="${escAttr(p.path)}">${esc(p.path)}</div>
        <div class="desc">${esc(p.description||'')}</div>
        <div class="cardfoot">
          <div class="meta" data-stats="${escAttr(p.id)}">
            <div class="metarow"><span class="k">Added</span><span class="v">${esc(p.added||'')}</span></div>
            <div class="metarow"><span class="k">Updated</span><span class="v" data-f="updated">…</span></div>
            <div class="metarow"><span class="k">Total Tickets</span><span class="v" data-f="count">…</span></div>
            <div class="metarow"><span class="k">Skills</span><span class="v" data-f="skills">…</span></div>
            <div class="metarow skhealth-row" data-f="skhealth-row" hidden><span class="k">Skill issue</span><span class="v"><span class="skhealth-text" data-f="skhealth"></span><button type="button" class="skrefresh b-accent" data-skrefresh="${escAttr(p.id)}" data-name="${escAttr(p.name)}" data-path="${escAttr(p.path)}" title="Run skills.sh refresh in this project: it re-links the skills and fixes the AGENTS.md rows">Refresh</button></span></div>
            <div class="metarow" data-f="sessions-row" hidden><span class="k">Sessions</span><span class="v" data-f="sessions"></span></div>
            <div class="metarow" data-f="stopped-row" hidden><span class="k">Stopped</span><span class="v" data-f="stopped"></span></div>
            <div class="metarow lb-link-row" data-logbook="${escAttr(p.id)}" title="Open the Logbook: this project's Handoff and Learnings"><span class="k">Learnings</span><span class="v">${LOGBOOK_ICON}<span data-f="learnings">…</span></span></div>
            <div class="metarow se-link-row" data-skill-eval="${escAttr(p.id)}" title="Check a skill folder in this project"><span class="k">Skill Eval</span><span class="v">Open</span></div>
            <div class="metarow fac-row" data-factory="${escAttr(p.id)}" title="Open this project's Factory"><span class="k">Factory</span><span class="v" data-f="factory">…</span></div>
          </div>
          <div class="card-divider"></div>
          <div class="cardbottom">
            <div class="regbtns" data-reg="${escAttr(p.id)}" aria-live="polite" style="display:none">
              ${IMPORTANT_SKILLS.map(sk=>`<button class="regskill b-accent" data-skill="${sk}" title="Not set up in this project yet — click to register the ${sk} skill" data-id="${escAttr(p.id)}" data-name="${escAttr(p.name)}" data-path="${escAttr(p.path)}" style="display:none">+ ${sk}${sk==='efficiency'?' (optional)':''}</button>`).join('')}
            </div>
            <div class="actions">
              <button class="scratchbtn b-accent" title="Start an agent in this project with no ticket" data-scratch="${escAttr(p.id)}">${SCRATCH_ICON}Scratch</button>
              <button class="dereg b-danger-main" title="Deregister" data-id="${escAttr(p.id)}" data-name="${escAttr(p.name)}">&#10005;</button>
              <button class="go" title="Open project" data-open="${escAttr(p.id)}" data-name="${escAttr(p.name)}">&#8250;</button>
            </div>
          </div>
        </div>
      </div>`).join('');
  // Delegated handlers (no inline onclick with interpolated user data — avoids
  // JS-string/attribute injection from a maliciously-named registered path).
  grid.querySelectorAll('.dereg').forEach(b=>b.addEventListener('click',()=>dereg(b.dataset.id,b.dataset.name)));
  grid.querySelectorAll('.scratchbtn').forEach(b=>b.addEventListener('click',()=>startScratch(b.dataset.scratch)));
  grid.querySelectorAll('.go').forEach(b=>b.addEventListener('click',()=>openProject(b.dataset.open,b.dataset.name,{nudge:true})));
  grid.querySelectorAll('.se-link-row').forEach(r=>r.addEventListener('click',()=>openSkillEvalFor(r.dataset.skillEval)));
  grid.querySelectorAll('.skrefresh').forEach(b=>b.addEventListener('click',()=>refreshSkills(b.dataset.skrefresh,b.dataset.name,b.dataset.path,b)));
  grid.querySelectorAll('.lb-link-row').forEach(r=>r.addEventListener('click',()=>openLogbookFor(r.dataset.logbook)));
  grid.querySelectorAll('.fac-row').forEach(r=>r.addEventListener('click',()=>openFactoryGithub(r.dataset.factory)));
  grid.querySelectorAll('.regskill').forEach(b=>b.addEventListener('click',()=>registerSkill(b.dataset.id,b.dataset.name,b.dataset.path,b.dataset.skill,b)));
  grid.querySelectorAll('.gitstate').forEach(b=>b.addEventListener('click',()=>{ if(b.classList.contains('is-off')) trackChanges(b.dataset.id,b.dataset.name,b); }));
  projects.forEach(p=>fillCardStats(p.id));
  renderSessionSurfaces();
}

// t-8381: the card's Learnings row, from the project's LEARNINGS.md (one parser, learnings-parse.js). It says whether lessons wait for
// /promote-learnings and when the sweep last ran; a failed read shows "—", never a count. A failed refresh keeps what is shown.
const sweptWhen=d=>{ if(!d) return ''; const t=new Date(), today=`${t.getFullYear()}-${String(t.getMonth()+1).padStart(2,'0')}-${String(t.getDate()).padStart(2,'0')}`; return ' \u00b7 swept '+(d===today?'today':d.slice(5)); };
function learningsText(lb){
  const f=lb&&lb.learnings;
  if(!f||f.error) return '\u2014';
  if(f.missing) return 'Not needed yet';
  const s=learningsSummary(f.text);
  if(!s.rows) return 'Not needed yet';
  return (s.pending?s.pending+' to promote':'None to promote')+sweptWhen(s.swept);
}
async function fillCardLearnings(id,el,refresh){
  const v=el.querySelector('[data-f="learnings"]');
  try{
    const r=await fetch('/api/logbook?project='+encodeURIComponent(id));
    if(!r.ok) throw 0;
    v.textContent=learningsText(await r.json());
  }catch(e){ if(!refresh) v.textContent='\u2014'; }
}

// t-5738: the cards were filled once at load, so tickets made while the Cockpit stayed open never showed (Total Tickets 0 until a restart).
// refreshStats re-reads every card (tickets, updated, skills, learnings, git icon; not Factory) when the Projects page is shown again and
// every 30 s while it is on screen. A card has one read at a time: a request that arrives mid-read is remembered and re-read once, so
// the newer state is never dropped. A failed refresh keeps the value already shown.
const statsBusy=new Set(), statsAgain=new Set();
export function refreshStats(){
  registeredProjects.forEach(p=>{
    if(statsBusy.has(p.id)){ statsAgain.add(p.id); return; }
    statsBusy.add(p.id);
    fillCardStats(p.id,true).finally(()=>{
      statsBusy.delete(p.id);
      if(statsAgain.delete(p.id)) refreshStats();
    });
  });
}
function projectsPageShown(){ const g=document.getElementById('grid'); return !!g && g.offsetParent!==null && document.visibilityState==='visible'; }
async function fillCardStats(id,refresh){
  const el=document.querySelector('.meta[data-stats="'+(window.CSS&&CSS.escape?CSS.escape(id):id)+'"]');
  if(!el) return;
  fillCardLearnings(id,el,refresh);
  fillCardSkillHealth(id,el,refresh);
  if(!refresh) fillCardFactory(id,el);   // Factory has its own refresh; re-reading it here would re-run gh every interval
  const up=el.querySelector('[data-f="updated"]'), ct=el.querySelector('[data-f="count"]'), sk=el.querySelector('[data-f="skills"]');
  try{
    const r=await fetch('/api/project-stats?project='+encodeURIComponent(id));
    if(!r.ok) throw 0;
    const s=await r.json();
    up.textContent=s.updated||'—';
    ct.textContent=(s.ticket_count!=null?s.ticket_count:'—');
    const skills=Array.isArray(s.skills)?s.skills:[];
    if(sk) sk.textContent = skills.length ? skills.join(', ') : '—';
    // t-96c3: offer a register button for each "important" skill (efficiency,
    // sprint) NOT yet registered; hide the row when both are present.
    const card=el.closest('.card');
    const reg=card&&card.querySelector('.regbtns');
    if(reg){
      let any=false;
      reg.querySelectorAll('.regskill').forEach(b=>{
        const show=!skills.includes(b.dataset.skill);
        b.style.display = show ? '' : 'none';
        any = any || show;
      });
      reg.style.display = any ? '' : 'none';
    }
    // t-8d72 (was the t-d538 chip): the Git icon reads the same status and stays hidden when it cannot say.
    const gs=card&&card.querySelector('.gitstate');
    if(gs){
      let st=null, got=false;
      try{ const t=await fetch('/api/track-changes?project='+encodeURIComponent(id)); if(t.ok){ st=await t.json(); got=true; } }catch(e){}
      if(got||!refresh) setGitState(gs,st);   // a failed refresh leaves the icon as it was
    }
  }catch(e){ if(!refresh){ up.textContent='—'; ct.textContent='—'; if(sk) sk.textContent='—'; } }
}

// t-8d72: the icon's three states, from GET /api/track-changes. A non-git folder cannot run agents until it is
// tracked (t-d538), so Off is clickable; On and None only explain (aria-disabled, so the tooltip still shows).
function setGitState(gs,st){
  gs.classList.remove('is-on','is-off','is-none');
  gs.dataset.synced=(st&&st.synced)||'';
  let cls='', tip='';
  if(st&&st.ok){
    if(st.tracking===true){ cls='is-on'; tip='Git enabled — this project keeps a version history'; }
    else if(st.git_available===false){ cls='is-none'; tip="Version history needs Git, which isn't installed on this computer"; }
    else if(st.tracking===false){ cls='is-off'; tip='Git not enabled — click to turn on version history'; }
  }
  if(!cls){ gs.hidden=true; return; }
  gs.classList.add(cls);
  gs.title=tip; gs.setAttribute('aria-label',tip);
  gs.setAttribute('aria-disabled', cls==='is-off' ? 'false' : 'true');
  gs.hidden=false;
}

// t-7485/t-96c3: register one of the "important" skills (sprint / efficiency)
// into a project from its card. Confirms the side effects, POSTs to the
// registered-id-only endpoint with the chosen skill, then refreshes. If the
// host can't run it (no bash/skills.sh — e.g. Windows Go binary), surfaces the
// exact copy-paste command instead of failing silently.
// t-7d8d: one run per project at a time — two concurrent skills.sh add runs race on
// AGENTS.md and settings.json.
const _regBusy=new Set();
// t-6541: the card's skill problems, from skills.sh's own check (GET /api/skills-health: status --json, cached on the server). A
// problem shows with Refresh; a check that could not run says so (never "healthy"); a healthy project shows no row.
async function fillCardSkillHealth(id,el,refresh){
  const row=el.querySelector('[data-f="skhealth-row"]'), txt=el.querySelector('[data-f="skhealth"]'), btn=row&&row.querySelector('.skrefresh');
  if(!row||!txt) return;
  let h;
  try{ const r=await fetch('/api/skills-health?project='+encodeURIComponent(id)); h=r.ok?await r.json():null; }catch(e){ h=null; }
  if(!h){ if(refresh) return; h={ok:false,error:'could not check'}; }
  if(!h.ok){ row.hidden=false; txt.textContent='\u26a0 '+(h.error||'could not check'); if(btn) btn.hidden=true; return; }
  const bad=(h.skills||[]).filter(s=>s.problems&&s.problems.length);
  row.hidden=!bad.length;
  if(btn) btn.hidden=!bad.length;
  txt.textContent=bad.map(s=>'\u26a0 '+s.name+': '+s.problems.join(', ')).join('; ');
}

// t-6541: Refresh runs skills.sh refresh in that project from the board (POST /api/skills-refresh: a fixed command, the board's
// non-interactive defaults), busy like the Project tab's add, then the card re-reads.
const _refreshBusy=new Set();
async function refreshSkills(id,name,path,btn){
  if(_refreshBusy.has(id)) return;
  _refreshBusy.add(id);
  const saved=btn.innerHTML; btn.disabled=true; btn.setAttribute('aria-busy','true');
  btn.innerHTML='<span class="reg-spin" aria-hidden="true"></span>'+esc('Refreshing…');
  try{
    const r=await fetch('/api/skills-refresh?project='+encodeURIComponent(id),{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    const res=await r.json().catch(()=>({}));
    if(res&&res.ok){ toast('\u2713 Refreshed the skills in '+name); }
    else if(res&&res.unsupported){ await cockpitConfirm({title:'Refresh the skills manually', body:'This host can\u2019t run it \u2014 run this in Git Bash, then reopen the project:', code: res.cmd||('skills.sh refresh '+path), okOnly:true, okLabel:'Done'}); }
    else await cockpitConfirm({title:'Refresh did not finish', body:(res&&res.error)||'skills.sh refresh failed', code:(res&&res.output)||'', okOnly:true, okLabel:'Close'});
  }catch(e){ toast('Request failed'); }
  finally{
    _refreshBusy.delete(id); btn.disabled=false; btn.removeAttribute('aria-busy'); btn.innerHTML=saved;
    fillCardStats(id,true);
  }
}

export async function registerSkill(id,name,path,skill,btn){
  skill=skill||'sprint';
  if(_regBusy.has(id)) return;
  const detail = REG_SKILL_DETAIL[skill] || ('registers the “'+skill+'” skill');
  if(!(await cockpitConfirm({title:'Register the “'+skill+'” skill in “'+name+'”?', body:'This '+detail+'. Safe to re-run.', okLabel:'Register'}))) return;
  if(_regBusy.has(id)) return;
  _regBusy.add(id);
  const btns=[...document.querySelectorAll('.regskill')].filter(b=>b.dataset.id===id);
  if(btn&&!btns.includes(btn)) btns.push(btn);
  const saved=btns.map(b=>b.innerHTML);
  btns.forEach(b=>{ b.disabled=true; });
  if(btn){ btn.setAttribute('aria-busy','true'); btn.innerHTML='<span class="reg-spin" aria-hidden="true"></span>'+esc('Adding '+skill+'…'); }
  let restored=false;
  const restore=()=>{
    if(restored) return; restored=true;
    _regBusy.delete(id);
    btns.forEach((b,i)=>{ b.disabled=false; b.removeAttribute('aria-busy'); b.innerHTML=saved[i]; });
  };
  try{
    const r=await fetch('/api/register-skill?project='+encodeURIComponent(id)+'&skill='+encodeURIComponent(skill),{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    const res=await r.json().catch(()=>({}));
    if(res&&res.ok){ toast('✓ Registered '+skill+' in '+name); load(); return; }
    if(res&&res.unsupported){ restore(); await cockpitConfirm({title:'Register '+skill+' manually', body:'This host can’t run it — run this in a terminal, then reopen the project:', code: res.cmd||('skills.sh add '+skill+' '+path), okOnly:true, okLabel:'Done'}); return; }
    toast((res&&res.error)?('Could not register: '+res.error):('Could not register '+skill));
  }catch(e){ toast('Request failed'); }
  finally{ restore(); }
}

// t-d538: opt-in local history (git init + a .gitignore-only first commit) for a registered
// non-git folder. The server re-resolves the folder from the registry and refuses on any
// existing .git; this only explains and confirms.
async function trackChanges(id,name,btn){
  if(btn.disabled) return;
  const synced=btn.dataset.synced;
  const body='Keeps a full history of this folder\u2019s files on this computer, so you can go back to earlier versions. It needs Git installed. Nothing is uploaded and your files stay exactly as they are. Agents can run here without it.'
    +(synced?' Note: this folder is in '+synced+'. Sync services can damage this history — consider moving the project out of '+synced+' first.':'');
  if(!(await cockpitConfirm({title:'Turn on version history for “'+name+'”?', body, okLabel:'Turn on'}))) return;
  const saved=btn.innerHTML;
  btn.disabled=true; btn.setAttribute('aria-busy','true'); btn.innerHTML='<span class="reg-spin" aria-hidden="true"></span>';
  try{
    const r=await fetch('/api/track-changes?project='+encodeURIComponent(id),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({confirm:true})});
    const res=await r.json().catch(()=>({}));
    if(res&&res.ok){ toast('✓ '+name+' now keeps a version history'); load(); return; }
    toast((res&&res.error)?res.error:'Could not turn on version history (HTTP '+r.status+')');
  }catch(e){ toast('Request failed'); }
  finally{ btn.disabled=false; btn.removeAttribute('aria-busy'); btn.innerHTML=saved; }
}

function openAdd(){document.getElementById('addErr').textContent='';document.getElementById('addPath').value='';document.getElementById('addDesc').value='';hideBrowse();document.getElementById('addModal').classList.add('show');document.getElementById('addPath').focus();}
function closeAdd(){document.getElementById('addModal').classList.remove('show');hideBrowse();}

// ── Add-Project folder browser (t-1b88) ────────────────────────────────────
// A web page can't read an absolute path, so navigate via the loopback
// /api/browse-dirs (directory names only) and hand the chosen path back to the
// text input. The text input still works for typing a known path.
let _browseCwd='';
function hideBrowse(){ const n=document.getElementById('dirnav'); if(n) n.style.display='none'; }
function toggleBrowse(){
  const n=document.getElementById('dirnav');
  if(n.style.display==='none'){ n.style.display=''; loadBrowse(document.getElementById('addPath').value.trim()); }
  else { n.style.display='none'; }
}
async function loadBrowse(path){
  const list=document.getElementById('dirnav-list');
  list.innerHTML='<div class="dirnav-empty">…</div>';
  const showHidden=!!(document.getElementById('dirnav-hidden')&&document.getElementById('dirnav-hidden').checked);
  let d={};
  try{ d=await (await fetch('/api/browse-dirs?path='+encodeURIComponent(path||'')+(showHidden?'&hidden=1':''))).json(); }catch(e){ d={error:'request failed'}; }
  if(d.error){ list.innerHTML='<div class="dirnav-empty">'+esc(d.error)+'</div>'; return; }
  _browseCwd=d.path||'';
  const p=document.getElementById('dirnav-path'); p.textContent=_browseCwd; p.title=_browseCwd;
  let rows='';
  if(d.parent) rows+='<div class="dirnav-row up" data-path="'+escAttr(d.parent)+'">↰ ..</div>';
  rows+=(d.entries||[]).map(e=>'<div class="dirnav-row" data-path="'+escAttr(e.path)+'">📁 '+esc(e.name)+'</div>').join('');
  list.innerHTML=rows||'<div class="dirnav-empty">No subfolders.</div>';
  list.querySelectorAll('.dirnav-row').forEach(r=>r.addEventListener('click',()=>loadBrowse(r.dataset.path)));
}
function useBrowseDir(){
  if(_browseCwd){ document.getElementById('addPath').value=_browseCwd; }
  hideBrowse();
  document.getElementById('addPath').focus();
}

async function submitAdd(){
  const path=document.getElementById('addPath').value.trim();
  const description=document.getElementById('addDesc').value;
  const err=document.getElementById('addErr');
  err.textContent='';
  if(!path){err.textContent='Path is required.';return;}
  try{
    const r=await fetch('/api/projects',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path,description})});
    const res=await r.json();
    if(!res.ok){err.textContent=res.error||'Could not add project.';return;}
    const nm=(res.project&&res.project.name)||'project';
    closeAdd();
    // t-07c8: a non-git folder registers with a non-blocking warning.
    toast(res.warning ? ('⚠ Added '+nm+' — '+res.warning) : ('Added '+nm));
    load();
  }catch(e){err.textContent='Request failed.';}
}

async function dereg(id,name){
  if(!(await cockpitConfirm({title:'Deregister “'+name+'”?', body:'This removes it from the Cockpit list only — your project files are not touched.', okLabel:'Deregister', danger:true}))) return;
  try{
    await fetch('/api/projects/'+encodeURIComponent(id),{method:'DELETE'});
    if(openTabs.some(t=>t.id===id)) closeTab(id); // close its tab if open
    toast('Deregistered '+name);load();
  }catch(e){toast('Could not deregister.');}
}
// t-4700: `#open=<id>` deep-links straight into a project's tab — used by
// `sprint-check` so it opens the project instead of the bare landing page.
function openFromHash(){
  const m=/^#open=(.+)$/.exec(location.hash);
  if(!m) return false;
  const id=decodeURIComponent(m[1]);
  const p=getProjects().find(p=>p.id===id);
  if(!p) return false;
  openProject(id,p.name,{nudge:true});
  return true;
}
// t-565f: projects's load-time code, run once at the end (the module version keeps it in initProjects()).
export function initProjects(){
document.addEventListener('DOMContentLoaded',()=>{
  document.getElementById('add-open').addEventListener('click',()=>openAdd());
  document.getElementById('add-browse').addEventListener('click',()=>toggleBrowse());
  document.getElementById('dirnav-hidden').addEventListener('change',()=>loadBrowse(_browseCwd));
  document.getElementById('add-use-dir').addEventListener('click',()=>useBrowseDir());
  document.getElementById('add-cancel').addEventListener('click',()=>closeAdd());
  document.getElementById('add-submit').addEventListener('click',()=>submitAdd());
});

setInterval(()=>{ if(projectsPageShown()) refreshStats(); },30000);
document.addEventListener('visibilitychange',()=>{ if(projectsPageShown()) refreshStats(); });
document.addEventListener('DOMContentLoaded',()=>{   // switching back to the Projects tab shows the grid again
  const g=document.getElementById('grid');
  if(g && 'IntersectionObserver' in window) new IntersectionObserver(es=>{ if(es.some(e=>e.isIntersecting)) refreshStats(); }).observe(g);
});

fetch('/api/version').then(r=>r.json()).then(v=>{if(v&&v.version)document.getElementById('ver').textContent='v'+v.version;}).catch(()=>{});
// Initial load, then restore any previously-open project tabs (once).
load().then(()=>{ restoreTabs(); startSessionPoll(); if(!openFromHash()){ if(location.hash==='#admin') showView('admin'); if(location.hash==='#help') openHelp(); } });
}
