## What a worthwhile harness does

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:8px;">
<div style="display:flex; flex-direction:column; gap:8px; min-height:0;">
<div style="padding:10px 18px; background:rgba(62,64,71,0.25); border-radius:8px; font-size:0.76em; color:#B2B8C4; line-height:1.5; text-align:center;">Most tools add <em>suggestions</em>. A harness earns its place only if it makes certain failures <strong style="color:#FFFFFF;">structurally&nbsp;impossible</strong> — not just unlikely.</div>
<div class="card c1" style="display:flex; gap:16px; align-items:flex-start; padding:12px 16px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #00FFFF; flex:1;">
<div style="font-size:1.4em; font-weight:900; color:#00FFFF; min-width:24px; flex-shrink:0; line-height:1;">1</div>
<div>
<div style="font-size:0.80em; font-weight:700; color:#00FFFF; margin-bottom:3px;">Adversarial close review</div>
<div style="font-size:0.72em; color:#B2B8C4; line-height:1.45;">A <em>fresh</em> agent — with no implementation context — checks actual code against <code>acceptance.md</code>. Each criterion gets a pass/fail with a <code>file:line</code> citation. A fail blocks close. Self-review is not review.</div>
</div>
</div>
<div class="card c2" style="display:flex; gap:16px; align-items:flex-start; padding:12px 16px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #4FFF00; flex:1;">
<div style="font-size:1.4em; font-weight:900; color:#4FFF00; min-width:24px; flex-shrink:0; line-height:1;">2</div>
<div>
<div style="font-size:0.80em; font-weight:700; color:#4FFF00; margin-bottom:3px;">Delivery receipt</div>
<div style="font-size:0.72em; color:#B2B8C4; line-height:1.45;">At close, the agent writes a plan-vs-actual table: what was planned, what shipped, what was waived or deferred. Not a commit message — a permanent, queryable record. The board surfaces it on the Summary tab.</div>
</div>
</div>
<div class="card c3" style="display:flex; gap:16px; align-items:flex-start; padding:12px 16px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #FFF500; flex:1;">
<div style="font-size:1.4em; font-weight:900; color:#FFF500; min-width:24px; flex-shrink:0; line-height:1;">3</div>
<div>
<div style="font-size:0.80em; font-weight:700; color:#FFF500; margin-bottom:3px;">Mechanical close gate</div>
<div style="font-size:0.72em; color:#B2B8C4; line-height:1.45;">The CLI <em>refuses</em> to close while acceptance items are unchecked, <code>summary.md</code> is missing, or wrapup gates are absent. Gates don't remind — they block. Certain failures become impossible.</div>
</div>
</div>
</div>
<div style="padding:9px 14px; background:rgba(62,64,71,0.3); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:0.74em; color:#B2B8C4; font-style:italic;">The CLI enforces state and close gates; the agent and evaluator judge whether the work is actually good.</div>
</div>
