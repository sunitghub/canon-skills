---
marp: true
theme: octave
paginate: true
html: true
---

<!-- _class: title -->

<div style="display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0; gap:24px;">
<div style="display:flex; flex-direction:column; gap:16px;">
<div style="font-size:3.1em; font-weight:900; line-height:1.05; color:#FFFFFF; letter-spacing:-0.02em;">Can an agent prove<br/>its code is right?</div>
<div style="width:100px; height:4px; background:linear-gradient(90deg,#00FFFF,#4FFF00); border-radius:2px;"></div>
<div style="font-size:1.15em; color:#00FFFF; line-height:1.45;">A four-minute demo of executable business rules</div>
</div>
</div>
<img src="./octave-logo.png" style="position:absolute; top:36px; left:72px; height:42px; width:auto;" alt="Octave"/>

---

## The problem: plausible code is not proven code

<img src="./octave-logo.png" style="position:absolute; top:24px; right:48px; height:28px; width:auto;" alt="Octave"/>

<div style="display:grid; grid-template-columns:1fr 1fr; flex:1; min-height:0; gap:18px; align-items:stretch;">
<div style="display:flex; flex-direction:column; border:1px solid rgba(255,0,199,.45); border-radius:10px; overflow:hidden; min-height:0;">
<div style="padding:12px 16px; background:rgba(255,0,199,.14); color:#FF00C7; font-size:.72em; font-weight:800; text-transform:uppercase; letter-spacing:.08em;">The usual workflow</div>
<div style="flex:1; padding:18px; background:rgba(62,64,71,.28); font-size:.82em; line-height:1.55;">An agent writes a function.<br/><br/>A person reads the diff.<br/><br/>Everyone says it looks reasonable.</div>
</div>
<div style="display:flex; flex-direction:column; border:1px solid rgba(0,255,255,.45); border-radius:10px; overflow:hidden; min-height:0;">
<div style="padding:12px 16px; background:rgba(0,255,255,.14); color:#00FFFF; font-size:.72em; font-weight:800; text-transform:uppercase; letter-spacing:.08em;">The executable-spec workflow</div>
<div style="flex:1; padding:18px; background:rgba(62,64,71,.28); font-size:.82em; line-height:1.55;">A business rule is written first.<br/><br/>The agent builds against it.<br/><br/>A runner returns a boolean: pass or fail.</div>
</div>
</div>
<div style="padding:11px 16px; margin-top:12px; background:rgba(62,64,71,.3); border-left:3px solid #4FFF00; border-radius:0 8px 8px 0; font-size:.78em; color:#B2B8C4;"><strong style="color:#4FFF00;">The shift:</strong> the spec is not commentary about the code. It is the check that can disagree with the code.</div>

---

## The demo: a pricing policy the machine can run

<img src="./octave-logo.png" style="position:absolute; top:24px; right:48px; height:28px; width:auto;" alt="Octave"/>

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:12px;">
<div style="display:flex; flex-direction:column; justify-content:space-evenly; flex:1; min-height:0; gap:10px;">
<div style="padding:12px 16px; background:rgba(62,64,71,.35); border-left:4px solid #00FFFF; border-radius:8px; font-size:.78em; line-height:1.45;"><strong style="color:#00FFFF;">1. Read the contract.</strong> <code>SAVE10</code> means 10% off above $50. <code>SAVE20</code> means 20% off above $100. Unknown codes are rejected.</div>
<div style="padding:12px 16px; background:rgba(62,64,71,.35); border-left:4px solid #4FFF00; border-radius:8px; font-size:.78em; line-height:1.45;"><strong style="color:#4FFF00;">2. Run it.</strong> <code>python dsl_runner.py specs/discount.feature</code> returns three <strong>[PASS]</strong> lines.</div>
<div style="padding:12px 16px; background:rgba(62,64,71,.35); border-left:4px solid #FF00C7; border-radius:8px; font-size:.78em; line-height:1.45;"><strong style="color:#FF00C7;">3. Break the code.</strong> Remove the minimum-cart check and run again. The below-minimum scenario fails with the exact actual-versus-expected mismatch.</div>
</div>
<div style="padding:11px 16px; background:rgba(62,64,71,.3); border-left:3px solid #FFF500; border-radius:0 8px 8px 0; font-size:.76em; color:#B2B8C4;"><strong style="color:#FFF500;">Live moment:</strong> nobody needs to spot the regression in the diff. The pre-written rule catches it.</div>
</div>

---

## The point: readable rules, executable proof

<img src="./octave-logo.png" style="position:absolute; top:24px; right:48px; height:28px; width:auto;" alt="Octave"/>

<div style="display:flex; flex-direction:column; justify-content:space-evenly; flex:1; min-height:0; gap:14px;">
<div style="display:flex; gap:18px; align-items:center; padding:15px 20px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #00FFFF;"><div style="font-size:1.5em; font-weight:800; color:#00FFFF; min-width:30px;">1</div><div style="font-size:.82em; line-height:1.45;"><strong>The owner can read it.</strong> Pricing policy is expressed as business language, not Python assertions.</div></div>
<div style="display:flex; gap:18px; align-items:center; padding:15px 20px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #4FFF00;"><div style="font-size:1.5em; font-weight:800; color:#4FFF00; min-width:30px;">2</div><div style="font-size:.82em; line-height:1.45;"><strong>The machine can run it.</strong> A bounded runner turns Given/When/Then into a pass/fail answer.</div></div>
<div style="display:flex; gap:18px; align-items:center; padding:15px 20px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #FF00C7;"><div style="font-size:1.5em; font-weight:800; color:#FF00C7; min-width:30px;">3</div><div style="font-size:.82em; line-height:1.45;"><strong>The check can catch the builder.</strong> When implementation and intent diverge, the spec—not the agent—gets the final word.</div></div>
</div>
<div style="padding:12px 16px; background:rgba(0,255,255,.08); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:.82em; color:#B2B8C4;"><strong style="color:#00FFFF;">Write the rule first. Run the rule. Then trust the code only when the rule agrees.</strong></div>
