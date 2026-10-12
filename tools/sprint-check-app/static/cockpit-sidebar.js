// t-565f: the Cockpit shell's sidebar code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initSidebar(), which cockpit-main.js runs in order once every module has loaded.
import { confirmCloseTab, hideCloseWarn } from './cockpit-sessions.js';

// ── Resizable sidebar (t-28ec) ─────────────────────────────────────────────
const LS_SIDE='canon-cockpit-side-w', SIDE_DEFAULT=230, SIDE_MIN=200, SIDE_MAX=420;
export function setSideWidth(w, save){
  w=Math.round(Math.min(SIDE_MAX, Math.max(SIDE_MIN, w)));
  document.documentElement.style.setProperty('--side-w', w+'px');
  const h=document.getElementById('side-resize');
  if(h) h.setAttribute('aria-valuenow', w);
  if(save){ try{ localStorage.setItem(LS_SIDE, String(w)); }catch(e){} }
}
function initSideResize(){
  let saved=NaN; try{ saved=parseInt(localStorage.getItem(LS_SIDE),10); }catch(e){}
  setSideWidth(isNaN(saved) ? SIDE_DEFAULT : saved, false);
  const h=document.getElementById('side-resize');
  if(!h) return;
  h.addEventListener('pointerdown', e=>{
    e.preventDefault();
    const left=h.parentElement.getBoundingClientRect().left;
    h.setPointerCapture(e.pointerId); h.classList.add('drag'); document.body.classList.add('resizing');
    const move=ev=>setSideWidth(ev.clientX-left, false);
    const up=ev=>{
      h.removeEventListener('pointermove', move); h.removeEventListener('pointerup', up);
      h.classList.remove('drag'); document.body.classList.remove('resizing');
      setSideWidth(ev.clientX-left, true);
    };
    h.addEventListener('pointermove', move); h.addEventListener('pointerup', up);
  });
  h.addEventListener('dblclick', ()=>setSideWidth(SIDE_DEFAULT, true));
  h.addEventListener('keydown', e=>{
    const cur=parseInt(h.getAttribute('aria-valuenow'),10)||SIDE_DEFAULT;
    if(e.key==='ArrowLeft' || e.key==='ArrowRight'){ e.preventDefault(); setSideWidth(cur+(e.key==='ArrowRight'?10:-10), true); }
    else if(e.key==='Home'){ e.preventDefault(); setSideWidth(SIDE_DEFAULT, true); }
  });
}

// ── Collapsible sidebar (t-4077) ───────────────────────────────────────────
const LS_SIDE_OFF='canon-cockpit-side-collapsed';
function setSideCollapsed(on, save){
  document.documentElement.classList.toggle('side-collapsed', on);
  const b=document.getElementById('side-collapse');
  b.setAttribute('aria-expanded', String(!on));
  b.setAttribute('aria-label', on ? 'Expand sidebar' : 'Collapse sidebar');
  b.title=(on ? 'Expand sidebar' : 'Collapse sidebar')+' (ctrl+. then w)';
  if(save){ try{ localStorage.setItem(LS_SIDE_OFF, on ? '1' : '0'); }catch(e){} }
}
export function toggleSide(){ setSideCollapsed(!document.documentElement.classList.contains('side-collapsed'), true); }
// t-565f: sidebar's load-time code, run once at the end (the module version keeps it in initSidebar()).
export function initSidebar(){
initSideResize();
(function initSideCollapse(){
  let off=false; try{ off=localStorage.getItem(LS_SIDE_OFF)==='1'; }catch(e){}
  setSideCollapsed(off, false);
  document.getElementById('side-collapse').addEventListener('click', toggleSide);
})();
document.addEventListener('DOMContentLoaded',()=>{
  document.getElementById('cw-keep').addEventListener('click',()=>hideCloseWarn());
  document.getElementById('cw-end').addEventListener('click',()=>confirmCloseTab(false));
  document.getElementById('cw-save').addEventListener('click',()=>confirmCloseTab(true));
});
}
