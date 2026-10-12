// t-565f: the Cockpit shell's upkeep code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initUpkeep(), which cockpit-main.js runs in order once every module has loaded.
import { cockpitConfirm, esc, escAttr } from './cockpit-core.js';
import { showView } from './cockpit-views.js';
import { seRender, seReset } from './cockpit-skill-eval.js';
import { activateTab, activeTab, applySplit, openProject, setUpkeepPane } from './cockpit-tabs.js';
import { getProjects } from './cockpit-projects.js';

// ── Views: Projects vs Admin vs Upkeep (t-5dc2, t-7ae6) ───────────────────
// t-67ab: the card's Branch and Upkeep rows (how many of the checks have never run).
export async function fillCardBranchUpkeep(id,el){
  const br=el.querySelector('[data-f="branch"]'), up=el.querySelector('[data-f="upkeep"]');
  try{
    const r=await fetch('/api/git?project='+encodeURIComponent(id)); const g=r.ok?await r.json():null;
    const row=br.closest('.metarow');
    if(g&&g.is_git===false){ if(row) row.hidden=true; }   // t-5a4b: no git, no branch to show
    else{ if(row) row.hidden=false; br.textContent=(g&&g.branch)||'—'; }
  }catch(e){ br.textContent='—'; }
  try{
    const st=await Promise.all(UPKEEP_SKILLS.map(s=>fetch('/api/upkeep/status?project='+encodeURIComponent(id)+'&skill='+encodeURIComponent(s.id)).then(r=>r.ok?r.json():null).catch(()=>null)));
    if(st.some(x=>!x)) throw 0;
    const never=st.filter(x=>!x.finished_at && x.status!=='running').length;
    up.textContent= never===0 ? 'all checks run' : never+' check'+(never===1?'':'s')+' never run';
  }catch(e){ up.textContent='—'; }
}

