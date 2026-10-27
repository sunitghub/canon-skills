// t-565f: the Cockpit shell's views code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initViews(), which cockpit-main.js runs in order once every module has loaded.
import { loadSkillEval } from './cockpit-skill-eval.js';
import { loadAdmin } from './cockpit-admin.js';
import { loadFactory } from './cockpit-factory.js';
import { renderSessionSurfaces } from './cockpit-sessions.js';
import { activateTab, activeTab, applySplit, setSkillEvalPane, splitShown } from './cockpit-tabs.js';

export function showView(v){
  if(v==='projects'){
    // Explicit click on the sidebar's Projects nav must always land on the
    // grid, even when a per-project tab (e.g. an open "ToDo" tab) is
    // currently active — previously this re-activated whatever tab was
    // already showing, a no-op that looked like the click did nothing.
    // activateTab manages view/nav state itself (incl. clearing nav-admin).
    activateTab('projects');
    return;
  }
  const inSplit=v==='skill-eval'&&splitShown();   // t-bcce: with a split on screen, Skill Eval opens inside its project's pane and the split stays
  if(inSplit) setSkillEvalPane(activeTab);   // every other path clears it in applySplit
  if(!inSplit){
    document.querySelectorAll('.view').forEach(x=>x.classList.remove('active'));
    document.getElementById('nav-projects').classList.remove('active');
    document.getElementById('nav-admin').classList.toggle('active',v==='admin');
    document.getElementById('nav-factory').classList.toggle('active',v==='factory');
  }
  renderSessionSurfaces();   // t-7456: Admin and Factory have no agent in view
  if(v==='admin'){
    document.getElementById('view-admin').classList.add('active');
    loadAdmin();
  } else if(v==='factory'){   // t-9641: per-project GitHub setup, full size like Admin
    document.getElementById('view-factory').classList.add('active');
    loadFactory();
  } else if(v==='skill-eval'){
    if(!inSplit) document.getElementById('view-skill-eval').classList.add('active');
    loadSkillEval();
  }
  applySplit();   // t-416c: Admin (and Factory, t-9641) shows full size and suspends the split
}
// t-565f: views's load-time code, run once at the end (the module version keeps it in initViews()).
export function initViews(){

document.addEventListener('DOMContentLoaded',()=>{
  document.getElementById('nav-projects').addEventListener('click',()=>showView('projects'));
  document.getElementById('nav-factory').addEventListener('click',()=>showView('factory'));
  document.getElementById('nav-admin').addEventListener('click',()=>showView('admin'));
});
}
