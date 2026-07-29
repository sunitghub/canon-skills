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
<div style="padding:12px 16px; background:rgba(62,64,71,.35); border-left:4px solid #4FFF00; border-radius:8px; font-size:.78em; line-height:1.45;"><strong style="color:#4FFF00;">2. Build it, then run it.</strong> A one-page <strong>Discount Apply</strong> app &mdash; Amount, Code, Message, Discounted Amount &mdash; with the rule in <code>app.js</code>. <code>node dsl_runner.js specs/discount.feature</code> returns three <strong>[PASS]</strong>, and the app shows <strong>$96.00</strong> for SAVE20 on a $120 cart.</div>
<div style="padding:12px 16px; background:rgba(62,64,71,.35); border-left:4px solid #FF00C7; border-radius:8px; font-size:.78em; line-height:1.45;"><strong style="color:#FF00C7;">3. Break the code.</strong> Delete the minimum-cart check and run again. The below-minimum scenario fails with the exact actual-versus-expected mismatch &mdash; and the app now wrongly discounts a $40 cart.</div>
</div>
<div style="padding:11px 16px; background:rgba(62,64,71,.3); border-left:3px solid #FFF500; border-radius:0 8px 8px 0; font-size:.76em; color:#B2B8C4;"><strong style="color:#FFF500;">Live moment:</strong> nobody needs to spot the regression in the diff. The pre-written rule catches it.</div>
</div>

---

## Who owns &ldquo;correct&rdquo;? The store owner does

<img src="./octave-logo.png" style="position:absolute; top:24px; right:48px; height:28px; width:auto;" alt="Octave"/>

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:12px;">
<div style="display:flex; align-items:stretch; min-height:0; gap:22px;">
<div style="flex:1.4; display:flex; flex-direction:column; justify-content:space-evenly; gap:9px; min-height:0;">
<div style="font-size:.78em; line-height:1.4; color:#B2B8C4;">Meet <strong style="color:#FFFFFF;">Maya</strong>, who runs the store. She owns the promo rules &mdash; and she can&rsquo;t read JavaScript, nor does she need to.</div>
<div style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #00FFFF;"><div style="font-size:1.3em; font-weight:800; color:#00FFFF; min-width:22px; flex-shrink:0;">1</div><div style="font-size:.76em; line-height:1.4;"><strong>The contract sits outside the agent&rsquo;s opinion.</strong> The scenarios are a readable, executable behavior contract that grades what the agent built &mdash; not the agent grading its own work.</div></div>
<div style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #4FFF00;"><div style="font-size:1.3em; font-weight:800; color:#4FFF00; min-width:22px; flex-shrink:0;">2</div><div style="font-size:.76em; line-height:1.4;"><strong>Maya defines and approves &ldquo;correct.&rdquo;</strong> <em>SAVE20 = 20% off above $100.</em> The agent implements it; the executable scenario checks the result. She stays in the loop without writing code.</div></div>
<div style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #FF00C7;"><div style="font-size:1.3em; font-weight:800; color:#FF00C7; min-width:22px; flex-shrink:0;">3</div><div style="font-size:.76em; line-height:1.4;"><strong>A mismatch triggers human review</strong> &mdash; not autonomous release.</div></div>
</div>
<div style="flex:1; display:flex; flex-direction:column; align-items:center; justify-content:center; min-height:0; gap:8px;">
<img src="./images/app-applied.png" style="max-width:100%; max-height:340px; height:auto; border-radius:10px; border:1px solid rgba(0,255,255,.3);" alt="Discount Apply app showing SAVE20 on a $120 cart resolving to $96.00"/>
<div style="font-size:.68em; color:#00FFFF; text-align:center; line-height:1.35;">The feature Maya approved, running: <strong>SAVE20</strong> on $120 &rarr; <strong>$96.00</strong>.</div>
</div>
</div>
<div style="padding:11px 16px; background:rgba(62,64,71,.3); border-left:3px solid #FFF500; border-radius:0 8px 8px 0; font-size:.74em; color:#B2B8C4;"><strong style="color:#FFF500;">What a failure means:</strong> a failed scenario doesn&rsquo;t claim the equipment physically failed &mdash; it says the digital record and its executable behavior no longer agree, so the record should not quietly move downstream.</div>
</div>

---

## The point: readable rules, executable proof

<img src="./octave-logo.png" style="position:absolute; top:24px; right:48px; height:28px; width:auto;" alt="Octave"/>

<div style="display:flex; flex-direction:column; justify-content:space-evenly; flex:1; min-height:0; gap:14px;">
<div style="display:flex; gap:18px; align-items:center; padding:15px 20px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #00FFFF;"><div style="font-size:1.5em; font-weight:800; color:#00FFFF; min-width:30px;">1</div><div style="font-size:.82em; line-height:1.45;"><strong>The owner can read it.</strong> Pricing policy is expressed as business language, not code assertions.</div></div>
<div style="display:flex; gap:18px; align-items:center; padding:15px 20px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #4FFF00;"><div style="font-size:1.5em; font-weight:800; color:#4FFF00; min-width:30px;">2</div><div style="font-size:.82em; line-height:1.45;"><strong>The machine can run it.</strong> A bounded runner turns Given/When/Then into a pass/fail answer.</div></div>
<div style="display:flex; gap:18px; align-items:center; padding:15px 20px; background:rgba(62,64,71,.35); border-radius:10px; border-left:4px solid #FF00C7;"><div style="font-size:1.5em; font-weight:800; color:#FF00C7; min-width:30px;">3</div><div style="font-size:.82em; line-height:1.45;"><strong>The check can catch the builder.</strong> When implementation and intent diverge, the spec—not the agent—gets the final word.</div></div>
</div>
<div style="padding:12px 16px; background:rgba(0,255,255,.08); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:.8em; color:#B2B8C4;"><strong style="color:#00FFFF;">The gap between &ldquo;looks right&rdquo; and &ldquo;is right&rdquo; is where trust breaks down.</strong> This is the agentic layer worth wanting in AI &ldquo;vibe coding&rdquo;: the agent generates the implementation, but a readable behavior contract stays outside its opinion and grades the result.</div>
