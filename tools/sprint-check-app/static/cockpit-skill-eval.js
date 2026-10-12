// t-565f: the Cockpit shell's skill-eval code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initSkillEval(), which cockpit-main.js runs in order once every module has loaded.
import { cockpitConfirm, esc, escAttr } from './cockpit-core.js';
import { _normPath } from './cockpit-sessions.js';
import { UPKEEP_MODEL_LABELS, upFmtWhen, upHelpBtn, upHelpSync, upProjectId, upToggleCollapse } from './cockpit-upkeep.js';
import { getProjects } from './cockpit-projects.js';

// ── Skill Eval (t-23d8): free checks on a picked skill folder, then the paid plugin eval ──
// Every path/gate decision is re-made by the server (validate_skill_dir, confirm_cost, fail and
// trust gates); this UI only guides. The run is read-only and uses the signed-in Claude account.
const se={dir:'',check:null,err:'',open:false,cwd:'',hidden:false,trust:false,run:null,avail:null};
let sePoll=null;
const SE_ICON={pass:'&#10003;',warn:'&#9650;',fail:'&#10005;',lock:'&#128274;'};
const SE_LABEL={pass:'Pass',warn:'Warning',fail:'Fail',lock:'Locked'};
// t-d2e1: k comes from the server's check results, so it is escaped, and only an own key picks an icon or label.
const sePill=(k,t)=>`<span class="se-pill ${esc(k)}">${Object.hasOwn(SE_ICON,k)?SE_ICON[k]:''} ${esc(t||(Object.hasOwn(SE_LABEL,k)?SE_LABEL[k]:k))}</span>`;
const seQuery=()=>'project='+encodeURIComponent(upProjectId)+'&skill_dir='+encodeURIComponent(se.dir);
const seWorst=rows=>rows.some(r=>r.status==='fail')?'fail':rows.some(r=>r.status==='warn')?'warn':'pass';
function seStageWord(rows){
  const f=rows.filter(r=>r.status==='fail').length, w=rows.filter(r=>r.status==='warn').length;
  return f ? 'Failed' : w ? 'Passed · '+w+' warning'+(w>1?'s':'') : 'Passed';
}
export function seReset(){
  clearInterval(sePoll); sePoll=null;
  Object.assign(se,{dir:'',check:null,err:'',open:false,cwd:'',trust:false,run:null});
}
function seRows(rows){
  return rows.map(r=>`<div class="se-row ${esc(r.status)}"><div>${sePill(r.status)}</div><div class="id">${esc(r.id)}</div><div class="ev">${esc(r.evidence)}</div>`
    +(r.fix?`<div class="fix">${esc(r.fix)}</div>`:'')+'</div>').join('');
}
function seStage(n,name,rows){
  const attn=rows.filter(r=>r.status!=='pass'), ok=rows.filter(r=>r.status==='pass');
  return `<div class="se-sec"><h4>${n} · ${esc(name)} ${sePill(seWorst(rows),seStageWord(rows))}</h4>`
    +(attn.length?seRows(attn):'<div class="se-note">Nothing needs attention.</div>')
    +(ok.length?`<details><summary>${ok.length} passing check${ok.length>1?'s':''}</summary>${seRows(ok)}</details>`:'')+'</div>';
}
function seResult(st){
  const m=st.summary||{};
  const pct=v=>v==null?'—':Math.round(v*100)+'%';
  const num=v=>v==null?'—':v.toFixed(2);
  const cases=(m.cases||[]).map(c=>`<div class="se-case"><div class="id mono">${esc(c.name)}</div><div>`
    +`<div class="se-bar" title="with the skill"><i class="w" style="width:${Math.round((c.with||0)*100)}%"></i><span>${num(c.with)}</span></div>`
    +`<div class="se-bar" title="without the skill"><i class="b" style="width:${Math.round((c.without||0)*100)}%"></i><span>${num(c.without)}</span></div></div></div>`).join('');
  const link=st.report_path?`<a class="btn" href="/api/skill-eval/report.html?${seQuery()}" target="_blank" rel="noopener">Open full report</a>`:'';
  const when=upFmtWhen(st.finished_at);
  return `<div class="se-tiles">`
    +`<div class="se-tile"><div class="k">With the skill</div><div class="v">${pct(m.overallScore)}</div></div>`
    +`<div class="se-tile"><div class="k">Skill effect (mean Δ)</div><div class="v">${m.meanDelta==null?'—':(m.meanDelta>=0?'+':'')+m.meanDelta.toFixed(2)}</div></div>`
    +`<div class="se-tile"><div class="k">Cases passed</div><div class="v">${esc(m.casesPassed??'—')} / ${esc(m.casesTotal??'—')}</div></div>`
    +`<div class="se-tile"><div class="k">Est. cost (list price)</div><div class="v">${m.costUsd==null?'—':'$'+m.costUsd.toFixed(2)}</div></div></div>`
    +(cases?`<div class="se-note" style="margin-top:10px">Score per case: <b style="color:var(--accent)">with</b> vs <b>without</b> the skill</div>${cases}`:'')
    +`<div class="rc-actions" style="margin-top:12px">${link}${when?`<span class="se-note" style="align-self:center">Last run — ${esc(when)}</span>`:''}</div>`;
}
// t-56f6: ask once per page load whether this board build runs Skill Eval at all. The Go build
// (Windows) marks every Skill Eval route unsupported:true; anything else — Python's plain
// "pick a folder" error, a failed fetch, an old server — counts as available, as before.
async function seProbe(){
  se.avail='probing';
  let d=null;
  try{ d=await (await fetch('/api/skill-eval/status?project='+encodeURIComponent(upProjectId))).json(); }catch(e){}
  se.avail=!(d&&d.unsupported===true);
  seRender();
}
export function seRender(){
  const el=document.getElementById('se-card'); if(!el) return;
  if(se.avail===null) seProbe();
  const proj=getProjects().find(p=>p.id===upProjectId);
  const c=se.check, rows=c?c.checks:[];
  const s1=rows.filter(r=>r.stage===1), s2=rows.filter(r=>r.stage===2);
  const w1=seWorst(s1), w2=seWorst(s2), blocked=!c||w1==='fail'||w2==='fail';
  const trust=rows.filter(r=>/^trust-/.test(r.id)&&r.status==='warn');
  const running=!!(se.run&&se.run.status==='running');
  let h=`<div class="rc-top"><div class="rc-icon">&#9878;</div><div class="rc-head"><div class="rc-title">Skill Eval</div>`
    +`<p class="rc-desc">Check that a skill ships evals and follows Anthropic's authoring rules, then measure it with and without the skill.</p></div>${upHelpBtn('skill-eval')}</div>`;
  if(se.avail===false){
    el.innerHTML=h+`<div class="se-pick"><button class="btn" disabled>Browse…</button></div>`
      +`<div class="se-note">Skill Eval isn't available in this build of the board (the Go build used on Windows). See README → Windows: what's different.</div>`;
    upHelpSync();
    return;
  }
  h+=`<div class="se-pick"><button class="btn se-browse">Browse…</button>`
    +`<span class="se-path">${se.dir?esc(se.dir):'Pick a skill folder inside '+esc(proj?proj.name:'the project')+' (the folder that contains SKILL.md)'}</span></div>`;
  if(se.open){
    h+=`<div class="dirnav"><div class="dirnav-head"><span class="dirnav-path" title="${escAttr(se.cwd)}">${esc(se.cwd||'…')}</span></div>`
      +`<div class="dirnav-controls"><label class="dirnav-hidden-lbl"><input type="checkbox" class="se-hidden" ${se.hidden?'checked':''}> Show hidden</label>`
      +`<button class="btn dirnav-use se-use">Use this folder</button></div><div class="dirnav-list" id="se-list"></div></div>`;
  }
  if(se.err) h+=`<div class="se-err">${esc(se.err)}</div>`;
  if(c){
    const s3=blocked?'lock':(se.run&&se.run.status==='done'?'pass':'lock');
    const s3txt=blocked?'Locked':running?'Running…':(se.run&&se.run.status==='done')?'Ran · '+((se.run.summary||{}).casesPassed??'?')+' of '+((se.run.summary||{}).casesTotal??'?')+' cases pass':'Ready';
    h+=`<div class="se-steps">`
      +`<div class="se-step"><div class="k">Stage 1 · Free</div><div class="n">Eval coverage</div><div class="d">Does the skill ship test cases?</div>${sePill(w1,seStageWord(s1))}</div>`
      +`<div class="se-step"><div class="k">Stage 2 · Free</div><div class="n">Best practices</div><div class="d">Anthropic's skill authoring rules</div>${sePill(w2,seStageWord(s2))}</div>`
      +`<div class="se-step"><div class="k">Stage 3 · Uses your Claude usage</div><div class="n">Plugin eval</div><div class="d">With the skill vs. without it</div>${sePill(s3,s3txt)}</div></div>`;
    h+=seStage(1,'Eval coverage',s1)+seStage(2,'Best practices',s2);
    h+='<div class="se-sec"><h4>3 · Plugin eval</h4>';
    if(blocked){
      h+=`<div class="se-note">Fix the failing check${(w1==='fail'&&w2==='fail')?'s':''} above to unlock this stage. Nothing has been run or spent.</div>`;
    }else{
      h+=`<div class="rc-config"><select class="rc-select" id="se-model" title="Model"${running?' disabled':''}><option value="claude-haiku-4-5-20251001" selected>Haiku 4.5</option><option value="claude-sonnet-5">Sonnet 5</option></select>`
        +`<button class="btn primary se-run"${(running||(trust.length&&!se.trust))?' disabled':''}>${running?'Running…':(se.run&&se.run.status==='done'?'&#8635; Run again':'&#9654; Run plugin eval')}</button>`
        +((trust.length&&!se.trust&&!running)?'<span class="se-note">Tick the box below to enable Run.</span>':'')+'</div>';
      if(trust.length) h+=`<label class="se-note se-ack"><input type="checkbox" class="se-trust" ${se.trust?'checked':''}> This skill runs hooks or shell commands (${esc(trust.map(t=>t.id).join(', '))}). I have reviewed them and want to run it anyway.</label>`;
      if(se.run&&se.run.status==='done') h+='<div style="margin-top:12px">'+seResult(se.run)+'</div>';
      else if(se.run&&se.run.status==='error') h+='<div class="se-err" style="margin-top:8px">The run failed. Check the board server log for the eval output.</div>';
    }
    h+='</div>';
  }
  el.innerHTML=h;
  el.querySelector('.se-browse').addEventListener('click',()=>seToggleBrowse());
  el.querySelector('.se-hidden')?.addEventListener('change',e=>{ se.hidden=e.target.checked; seLoad(se.cwd); });
  el.querySelector('.se-use')?.addEventListener('click',()=>seUse());
  el.querySelector('.se-run')?.addEventListener('click',()=>seRun());
  el.querySelector('.se-trust')?.addEventListener('change',e=>{ se.trust=e.target.checked; seRender(); });
  upHelpSync();
  if(se.open) seLoad(se.cwd);
}
// Explain the two real failures instead of "request failed": a board server started before this
// page's routes existed answers 404 (plain text, not JSON); a stopped server refuses the connection.
async function seJson(url,opts){
  let r;
  try{ r=await fetch(url,opts); }catch(e){ return {ok:false,error:'Could not reach the board server. Is it still running?'}; }
  if(r.status===404) return {ok:false,error:'This board server is older than this page. Restart it to use Skill Eval.'};
  try{ return await r.json(); }catch(e){ return {ok:false,error:'The board server sent an unexpected reply (HTTP '+r.status+').'}; }
}
async function seLoad(path){
  const d=await seJson('/api/browse-dirs?path='+encodeURIComponent(path||'')+(se.hidden?'&hidden=1':''));
  const list=document.getElementById('se-list'); if(!list) return;
  if(d.error){ list.innerHTML='<div class="dirnav-empty">'+esc(d.error)+'</div>'; return; }
  se.cwd=d.path||'';
  const proj=getProjects().find(p=>p.id===upProjectId);
  const atRoot=proj && _normPath(se.cwd)===_normPath(proj.path);
  const pathEl=document.querySelector('#se-card .dirnav-path'); if(pathEl){ pathEl.textContent=se.cwd; pathEl.title=se.cwd; }
  let rows=(d.parent&&!atRoot)?'<div class="dirnav-row up" data-path="'+escAttr(d.parent)+'">↰ ..</div>':'';
  rows+=(d.entries||[]).map(e=>'<div class="dirnav-row" data-path="'+escAttr(e.path)+'">📁 '+esc(e.name)+'</div>').join('');
  list.innerHTML=rows||'<div class="dirnav-empty">No subfolders.</div>';
  list.querySelectorAll('.dirnav-row').forEach(r=>r.addEventListener('click',()=>seLoad(r.dataset.path)));
}
function seToggleBrowse(){
  se.open=!se.open;
  if(se.open){ const proj=getProjects().find(p=>p.id===upProjectId); se.cwd=se.cwd||(proj?proj.path:''); }
  seRender();
}
async function seUse(){
  if(!se.cwd) return;
  se.dir=se.cwd; se.open=false; se.err=''; se.check=null; se.run=null; se.trust=false;
  clearInterval(sePoll); sePoll=null;
  seRender();
  const r=await seJson('/api/skill-eval/check?project='+encodeURIComponent(upProjectId),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({skill_dir:se.dir})});
  if(!r.ok){ se.err=r.error||'Could not check that folder.'; se.dir=''; seRender(); return; }
  se.check=r;
  try{
    const st=await (await fetch('/api/skill-eval/status?'+seQuery())).json();
    if(st.ok && st.status!=='never') se.run=st;
    if(st.status==='running') seStartPoll();
  }catch(e){}
  seRender();
}
function seStartPoll(){
  if(sePoll) return;
  sePoll=setInterval(async()=>{
    let st={};
    try{ st=await (await fetch('/api/skill-eval/status?'+seQuery())).json(); }catch(e){ return; }
    if(st.status!=='running'){ clearInterval(sePoll); sePoll=null; se.run=st; seRender(); }
  },3000);
}
async function seRun(){
  const modelEl=document.getElementById('se-model');
  const model=modelEl?modelEl.value:'claude-haiku-4-5-20251001';
  const label=UPKEEP_MODEL_LABELS[model]||model;
  const name=se.dir.split(/[\\/]/).pop();
  const ok=await cockpitConfirm({
    title:'Run plugin eval on '+name+'?',
    body:'Runs each eval case twice, with and without the skill, on Claude '+label+' using your signed-in account. Estimated up to $3 at list price; on a subscription this counts against your plan usage. Read-only — nothing in the project is modified.',
    okLabel:'Run',
  });
  if(!ok) return;
  se.err='';
  const r=await seJson('/api/skill-eval/run?project='+encodeURIComponent(upProjectId),{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skill_dir:se.dir,model,confirm_cost:true,allow_trust:se.trust,max_cost_usd:3})});
  if(!r.ok && !r.busy){ se.err=r.error||'Could not start the run.'; seRender(); return; }
  se.run={status:'running'}; seRender(); seStartPoll();
}
// t-565f: skill-eval's load-time code, run once at the end (the module version keeps it in initSkillEval()).
export function initSkillEval(){
document.addEventListener('DOMContentLoaded',()=>document.querySelector('#up-detail .up-detail-head').addEventListener('click',()=>upToggleCollapse()));
}
