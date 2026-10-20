// t-9641: the Cockpit shell's Factory page (per project; GitHub moved here from Admin, t-90a3). Declarations only:
// the load-time code is initFactory(), which cockpit-main.js runs in order once every module has loaded.
import { esc, escAttr, toast } from './cockpit-core.js';
import { activeTab, isProjectTab, openProject } from './cockpit-tabs.js';
import { getProjects } from './cockpit-projects.js';
import { showView } from './cockpit-views.js';

// ── Doctor cache ─────────────────────────────────────────────────────────
// `tkt github-doctor --json` via GET /api/github/doctor, the one readiness source (t-90a3). gh runs per check, so each
// project's answer is fetched once per shell load (the Projects card and this page share it) and again only on
// Check again, never on a poll.
const doctors=new Map();   // project id -> Promise<{ok, doctor?, output?}>
let doctorQueue=Promise.resolve();   // one doctor at a time: a page of cards never starts N gh runs at once
function fetchDoctor(pid, force){
  if(force || !doctors.has(pid)){
    const run=()=>fetch('/api/github/doctor?project='+encodeURIComponent(pid))
      .then(r=>r.ok?r.json():{ok:false,output:'HTTP '+r.status}, e=>({ok:false,output:String(e.message||e)}));
    const p=doctorQueue.then(run,run)
      .then(res=>{ if(!(res&&res.ok&&res.doctor)) doctors.delete(pid); return res; });   // a failed read is tried again next time
    doctors.set(pid,p); doctorQueue=p;
    return p;
  }
  return doctors.get(pid);
}
function checksOf(res){ return res&&res.ok&&res.doctor&&Array.isArray(res.doctor.checks)?res.doctor.checks:null; }

// The Projects card's Factory row (t-9641): "GitHub ready · agentic off ›", "GitHub needs setup · …", or muted
// "Not set up" when the project has no GitHub origin. The agentic line is not built yet, so it always reads off.
export function factoryRow(res){
  const checks=checksOf(res);
  if(!checks) return {text:'GitHub · could not check ›', muted:true};
  if(checks.some(c=>c.id==='origin'&&c.status==='bad')) return {text:'Not set up', muted:true};
  return {text:(checks.some(c=>c.status==='bad')?'GitHub needs setup':'GitHub ready')+' · agentic off ›', muted:false};
}
export function fillCardFactory(pid, el){
  const v=el.querySelector('[data-f="factory"]');
  if(!v) return;
  fetchDoctor(pid,false).then(res=>{ const r=factoryRow(res); v.textContent=r.text; v.classList.toggle('muted',r.muted); });
}
function refreshCardRow(pid){
  const el=document.querySelector('.meta[data-stats="'+(window.CSS&&CSS.escape?CSS.escape(pid):pid)+'"]');
  if(el) fillCardFactory(pid,el);
}

// ── Factory > GitHub ─────────────────────────────────────────────────────
let ghPid=null, ghDoctor=null, ghGen=0, ghWant='';
// t-24b1: a board's "GitHub · set up first" row, or a Projects card's Factory row, asks for that project's checks.
export function openFactoryGithub(pid){ ghWant=pid; ghPid=null; facTab('gh'); showView('factory'); }
export function loadFactory(){ ghLoad(false); }
function ghPickProject(){
  const sel=document.getElementById('fac-gh-project'), projects=getProjects();
  const want=ghWant||sel.value||(isProjectTab(activeTab)?activeTab:'')||(projects[0]&&projects[0].id)||'';
  ghWant='';
  sel.innerHTML=projects.map(p=>`<option value="${escAttr(p.id)}">${esc(p.name)}</option>`).join('');
  if(projects.some(p=>p.id===want)) sel.value=want;
  const p=projects.find(x=>x.id===sel.value);
  document.getElementById('fac-gh-proj').innerHTML=p?`Project <b>${esc(p.name)}</b> · <code>${esc(p.path)}</code><span class="fac-proj-note">These settings apply to this project only.</span>`:'No project registered.';
  return sel.value;
}
async function ghLoad(force){
  const pid=ghPickProject();
  if(!pid || (!force && pid===ghPid)) return;
  ghPid=pid; const gen=++ghGen;
  document.getElementById('fac-gh-count').textContent='Checks · checking…';
  intakeWaiting('Checking…');
  const res=await fetchDoctor(pid,force);
  if(gen!==ghGen) return;
  if(force) refreshCardRow(pid);
  ghDoctor=res.ok&&res.doctor?res.doctor:null;
  if(!ghDoctor) ghPid=null;   // a failed read is tried again the next time Factory opens
  ghRender(res);
  intakeLoad(pid,gen);
}
function ghRender(res){
  const box=document.getElementById('fac-gh-checks'), count=document.getElementById('fac-gh-count');
  if(!ghDoctor){ count.textContent='Checks'; document.getElementById('fac-gh-copy-domains').disabled=document.getElementById('fac-gh-copy-script').disabled=true; box.innerHTML=`<div class="gh-row gh-bad"><i></i><em class="gh-n"></em><div><b>Could not run the checks</b><pre>${esc(res.output||'')}</pre></div></div>`; return; }
  const checks=ghDoctor.checks||[];
  count.textContent=`Checks · ${checks.filter(c=>c.status!=='bad').length} of ${checks.length} ready`;
  box.innerHTML=checks.map((c,i)=>{
    const f=c.fix||{};
    const fix=f.cmd?`<code>${esc(f.cmd)}</code><button type="button" class="btn primary" data-gh-copy="${escAttr(f.cmd)}">Copy</button>`
      :/^https:\/\//.test(f.url||'')?`<a href="${escAttr(f.url)}" target="_blank" rel="noopener">${esc(f.url)} \u2197</a>`:'';
    // numbered like the steps below; the fix sits under the text so a long command never squeezes the title
    return `<div class="gh-row gh-${escAttr(c.status)}" data-check="${escAttr(c.id)}"><i></i><em class="gh-n">${i+1}.</em><div><b>${esc(c.title)}</b><span>${esc(c.detail||'')}</span>${fix?`<div class="gh-fix">${fix}</div>`:''}</div></div>`;
  }).join('');
  const cloud=ghDoctor.cloud||{};
  document.getElementById('fac-gh-copy-domains').disabled=!(cloud.domains||[]).length;
  document.getElementById('fac-gh-copy-script').disabled=!cloud.setup_script;
  document.getElementById('fac-gh-domains').innerHTML=(cloud.domains||[]).map(d=>`<code>${esc(d)}</code>`).join('');
}
function ghCopy(text){
  try{ navigator.clipboard.writeText(text).then(()=>toast('Copied'),()=>toast('Copy failed')); }catch(e){ toast('Copy failed'); }
}