// ── Upkeep (t-7ae6): headless, read-only per-project report runner ────────
const UPKEEP_SKILLS = [
  {id:'context-check', icon:'&#9689;', title:'context-check', desc:'Audits always-on context load for bloat, redundancy, and quality.'},
  {id:'context-doctor', icon:'&#10010;', title:'context-doctor', desc:'Audits repo context vs. context-engineering lessons for the running model.'},
  {id:'dead-code-cleanup', icon:'&#9986;', title:'dead-code-cleanup', desc:'Scans for unreferenced symbols. Advisory-first — never deletes without confirmation.'},
  {id:'promote-learnings', icon:'&#8593;', title:'promote-learnings', desc:'Fresh-context review of pending LEARNINGS.md rows — proposes promotions, never writes unconfirmed.'},
];
// ── "?" info popovers (t-576f). Text is sourced from tools/upkeep-run's header, each skill's SKILL.md,
// skills/sprint/reference/complete.md and the plugin-evals doc; keep it in step with them. ──
const UP_HOW='Click Run and the board starts <code>upkeep-run</code>, which launches a fresh, headless <code>claude -p</code> session against this project. The skill\'s own SKILL.md is checked against a pinned hash first, so a tampered copy is refused. It reads the repo and writes one Markdown report under the project\'s <code>.reports/</code>; you read it here with View report.';
const UP_NOT='It does not edit your code or config, runs no arbitrary shell commands, and never auto-executes the report\'s Next Steps. Its tools are limited to reading (plus read-only git and wc) and writing the one report; the single-file limit itself is enforced by the prompt, not by the tool.';
const UP_COST='One headless Claude session on your account, which can take many tool turns: Haiku 4.5 by default, Sonnet 5 if you pick it. On a subscription it counts against your plan usage.';
const UP_HELP={
  'skill-eval':{title:'Skill Eval',
    lead:"Checks that a skill folder ships evals and follows Anthropic's skill-authoring rules, then measures the skill with and without it.",
    sections:[
      ['The three stages','<b>1 Eval coverage</b> (free): does <code>evals/evals.json</code> exist with enough varied cases?<br><b>2 Best practices</b> (free): frontmatter, description, size and trust checks based on Anthropic\'s published rules.<br><b>3 Plugin eval</b> (paid): runs <code>claude plugin eval</code>. Stage 3 unlocks only when stages 1 and 2 have no failure, and a skill with hooks or shell blocks needs your explicit OK.'],
      ['What we hand to plugin eval','Your <code>evals.json</code> is converted to eval cases. Each gets an LLM-judge rubric built from its expectations, plus, for most cases, a check that the skill actually fired. Every case runs twice with the skill and twice without it (the baseline); the difference is the skill\'s effect. The grading itself is Anthropic\'s <code>claude plugin eval</code>.'],
      ['Limits','Scores come from an LLM judge, so they are only as good as your evals. Each run starts in an empty working directory (per the plugin-evals doc) with read-only tools, and expectations about saving memory are dropped. A skill that refuses direct invocation, as wrapup does, may never fire and so scores as if it did nothing. Canon\'s own skills are never picked here.'],
      ['What to do next','Open the full report (link above). A stage 1/2 failure: fix the flagged frontmatter, eval-coverage, or trust issue directly in the skill folder, then re-run. A stage 3 result: compare the with-skill and without-skill scores — a skill that didn\'t move the needle needs a stronger description or examples, not just more evals.']],
    facts:[['Cost','stage 3 uses your Claude usage, capped near $3 (list price) per run'],['Writes','run state in the project\'s .reports/skillEvalRuns.json; reports stay in canon\'s cache']]},
  'context-check':{title:'context-check',
    lead:'Audits how heavy and redundant your always-on context is.',
    sections:[['How it happens',UP_HOW],
      ['Why it runs','Each run compares its finding count to your last run on this repo, so the report shows whether context got lighter or heavier since then. Files such as CLAUDE.md and AGENTS.md load into every session, so bloat there costs tokens and attention on every turn. Run it when sessions feel heavy, or periodically to keep the always-on budget lean.'],
      ['What to do next','Read <code>context-check-report.md</code>, then trim or fix what it flags directly — no further command. Re-run later to see the Trend line move.'],
      ['What it does not do',UP_NOT],
      ['Cost',UP_COST]],
    facts:[['Reads','always-on context files, project and global'],['Writes','one report, plus a run-history file for the trend line']]},
  'context-doctor':{title:'context-doctor',
    lead:"Audits your repo's agent context against context-engineering lessons for Claude 4/5 models.",
    sections:[['How it happens',UP_HOW],
      ['Why it runs','It looks at the system prompt, CLAUDE.md/AGENTS.md, skills and references and reports what to tighten. The model it targets is the one that runs the audit: the model you pick on this card.'],
      ['What to do next','Read <code>claude-optimization.md</code>\'s Summary table, then apply the suggested tightening directly to your context setup — no further command.'],
      ['What it does not do',UP_NOT],
      ['Cost',UP_COST]],
    facts:[['Reads','agent context, skills, references'],['Writes','one report']]},
  'dead-code-cleanup':{title:'dead-code-cleanup',
    lead:'Finds likely-unreferenced symbols so you can consider removing them.',
    sections:[['How it happens',UP_HOW],
      ['Why it runs','It scans for top-level symbols with no references (JS/TS exports, Python def/class, Go exported functions) and ranks removal candidates as high or low confidence. It is a heuristic, so a candidate can be wrong.'],
      ['What to do next','Re-invoke this skill in an interactive session to review candidates and confirm removals — Upkeep\'s headless run stops at the report.'],
      ['What it does not do','Run from Upkeep it never reaches its deletion step: nothing is removed. '+UP_NOT],
      ['Cost',UP_COST]],
    facts:[['Reads','source files'],['Writes','one report']]},
  'promote-learnings':{title:'promote-learnings',
    lead:"A fresh-context review of pending learnings rows. It proposes where each durable one belongs and never writes it.",
    sections:[['How it happens',UP_HOW+' It reads the UNPROMOTED rows in LEARNINGS.md, then each row\'s source <code>.tickets/&lt;id&gt;/learnings.md</code> in full. It can also be run directly, any time, outside Upkeep — e.g. <code>/promote-learnings</code> — the UNPROMOTED queue does not need to wait for a board click.'],
      ['Why it runs','The sprint that produced a lesson cannot judge whether it generalises, so promotion must be done by a reader with no memory of that sprint. Every Upkeep run is a fresh subprocess, so that holds automatically. For each durable row it proposes one destination: in canon, a file such as one under <code>standards/</code>; in any other project, that project\'s own <code>PROMOTED.md</code>.'],
      ['Where learnings come from','<b>1</b> <code>tkt learn &lt;id&gt;</code> (the sprint agent runs this itself at close, when there is anything to distill) distils a closed sprint\'s non-delivered plan rows and evaluator findings into an UNPROMOTED <code>.tickets/&lt;id&gt;/learnings.md</code>.<br><b>2</b> <code>learnings-sweep</code> (also automatic, right after) indexes those into LEARNINGS.md.<br><b>3</b> This card judges them.'],
      ['Example output — from a past run, not a live preview','<code>### t-f15b: ...</code><br><b>Durable:</b> yes — <b>Proposed destination:</b> standards/efficiency.md<br><code>### t-c6fa: ...</code><br><b>Durable:</b> no — <b>Proposed destination:</b> dismiss<br>Every report ends: <i>"In canon, this skill never writes these changes itself. (In a consumer project, confirmed PROMOTED.md proposals go through the Apply step instead.) Apply them by hand…"</i><br>Captured before those rows were promoted — today\'s queue may hold different rows, or none.'],
      ['What to do next','To move the learnings, run <code>/promote-learnings</code> in an interactive session. In any other project it asks which proposals to apply, writes the ones you confirm into <code>PROMOTED.md</code> (loaded every session via <code>AGENTS.md</code>), and marks each row promoted in LEARNINGS.md. In canon there is no promote command that writes: follow the report\'s Next Steps, hand-edit each proposed destination file, and flip that row\'s Status in LEARNINGS.md yourself.'],
      ['What it does not do','Run from Upkeep, it never writes LEARNINGS.md, <code>PROMOTED.md</code>, <code>standards/</code> or <code>critique/</code>. '+UP_NOT],
      ['Cost',UP_COST]],
    facts:[['Reads','LEARNINGS.md and ticket learnings'],['Writes','one report']]}
};
export let upHelpOpen=null, upHelpScroll=0;
export function upHelpBtn(id){
  const h=UP_HELP[id]; if(!h) return '';
  return `<span class="rc-help-wrap"><button type="button" class="rc-help" aria-label="About ${escAttr(h.title)}" aria-expanded="${upHelpOpen===id}" aria-controls="up-help-${id}">?</button></span>`;
}
function upHelpPanelHTML(id){
  const h=UP_HELP[id];
  return `<div class="rc-pop" id="up-help-${id}" role="region" aria-label="About ${escAttr(h.title)}"><div class="rc-pop-body">`
    +`<div class="rc-pop-head"><span class="rc-pop-title">${esc(h.title)}</span><button type="button" class="rc-pop-x" aria-label="Close">&times;</button></div>`
    +`<p class="rc-pop-lead">${esc(h.lead)}</p>`
    +(h.sections.some(s=>s[0]===UP_NEXT)?`<button type="button" class="rc-pop-jump">&rarr; ${UP_NEXT}</button>`:'')
    +h.sections.map(s=>`<div class="rc-pop-sec${s[0]===UP_NEXT?' next" id="up-help-'+id+'-next':''}"><div class="rc-pop-eyebrow">${esc(s[0])}</div><p>${s[1]}</p></div>`).join('')
    +`<div class="rc-pop-facts">${h.facts.map(f=>`<span class="rc-pop-fact"><b>${esc(f[0])}</b>${esc(f[1])}</span>`).join('')}</div>`
    +'</div></div>';
}
// Keeps the DOM in step with upHelpOpen; called after every card (re)render so a poll refresh does not close it.
// t-783a: it also wires the "?" buttons (once each: a button can outlive a sync) and each freshly built panel.
const upHelpWired=new WeakSet();
export function upHelpSync(){
  document.querySelectorAll('[data-help]').forEach(card=>{
    const id=card.dataset.help, open=upHelpOpen===id;
    const btn=card.querySelector('.rc-help'); if(btn) btn.setAttribute('aria-expanded',String(open));
    if(btn&&!upHelpWired.has(btn)){ upHelpWired.add(btn); btn.addEventListener('click',()=>upHelpToggle(id)); }
    const wrap=card.querySelector('.rc-help-wrap'); if(!wrap) return;
    const pop=wrap.querySelector('.rc-pop');
    if(open&&!pop){
      wrap.insertAdjacentHTML('beforeend',upHelpPanelHTML(id)); upHelpPlace(wrap.querySelector('.rc-pop'));
      wrap.querySelector('.rc-pop-x').addEventListener('click',()=>upHelpClose(true));
      const jump=wrap.querySelector('.rc-pop-jump'); if(jump) jump.addEventListener('click',()=>upHelpJump(id));
      wrap.querySelector('.rc-pop-body').scrollTop=upHelpScroll;   // a card re-render rebuilds the panel; keep the reader's place
    }
    else if(!open&&pop) pop.remove();
  });
}
// Open downward unless there is more room above; cap the body height to the room actually available.
function upHelpPlace(pop){
  // Room above is measured from #views' top edge: the tab strip sits above it and would cover the panel.
  const main=document.querySelector('.main'), mr=main?main.getBoundingClientRect():{left:0};
  const views=pop.closest('.views'), topEdge=views?views.getBoundingClientRect().top:0;
  const w=pop.parentElement.getBoundingClientRect(), below=window.innerHeight-w.bottom-44, above=w.top-topEdge-16;
  const up=below<300&&above>below;
  pop.classList.toggle('up',up);
  if(main) pop.style.width=Math.max(220,Math.min(400,w.right+6-mr.left-12))+'px';   // never spill under the sidebar on a narrow window
  pop.querySelector('.rc-pop-body').style.maxHeight=Math.max(160,Math.min(520,up?above:below))+'px';
}
const UP_NEXT='What to do next';
// Scroll only the panel body: scrollIntoView would also scroll the page behind the popover.
function upHelpJump(id){
  const sec=document.getElementById(`up-help-${id}-next`), body=sec&&sec.closest('.rc-pop-body'); if(!body) return;
  body.scrollBy({top:sec.getBoundingClientRect().top-body.getBoundingClientRect().top-4,behavior:'smooth'});
}
function upHelpToggle(id){ upHelpOpen=(upHelpOpen===id)?null:id; upHelpScroll=0; upHelpSync(); }
// focusBtn: Escape and the x hand focus back to the "?"; an outside click leaves focus where the user put it.
function upHelpClose(focusBtn){
  const id=upHelpOpen; upHelpOpen=null; upHelpScroll=0; upHelpSync();
  if(focusBtn&&id){ const b=document.querySelector(`[data-help="${id}"] .rc-help`); if(b) b.focus(); }
}

