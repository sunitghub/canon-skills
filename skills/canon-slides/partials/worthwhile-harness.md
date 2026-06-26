## What a worthwhile harness does

<div style="display:grid; grid-template-rows:auto 1fr auto; flex:1; min-height:0; gap:8px;">
<div style="padding:9px 18px; background:rgba(62,64,71,0.25); border-radius:8px; font-size:0.75em; color:#B2B8C4; line-height:1.45; text-align:center;">Most tools add <em>suggestions</em>. A harness earns its place only if it makes certain failures <strong style="color:#FFFFFF;">structurally&nbsp;impossible</strong> — not just unlikely.</div>
<div style="display:flex; align-items:stretch; gap:0; min-height:0;">
<div class="step s1" style="flex:1; display:flex; flex-direction:column; justify-content:center; gap:8px; padding:14px 16px; background:rgba(0,255,255,0.07); border-radius:10px; border:1px solid rgba(0,255,255,0.25);">
<div style="font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#00FFFF; font-weight:600;">Wrapup pipeline · advisory</div>
<div style="font-size:0.78em; font-weight:700; color:#FFFFFF; line-height:1.3;">Gates run, findings surface</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4; margin-top:2px;">Reviewer, security, doc-audit each record <code>ran</code> or <code>skipped</code> — no <code>fail</code> status exists. A <strong style="color:#F46600;">NO</strong> finding goes in the Reason column and surfaces to you. Pipeline continues.</div>
</div>
<div style="display:flex; align-items:center; padding:0 8px; flex-shrink:0;">
<svg width="22" height="22" viewBox="0 0 22 22"><path d="M3 11 L17 11 M12 6 L17 11 L12 16" stroke="#4FFF00" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
</div>
<div class="step s2" style="flex:1; display:flex; flex-direction:column; justify-content:center; gap:8px; padding:14px 16px; background:rgba(244,102,0,0.07); border-radius:10px; border:1px solid rgba(244,102,0,0.25);">
<div style="font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#F46600; font-weight:600;">Mechanical gate</div>
<div style="font-size:0.78em; font-weight:700; color:#FFFFFF; line-height:1.3;">CLI <em>refuses</em> to close</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4; margin-top:2px;">Acceptance unchecked? <code>summary.md</code> missing? Wrapup Gates section absent? <code>eval-report</code> not <code>pass:</code>? Blocked — not warned.</div>
</div>
<div style="display:flex; align-items:center; padding:0 8px; flex-shrink:0;">
<svg width="22" height="22" viewBox="0 0 22 22"><path d="M3 11 L17 11 M12 6 L17 11 L12 16" stroke="#FFF500" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
</div>
<div class="step s3" style="flex:1; display:flex; flex-direction:column; justify-content:center; gap:8px; padding:14px 16px; background:rgba(79,255,0,0.07); border-radius:10px; border:1px solid rgba(79,255,0,0.25);">
<div style="font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#4FFF00; font-weight:600;">Evaluator subagent</div>
<div style="font-size:0.78em; font-weight:700; color:#FFFFFF; line-height:1.3;">Binding close check</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4; margin-top:2px;">Fresh context, no implementation history. Each criterion: <code>pass</code>/<code>fail</code> + <code>file:line</code> cite. <code>fail</code> blocks. Self-review is not review.</div>
</div>
<div style="display:flex; align-items:center; padding:0 8px; flex-shrink:0;">
<svg width="22" height="22" viewBox="0 0 22 22"><path d="M3 11 L17 11 M12 6 L17 11 L12 16" stroke="#4FFF00" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
</div>
<div class="step s4" style="flex:0.7; display:flex; flex-direction:column; justify-content:center; align-items:center; gap:8px; padding:14px 12px; background:rgba(79,255,0,0.1); border-radius:10px; border:2px solid #4FFF00;">
<div style="font-size:1.8em; font-weight:900; color:#4FFF00; line-height:1;">✓</div>
<div style="font-size:0.72em; font-weight:700; color:#4FFF00; text-align:center; line-height:1.3;">Sprint<br>closed</div>
</div>
</div>
<div style="padding:9px 14px; background:rgba(62,64,71,0.3); border-left:3px solid #F46600; border-radius:0 8px 8px 0; font-size:0.74em; color:#B2B8C4;">"<em>What if wrapup finds something bad?</em>" — it records it and you see it, but the pipeline continues. There is no <code>fail</code> status in wrapup. The only hard stops are the <strong style="color:#F46600;">CLI</strong> (missing files or sections) and the <strong style="color:#4FFF00;">evaluator</strong> (<code>fail:</code> verdict).</div>
</div>
