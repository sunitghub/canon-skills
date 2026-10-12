// t-565f: the Cockpit shell's views code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initViews(), which cockpit-main.js runs in order once every module has loaded.
import { loadUpkeep } from './cockpit-upkeep.js';
import { loadAdmin } from './cockpit-admin.js';
import { activateTab, activeTab, applySplit, setUpkeepPane, splitShown } from './cockpit-tabs.js';

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
  const inSplit=v==='upkeep'&&splitShown();   // t-bcce: with a split on screen, Upkeep opens inside its project's pane and the split stays
  if(inSplit) setUpkeepPane(activeTab);   // every other path clears it in applySplit
  if(!inSplit){
    document.querySelectorAll('.view').forEach(x=>x.classList.remove('active'));
    document.getElementById('nav-projects').classList.remove('active');
    document.getElementById('nav-admin').classList.toggle('active',v==='admin');
  }
  if(v==='admin'){
    document.getElementById('view-admin').classList.add('active');
    loadAdmin();
  } else if(v==='upkeep'){
    if(!inSplit) document.getElementById('view-upkeep').classList.add('active');
    loadUpkeep();
  }
  applySplit();   // t-416c: Admin shows full size and suspends the split
}
// t-565f: views's load-time code, run once at the end (the module version keeps it in initViews()).
export function initViews(){

document.addEventListener('DOMContentLoaded',()=>{
  document.getElementById('nav-projects').addEventListener('click',()=>showView('projects'));
  document.getElementById('nav-admin').addEventListener('click',()=>showView('admin'));
});
}
