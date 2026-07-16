---
marp: true
theme: octave
paginate: true
html: true
---

<style>
@keyframes fadeUp {
  from { opacity: 0; transform: translateY(16px); }
  to   { opacity: 1; transform: translateY(0); }
}
.card { animation: fadeUp 0.35s both; }
.c1 { animation-delay: 0.05s; } .c2 { animation-delay: 0.22s; }
.c3 { animation-delay: 0.39s; } .c4 { animation-delay: 0.56s; }
.c5 { animation-delay: 0.73s; }
</style>

<div style="display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0; gap:24px;">
<div style="display:flex; flex-direction:column; gap:16px;">
<div style="font-size:3.2em; font-weight:900; line-height:1.1; color:#FFFFFF; letter-spacing:-0.02em;">Why every skill needs an evals folder</div>
<div style="width:72px; height:4px; background:linear-gradient(90deg,#00FFFF,#4FFF00); border-radius:2px;"></div>
<div style="font-size:1.15em; color:#00FFFF; font-weight:400; line-height:1.5;">A real walkthrough with a tiny skill, <code>slugify</code> — two bugs, two different catches.</div>
</div>
</div>

---

## The premise, pressure-tested

<div style="display:flex; flex-direction:column; flex:1; min-height:0; gap:14px;">
<div class="card c1" style="padding:16px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #00FFFF; font-size:0.85em; line-height:1.5;">
<strong>Fair pushback:</strong> "couldn't you just keep tweaking the skill until it works?" Yes — once, in one session, by the person paying close attention.
</div>
<div class="card c2" style="padding:16px 20px; background:rgba(244,102,0,0.1); border-radius:10px; border-left:4px solid #F46600; font-size:0.85em; line-height:1.5;">
<strong>Regression protection isn't free without a fixed test set.</strong> You only re-check what you remember to re-check. Six months from now, someone edits this skill and has no way to know the café case or the apostrophe case ever existed.
</div>
<div class="card c3" style="padding:16px 20px; background:rgba(79,255,0,0.08); border-radius:10px; border-left:4px solid #4FFF00; font-size:0.85em; line-height:1.5;">
The evals folder isn't what gets the skill right the first time — it's what tells the <em>next</em> edit whether it's still right.
</div>
</div>

---

## The skill, with two independent bugs

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
<div style="display:flex; flex-direction:column; gap:12px; min-height:0;">
<div class="card c1" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #F46600;">
<div style="font-size:1.5em; font-weight:800; color:#F46600; min-width:28px; flex-shrink:0;">1</div>
<div style="font-size:0.85em; line-height:1.45;"><strong>Step 3 accidentally keeps apostrophes</strong> in the character allowlist — they should be dropped.</div>
</div>
<div class="card c2" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #FF00C7;">
<div style="font-size:1.5em; font-weight:800; color:#FF00C7; min-width:28px; flex-shrink:0;">2</div>
<div style="font-size:0.85em; line-height:1.45;"><strong>Nothing transliterates accented characters</strong> — <code>é</code>, <code>à</code>, etc. are just silently dropped, not converted to plain ASCII.</div>
</div>
</div>
<div style="padding:10px 16px; background:rgba(62,64,71,0.3); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:0.78em; color:#B2B8C4;">
Seven steps: lowercase → hyphenate whitespace → strip characters → collapse → trim. Neither bug is obvious from reading it once.
</div>
</div>

---

## Tier 1 — having evals at all

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
<div style="display:flex; gap:16px; min-height:0;">
<div style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(0,255,255,0.25);">
<div style="padding:10px 16px; background:rgba(0,255,255,0.15); font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#00FFFF; font-weight:600;">Agent-written eval, cold</div>
<div style="flex:1; padding:14px; background:rgba(62,64,71,0.25); font-size:0.72em; line-height:1.5;">One prompt: "write evals, include the happy path plus a realistic edge case." No hint about the bug. The agent wrote a case for <code>"Don't Stop Believin'"</code> unprompted, expecting apostrophes dropped.</div>
</div>
<div style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(244,102,0,0.35);">
<div style="padding:10px 16px; background:rgba(244,102,0,0.18); font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#F46600; font-weight:600;">Real run, unmodified skill</div>
<div style="flex:1; padding:14px; background:rgba(62,64,71,0.25); font-size:0.72em; line-height:1.5;"><code>Input: "Don't Stop Believin'"</code><br><code>Output: don't-stop-believin'</code><br><br>Raw apostrophes ship straight into the "URL-safe" slug.</div>
</div>
</div>
<div style="padding:10px 16px; background:rgba(244,102,0,0.12); border-left:3px solid #F46600; border-radius:0 8px 8px 0; font-size:0.78em; color:#F46600; font-weight:700;">
0/3 — clean fail, zero human edits. This is the whole case for having an evals folder at all.
</div>
</div>

---

## Tier 2 — the catch that needed a human

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
<div style="display:flex; gap:16px; min-height:0;">
<div style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(255,0,199,0.3);">
<div style="padding:10px 16px; background:rgba(255,0,199,0.15); font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#FF00C7; font-weight:600;">Agent's first draft eval</div>
<div style="flex:1; padding:14px; background:rgba(62,64,71,0.25); font-size:0.72em; line-height:1.5;"><code>"Café Rules — 2024"</code> → expected <code>caf-rules-2024</code>. Reasoning: "dropped, per the rule that only lowercase letters, digits, hyphens survive."</div>
</div>
<div style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(79,255,0,0.3);">
<div style="padding:10px 16px; background:rgba(79,255,0,0.15); font-size:0.62em; text-transform:uppercase; letter-spacing:0.09em; color:#4FFF00; font-weight:600;">Human correction</div>
<div style="flex:1; padding:14px; background:rgba(62,64,71,0.25); font-size:0.72em; line-height:1.5;">Corrected to <code>cafe-rules-2024</code>. Every real slugify library (WordPress, Jekyll, npm's <code>slugify</code>) transliterates accented letters — dropping one is a defect, not a feature.</div>
</div>
</div>
<div style="padding:10px 16px; background:rgba(255,0,199,0.1); border-left:3px solid #FF00C7; border-radius:0 8px 8px 0; font-size:0.76em; color:#FF00C7; line-height:1.4;">
The agent re-derived "expected" from the skill's own flawed rule instead of judging correctness — an eval like that certifies the bug instead of catching it.
</div>
</div>

---

## Closing the loop

<div style="display:flex; flex-direction:column; flex:1; min-height:0; gap:14px;">
<div class="card c1" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(0,255,255,0.08); border-radius:10px; border-left:4px solid #00FFFF;">
<div style="font-size:0.85em; line-height:1.45;"><strong>Having evals</strong> turns "seems fine" into a reproducible signal on the first run — the apostrophe bug needed zero human correction, just one prompt.</div>
</div>
<div class="card c2" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(79,255,0,0.08); border-radius:10px; border-left:4px solid #4FFF00;">
<div style="font-size:0.85em; line-height:1.45;"><strong>Having a human in the loop</strong> catches the case where the eval itself is wrong — an agent that mechanically re-derives "expected" will certify a bug instead of flagging it.</div>
</div>
<div class="card c3" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(244,102,0,0.08); border-radius:10px; border-left:4px solid #F46600;">
<div style="font-size:0.85em; line-height:1.45;">Two small, cited fixes closed both bugs: drop the apostrophe carve-out, add a transliteration step. <strong>15/15</strong>, no regressions.</div>
</div>
</div>