export let upProjectId=null;
const upPollTimers={};

export function upFmtWhen(finishedAt){
  if(!finishedAt) return null;
  const d=new Date(finishedAt*1000);
  return isNaN(d.getTime()) ? null : d.toLocaleString(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'});
}

export async function loadUpkeep(){
  const proj=getProjects().find(p=>p.id===upProjectId);
  document.getElementById('up-proj').textContent=proj?proj.name:'';
  if(!proj){ document.getElementById('up-grid').innerHTML='<span class="up-empty">Open a project, then its Upkeep button.</span>'; return; }
  await upRenderGrid();
  seRender();
}

// t-67ab: Upkeep belongs to a project tab — opened by that tab's board (or its Projects card),
// it shows only that project; ← Board returns to the tab.
export function openUpkeepFor(pid){
  if(!getProjects().some(p=>p.id===pid)) return;
  if(pid!==upProjectId){
    seReset();
    Object.keys(upPollTimers).forEach(k=>{clearInterval(upPollTimers[k]); delete upPollTimers[k];});
    upProjectId=pid;
  }
  if(activeTab!==pid){ const p=getProjects().find(x=>x.id===pid); openProject(pid,p.name); }
  showView('upkeep');
}

async function upFetchState(skill){
  try{
    const r=await fetch('/api/upkeep/status?project='+encodeURIComponent(upProjectId)+'&skill='+encodeURIComponent(skill));
    if(r.ok) return await r.json();
  }catch(e){}
  return {status:'idle', report_path:''};
}

export async function upRenderGrid(){
  const states=await Promise.all(UPKEEP_SKILLS.map(s=>upFetchState(s.id)));
  // Ascending by last-run: never-run sorts first (oldest/most-overdue), then
  // by finished_at ascending; a currently-running item sorts by its own
  // started-at proxy (now, so it lands near the "recent" end).
  const rows=UPKEEP_SKILLS.map((s,i)=>({s, st:states[i]}));
  rows.sort((a,b)=>{
    const av=a.st.status==='running' ? Date.now()/1000 : (a.st.finished_at||0);
    const bv=b.st.status==='running' ? Date.now()/1000 : (b.st.finished_at||0);
    return av-bv;
  });
  const grid=document.getElementById('up-grid');
  grid.innerHTML=rows.map(({s,st})=>upCardHTML(s,st)).join('');
  rows.forEach(({s})=>{
    const card=grid.querySelector(`#up-card-${s.id}`);
    card.querySelector('.up-run').addEventListener('click',()=>upRun(s.id));
    const view=card.querySelector('.up-view'); if(view) view.addEventListener('click',()=>upViewReport(s.id));
  });
  upHelpSync();
  rows.forEach(({s,st})=>{ if(st.status==='running') upStartPoll(s.id); });
}

function upStatusPill(st){
  if(st.status==='running') return '<span class="up-status run">Running…</span>';
  if(st.status==='error'){
    // t-1776: surface the failure's own output as a tooltip — the whole
    // point of persisting it was so a failure is diagnosable from the
    // dashboard, not just by opening upkeepRuns.json by hand.
    const tip = st.output ? esc(st.output.slice(-2048)) : 'No output captured.';
    return `<span class="up-status err" title="${tip}">Error</span>`;
  }
  if(st.status==='idle' || !st.report_path) return '<span class="up-status never">Never run</span>';
  return '<span class="up-status ok">Done</span>';
}

function upCardHTML(s, st){
  const when=upFmtWhen(st.finished_at);
  const whenLine = st.status==='running' ? 'Running…' : (when ? 'Last run — '+esc(when) : 'Last run — never');
  const running = st.status==='running';
  const agentSel = `<select class="rc-select" title="Agent"${running?' disabled':''}>`
    + '<option>Claude</option><option disabled>Pi (soon)</option><option disabled>Copilot (soon)</option></select>';
  const modelSel = `<select class="rc-select" id="up-model-${s.id}" title="Model"${running?' disabled':''}>`
    + '<option value="claude-haiku-4-5-20251001" selected>Haiku 4.5</option><option value="claude-sonnet-5">Sonnet 5</option></select>';
  const runBtn = st.status==='idle' || !st.report_path
    ? `<button class="btn primary up-run"${running?' disabled':''}>&#9654; Run</button>`
    : `<button class="btn up-run"${running?' disabled':''}>&#8635; Run again</button>
         <button class="btn primary up-view">View report</button>`;
  return `<div class="rcard" id="up-card-${s.id}" data-help="${s.id}">
      <div class="rc-when mono">${esc(whenLine)}</div>
      <div class="rc-top">
        <div class="rc-icon">${s.icon}</div>
        <div class="rc-head"><div class="rc-title">${esc(s.title)}</div><p class="rc-desc">${esc(s.desc)}</p></div>
        ${upStatusPill(st)}${upHelpBtn(s.id)}
      </div>
      <div class="rc-config">${agentSel}${modelSel}${running?'<span class="rc-config-note">locked while running</span>':''}</div>
      <div class="rc-actions">${runBtn}</div>
    </div>`;
}

export const UPKEEP_MODEL_LABELS={'claude-haiku-4-5-20251001':'Haiku 4.5','claude-sonnet-5':'Sonnet 5'};

async function upRun(skill){
  const modelEl=document.getElementById('up-model-'+skill);
  const model=modelEl ? modelEl.value : 'claude-haiku-4-5-20251001';
  const modelLabel=UPKEEP_MODEL_LABELS[model]||model;
  const proj=getProjects().find(p=>p.id===upProjectId);
  const ok=await cockpitConfirm({
    title:'Run '+skill+'?',
    body:'This dispatches a real LLM call (Claude '+modelLabel+') against '+(proj?proj.name:'this project')+' and will incur API cost. Report-only — nothing is modified.',
    okLabel:'Run',
  });
  if(!ok) return;
  try{
    // The server resolves the project root from the URL's ?project= query
    // string (effective_root, t-8485 convention) — never from the JSON body.
    await fetch('/api/upkeep/run?project='+encodeURIComponent(upProjectId),{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({skill, model})});
  }catch(e){}
  await upRenderGrid();
  upStartPoll(skill);
}

function upStartPoll(skill){
  if(upPollTimers[skill]) return;
  upPollTimers[skill]=setInterval(async()=>{
    const st=await upFetchState(skill);
    if(st.status!=='running'){
      clearInterval(upPollTimers[skill]); delete upPollTimers[skill];
      await upRenderGrid();
    }
  },3000);
}

export function upToggleCollapse(){ document.getElementById('up-detail').classList.toggle('open'); }

// Minimal markdown-ish renderer scoped to Upkeep's own report shape (# / ##
// headers, `code` spans, - bullet lists) — not a general parser. List items
// under a "Findings" heading get the amber callout treatment; everything
// else is heading/paragraph/code only. Deliberately narrower than the board's
// md() (static/board-helpers.js) (which also handles checkboxes/gherkin/feature-refs for ticket docs —
// a different, larger job this view doesn't need).
function upRenderReport(raw){
  if(!raw) return '<div class="up-empty">Empty report.</div>';
  const lines=raw.split(/\r?\n/);
  let html=''; let inFindings=false; let inList=false; let inMeta=false; let skippedTitle=false;
  const closeList=()=>{ if(inList){ html+='</ul>'; inList=false; } };
  const closeMeta=()=>{ if(inMeta){ html+='</div>'; inMeta=false; } };
  const inline=t=>esc(t).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
  const isTableRow=l=>/^\s*\|.*\|\s*$/.test(l);
  const isTableSep=l=>/^\s*\|[\s|:-]+\|\s*$/.test(l);
  const splitRow=l=>l.trim().replace(/^\|/,'').replace(/\|$/,'').split('|').map(c=>c.trim());
  const statusCell=c=>{
    const m=c.match(/^(?:❌|✗|🔴)\s*(.*)/); // ✗, ❌, 🔴
    if(m) return `<span class="up-status-chip bad">${inline(m[1]||'Missing')}</span>`;
    const ok=c.match(/^(?:✅|✓|🟢)\s*(.*)/); // ✓, ✅, 🟢
    if(ok) return `<span class="up-status-chip ok">${inline(ok[1]||'OK')}</span>`;
    return inline(c);
  };
  for(let i=0;i<lines.length;i++){
    const line=lines[i];
    // The panel title is always the report's first non-blank line, heading
    // syntax or not (upViewReport takes it the same way) — skip it here
    // unconditionally or it renders a second time in the body.
    if(!skippedTitle){
      if(!line.trim()) continue;
      skippedTitle=true; continue;
    }
    const h3=line.match(/^###\s+(.*)/); const h2=line.match(/^##\s+(.*)/); const h1=line.match(/^#\s+(.*)/);
    const li=line.match(/^[-*]\s+(.*)/);
    const metaLine=line.match(/^\*\*([^*]+):\*\*\s*(.*)/);
    if(isTableRow(line) && isTableSep(lines[i+1]||'')){
      closeList(); closeMeta();
      const head=splitRow(line);
      let body=''; let j=i+2;
      // Tolerate blank lines between body rows (a common LLM-markdown quirk) —
      // only a real, non-blank, non-table line actually ends the table.
      for(;j<lines.length;j++){
        if(!lines[j].trim()) continue;
        if(!isTableRow(lines[j])) break;
        body+='<tr>'+splitRow(lines[j]).map(c=>`<td>${statusCell(c)}</td>`).join('')+'</tr>';
      }
      html+='<div class="up-table-wrap"><table><thead><tr>'+head.map(c=>`<th>${inline(c)}</th>`).join('')+'</tr></thead><tbody>'+body+'</tbody></table></div>';
      i=j-1; continue;
    }
    if(metaLine){
      if(!inMeta){ closeList(); html+='<div class="up-meta">'; inMeta=true; }
      html+=`<span class="um"><b>${inline(metaLine[1])}</b>${inline(metaLine[2])}</span>`; continue;
    }
    closeMeta();
    if(/^-{3,}\s*$/.test(line.trim())){ closeList(); html+='<hr>'; continue; }
    if(h1){ closeList(); inFindings=false; html+=`<h3>${inline(h1[1])}</h3>`; continue; }
    if(h2){ closeList(); inFindings=/findings/i.test(h2[1]); html+=`<h3>${inline(h2[1])}</h3>`; continue; }
    if(h3){ closeList(); html+=`<h4>${inline(h3[1])}</h4>`; continue; }
    if(li){
      if(!inList){ html+=`<ul class="${inFindings?'up-findings':''}">`; inList=true; }
      html+=`<li>${inline(li[1])}</li>`; continue;
    }
    closeList();
    if(line.trim()) html+=`<p>${inline(line)}</p>`;
  }
  closeList(); closeMeta();
  return html;
}

async function upViewReport(skill){
  const meta=UPKEEP_SKILLS.find(s=>s.id===skill);
  document.getElementById('up-rp-eyebrow').textContent='Report · '+skill;
  document.getElementById('up-rp-title').textContent='Loading…';
  document.getElementById('up-rp-when').textContent='';
  document.getElementById('up-rp-body').innerHTML='<div class="up-empty">Loading…</div>';
  document.getElementById('up-detail').classList.add('open');
  let data={ok:false};
  try{
    const r=await fetch('/api/upkeep/report?project='+encodeURIComponent(upProjectId)+'&skill='+encodeURIComponent(skill));
    data=await r.json();
  }catch(e){}
  const st=await upFetchState(skill);
  document.getElementById('up-rp-when').textContent=upFmtWhen(st.finished_at)||'';
  if(!data.ok){
    document.getElementById('up-rp-title').textContent='No report yet';
    document.getElementById('up-rp-body').innerHTML='<div class="up-empty">'+esc(data.error||'No report yet.')+'</div>';
    return;
  }
  const firstLine=(data.content.split(/\r?\n/).find(l=>l.trim())||meta.title).replace(/^#+\s*/,'');
  document.getElementById('up-rp-title').textContent=firstLine;
  document.getElementById('up-rp-body').innerHTML=upRenderReport(data.content);
}
// t-565f: upkeep's load-time code, run once at the end (the module version keeps it in initUpkeep()).
export function initUpkeep(){
document.addEventListener('keydown',e=>{ if(e.key==='Escape'&&upHelpOpen) upHelpClose(true); });
document.addEventListener('click',e=>{ if(upHelpOpen&&!e.target.closest('.rc-pop,.rc-help')) upHelpClose(false); });
document.addEventListener('scroll',e=>{ if(e.target.classList&&e.target.classList.contains('rc-pop-body')) upHelpScroll=e.target.scrollTop; },true);
window.addEventListener('resize',()=>{ if(upHelpOpen) upHelpClose(false); });   // placement is computed once, so a resize closes it
document.getElementById('up-back').addEventListener('click',()=>{ setUpkeepPane(null); if(upProjectId) activateTab(upProjectId); else applySplit(); });
}