// ── Intake (t-9641) ──────────────────────────────────────────────────────
// GET /api/github/intake: `tkt sync-issues --dry-run --json` (issues labelled canon that no ticket links to yet) and the
// newest github.synced event. Issue titles and event values are untrusted: text only, through esc().
function intakeWaiting(html){ document.getElementById('fac-in-wait').innerHTML=html; }
async function intakeLoad(pid, gen){
  const repo=document.getElementById('fac-in-repo'), last=document.getElementById('fac-in-last');
  repo.textContent=last.textContent='—';
  if(!ghDoctor || (ghDoctor.checks||[]).some(c=>c.status==='bad')){
    intakeWaiting('Unavailable until the checks above pass. Sync from GitHub on the board is disabled meanwhile.');
    return;
  }
  intakeWaiting('Checking…');
  let res;
  try{ const r=await fetch('/api/github/intake?project='+encodeURIComponent(pid)); res=r.ok?await r.json():{ok:false,output:'HTTP '+r.status,old:r.status===404}; }
  catch(e){ res={ok:false,output:String(e.message||e)}; }
  if(gen!==ghGen) return;
  const ls=res&&res.last_synced;
  if(ls&&ls.ts){
    const n=+ls.count, when=new Date(ls.ts);
    last.textContent=(isNaN(when)?ls.ts:when.toLocaleString())+' · '+n+' ticket'+(n===1?'':'s')+' made';
  } else last.textContent='never';
  const d=res&&res.ok&&res.intake;
  // a 404 is a board started before this route existed (the page files are newer than the running binary)
  if(!d){ intakeWaiting(res&&res.old?'This board is older than the page. Restart <code>canon</code> (Ctrl+C, then <code>canon</code>) to read the waiting issues.':`<pre>${esc((res&&res.output)||'')}</pre>`); return; }
  repo.textContent=String(d.repo||'—')+' (origin)';
  const w=Array.isArray(d.waiting)?d.waiting:[];
  intakeWaiting(!w.length?'No open issue labelled <code>canon</code> is waiting.'
    :`${w.length} open issue${w.length===1?'':'s'} labelled <code>canon</code>:<ul class="fac-wait">`+
      w.map(i=>`<li><b>#${esc(String(i.issue))}</b> ${esc(String(i.title||''))}</li>`).join('')+'</ul>');
}

// ── Tabs ─────────────────────────────────────────────────────────────────
function facTab(which){
  document.querySelectorAll('[data-fac-tab]').forEach(t=>{
    const on=t.dataset.facTab===which;
    t.classList.toggle('active',on); t.setAttribute('aria-selected',String(on)); t.tabIndex=on?0:-1;
  });
  document.getElementById('fac-gh').hidden=which!=='gh';
  document.getElementById('fac-line').hidden=which!=='line';
}

// t-9641: factory's load-time code, run once at the end.
export function initFactory(){
document.addEventListener('DOMContentLoaded',()=>{
  document.querySelectorAll('[data-fac-tab]').forEach(t=>{
    t.addEventListener('click',()=>facTab(t.dataset.facTab));
    t.addEventListener('keydown',e=>{
      if(e.key!=='ArrowLeft'&&e.key!=='ArrowRight') return;
      e.preventDefault();
      const other=document.querySelector('[data-fac-tab]:not([aria-selected="true"])');
      facTab(other.dataset.facTab); other.focus();
    });
  });
  document.getElementById('fac-gh-project').addEventListener('change',()=>ghLoad(false));
  document.getElementById('fac-gh-recheck').addEventListener('click',()=>ghLoad(true));
  document.getElementById('fac-gh-checks').addEventListener('click',e=>{ const b=e.target.closest('[data-gh-copy]'); if(b) ghCopy(b.dataset.ghCopy); });
  document.getElementById('fac-gh-copy-domains').addEventListener('click',()=>ghCopy(((ghDoctor&&ghDoctor.cloud&&ghDoctor.cloud.domains)||[]).join('\n')));
  document.getElementById('fac-gh-copy-script').addEventListener('click',()=>ghCopy((ghDoctor&&ghDoctor.cloud&&ghDoctor.cloud.setup_script)||''));
  document.getElementById('fac-in-board').addEventListener('click',()=>{
    const p=getProjects().find(x=>x.id===document.getElementById('fac-gh-project').value);
    if(p) openProject(p.id,p.name);
  });
});
}
