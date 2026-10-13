// t-565f: the Cockpit shell's core code (was part of cockpit.html's one script). Declarations only: the
// load-time code is initCore(), which cockpit-main.js runs in order once every module has loaded.
import { hideCloseWarn } from './cockpit-sessions.js';
import { toggleKeysSheet } from './cockpit-keys.js';
import { closeTabMenu } from './cockpit-tabs.js';

// t-d2e1: esc() escapes quotes too (text-node serialization alone does not), so its output is safe in text AND in a
// quoted attribute; attribute sinks that used esc() instead of escAttr could be broken out of. escAttr is the same now.
export function esc(s){const d=document.createElement('div');d.textContent=s==null?'':String(s);return d.innerHTML.replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
export function escAttr(s){return esc(s);}
export function toast(msg){const t=document.getElementById('toast');t.textContent=msg;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2600);}

// ── Reusable canon-styled confirm (t-5849) ─────────────────────────────────
// Replaces native confirm()/prompt(). Returns a Promise<bool> (true=OK).
// opts: {title, body, okLabel, cancelLabel, danger, okOnly, code, focusCancel}.
let _ccResolve=null;
function _ccClose(val){
  const s=document.getElementById('cconfirm');
  if(!s.classList.contains('show')) return;
  s.classList.remove('show');
  document.removeEventListener('keydown',_ccKey,true);
  const r=_ccResolve; _ccResolve=null;
  if(r) r(val);
}
function _ccKey(e){
  if(!document.getElementById('cconfirm').classList.contains('show')) return;
  if(e.key==='Escape'){ e.stopPropagation(); _ccClose(false); }
  // t-3c9a: Enter presses the focused button, so a dialog that opens on Cancel (Kill) isn't one keystroke from OK.
  else if(e.key==='Enter'){ e.stopPropagation(); _ccClose(document.activeElement!==document.getElementById('cc-cancel')); }
}
export function cockpitConfirm(opts){
  opts=opts||{};
  if(_ccResolve){ const prev=_ccResolve; _ccResolve=null; prev(false); }  // resolve any orphaned prior confirm
  const s=document.getElementById('cconfirm');
  document.getElementById('cc-title').textContent=opts.title||'Are you sure?';
  document.getElementById('cc-body').textContent=opts.body||'';
  const ok=document.getElementById('cc-ok'), cancel=document.getElementById('cc-cancel');
  ok.textContent=opts.okLabel||'OK';
  ok.className='btn '+(opts.danger?'danger':'primary');
  cancel.textContent=opts.cancelLabel||'Cancel';
  cancel.style.display=opts.okOnly?'none':'';
  // optional read-only copyable command field (replaces the old prompt())
  const wrap=document.getElementById('cc-code-wrap'), code=document.getElementById('cc-code');
  if(opts.code){ code.value=opts.code; wrap.style.display=''; } else { code.value=''; wrap.style.display='none'; }
  s.classList.add('show');
  (opts.focusCancel&&!opts.okOnly?cancel:ok).focus();
  document.addEventListener('keydown',_ccKey,true);
  return new Promise(res=>{ _ccResolve=res; });
}

// ── Help/tour overlay (t-c5e7) ────────────────────────────────────────────
let _helpVersionsLoaded=false;
export let _helpVersionsDone=Promise.resolve();   // settles when the Versions fetches have been applied (the specs await it before asserting an "unchanged" row)
export function openHelp(){
  document.getElementById('help-overlay').classList.add('open');
  if(!_helpVersionsLoaded){ _helpVersionsLoaded=true; _helpVersionsDone=loadHelpVersions(); }
}
function closeHelp(){ document.getElementById('help-overlay').classList.remove('open'); }
async function loadHelpVersions(){
  // Only stay "loaded" once /api/version arrived (it fills the canon row; /api/cockpit can fill the daemon row alone): a fetch that failed (the board restarting) must retry on the next open.
  setTimeout(()=>{ if(document.getElementById('hv-canon').textContent.trim()==='\u2014') _helpVersionsLoaded=false; },4000);
  try{ const v=await (await fetch('/api/version')).json();
    if(v&&v.version) document.getElementById('hv-canon').textContent='v'+v.version;
    if(v&&v.commit) document.getElementById('hv-board').textContent=v.commit;
    if(v&&v.daemon) document.getElementById('hv-daemon').textContent=v.daemon;
  }catch(e){}
  // daemon build (best-effort) from /api/cockpit running_build
  try{ const ck=await (await fetch('/api/cockpit')).json();
    const rb=ck&&ck.running_build;
    if(rb&&rb.version){
      // t-4487: show the same string `cockpit-daemon --version` prints. A running build without a commit (an older daemon) must not
      // wipe a stamped string /api/version already filled in; it only fills an empty row.
      const el=document.getElementById('hv-daemon');
      if(rb.commit&&rb.commit!=='dev') el.textContent=rb.version+' ('+rb.commit+')';   // a dev build prints bare, as --version does
      else if(el.textContent.trim()==='\u2014') el.textContent=rb.version;
    }
  }catch(e){}
}
// t-565f: core's load-time code, run once at the end (the module version keeps it in initCore()).
export function initCore(){
document.addEventListener('DOMContentLoaded',()=>{
  document.getElementById('cc-ok').addEventListener('click',()=>_ccClose(true));
  document.getElementById('cc-cancel').addEventListener('click',()=>_ccClose(false));
  document.getElementById('cconfirm').addEventListener('click',e=>{ if(e.target.id==='cconfirm') _ccClose(false); });
  const copyBtn=document.getElementById('cc-copy');
  if(copyBtn) copyBtn.addEventListener('click',()=>{
    const v=document.getElementById('cc-code').value;
    try{ navigator.clipboard.writeText(v); toast('Copied'); }
    catch(e){ const i=document.getElementById('cc-code'); i.focus(); i.select(); }
  });
});
document.addEventListener('DOMContentLoaded',()=>{
  const hc=document.getElementById('help-close'); if(hc) hc.addEventListener('click',closeHelp);
  document.getElementById('help-btn').addEventListener('click',()=>openHelp());
  const ov=document.getElementById('help-overlay');
  if(ov) ov.addEventListener('click',e=>{ if(e.target===ov) closeHelp(); });
});
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){
    const cw=document.getElementById('closeWarn');
    if(cw&&cw.classList.contains('show')){ hideCloseWarn(); return; }
    const ov=document.getElementById('help-overlay'); if(ov&&ov.classList.contains('open')){ closeHelp(); }
    const ks=document.getElementById('keys-sheet'); if(ks&&ks.classList.contains('show')){ toggleKeysSheet(false); }
    closeTabMenu();
  }
});
}
