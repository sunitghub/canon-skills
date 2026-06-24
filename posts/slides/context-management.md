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
.c1 { animation-delay: 0.05s; }
.c2 { animation-delay: 0.22s; }
.c3 { animation-delay: 0.39s; }
.c4 { animation-delay: 0.56s; }
.c5 { animation-delay: 0.73s; }
.step { animation: fadeUp 0.3s both; }
.s1 { animation-delay: 0.05s; }
.s2 { animation-delay: 0.18s; }
.s3 { animation-delay: 0.31s; }
.s4 { animation-delay: 0.44s; }
.s5 { animation-delay: 0.57s; }
</style>

<div style="display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0; gap:24px;">
<div style="display:flex; flex-direction:column; gap:16px;">
<div style="font-size:3.2em; font-weight:900; line-height:1.1; color:#FFFFFF; letter-spacing:-0.02em;">Context Hygiene</div>
<div style="width:72px; height:4px; background:linear-gradient(90deg,#00FFFF,#4FFF00); border-radius:2px;"></div>
<div style="font-size:1.15em; color:#00FFFF; font-weight:400; line-height:1.5;">The hidden tax your agent pays before writing a single line of code</div>
</div>
</div>

---

## You think you have this

<div style="display:flex; flex-direction:column; justify-content:center; align-items:center; flex:1; min-height:0; gap:28px;">
<div style="font-size:6em; font-weight:800; color:#00FFFF; letter-spacing:-3px; line-height:1;">200,000</div>
<div style="font-size:1.05em; color:#6F7480; text-align:center;">tokens. Nice big window. Feels unlimited.</div>
</div>

---

## One sentence, many tokens

<div style="display:flex; flex-direction:column; justify-content:center; align-items:center; flex:1; min-height:0; gap:24px;">
<div style="font-size:2.2em; font-weight:800; color:#FFFFFF; letter-spacing:-0.02em; line-height:1.1;">Unbelievable.</div>
<div style="font-size:0.86em; color:#6F7480; text-align:center;">What you type</div>

<div style="display:flex; flex-direction:column; align-items:center; gap:6px;">
  <div style="font-size:2.0em; font-weight:800; color:#00FFFF; letter-spacing:-0.01em; line-height:1.2; text-align:center; font-family:var(--font-mono); white-space:nowrap;">Un | believable | .</div>
  <div style="display:flex; gap:54px; justify-content:center; font-size:0.8em; color:#6F7480; font-family:var(--font-mono); white-space:nowrap;">
    <span>~1</span>
    <span>~1</span>
    <span>~1</span>
  </div>
</div>
<div style="font-size:0.82em; color:#B2B8C4; text-align:center; max-width:860px;">
  This is an approximation: tokenizers split text into pieces, not characters, and the exact split depends on the model and input.
</div>
</div>

---

## The Model is stateless

<div style="font-size:0.8em; color:#B2B8C4; line-height:1.35; margin-bottom:10px;">No memory between turns. Every request resends the context it needs.</div>
<div style="display:flex; flex-direction:column; gap:6px;">
  <div style="display:flex; gap:10px; align-items:center; padding:6px 10px; background:rgba(62,64,71,0.35); border-left:4px solid #6F7480; border-radius:0 8px 8px 0;">
    <div style="font-size:0.95em; font-weight:800; color:#6F7480; min-width:14px;">1</div>
    <div style="font-size:0.72em;"><strong style="color:#B2B8C4;">System prompt</strong> <span style="color:#6F7480;">~14k</span></div>
  </div>
  <div style="display:flex; gap:10px; align-items:center; padding:6px 10px; background:rgba(244,102,0,0.08); border-left:4px solid #F46600; border-radius:0 8px 8px 0;">
    <div style="font-size:0.95em; font-weight:800; color:#F46600; min-width:14px;">2</div>
    <div style="font-size:0.72em;"><strong style="color:#F46600;">Conversation history</strong></div>
  </div>
  <div style="display:flex; gap:10px; align-items:center; padding:6px 10px; background:rgba(79,255,0,0.07); border-left:4px solid #4FFF00; border-radius:0 8px 8px 0;">
    <div style="font-size:0.95em; font-weight:800; color:#4FFF00; min-width:14px;">3</div>
    <div style="font-size:0.72em;"><strong style="color:#4FFF00;">Your new message</strong></div>
  </div>
</div>

## The compounding tax

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:4px;">
<div style="display:flex; flex-direction:column; justify-content:flex-start; gap:8px;">
<div style="display:flex; align-items:center; gap:8px;">
<div style="width:42px; font-size:0.66em; color:#6F7480; text-align:right; flex-shrink:0;">Turn 1</div>
<div style="width:12%; height:22px; background:#00FFFF; border-radius:2px;"></div>
<div style="font-size:0.7em; color:#B2B8C4;">1×</div>
</div>
<div style="display:flex; align-items:center; gap:8px;">
<div style="width:42px; font-size:0.66em; color:#6F7480; text-align:right; flex-shrink:0;">Turn 5</div>
<div style="width:34%; height:22px; background:#4FFF00; border-radius:2px;"></div>
<div style="font-size:0.7em; color:#B2B8C4;">3×</div>
</div>
<div style="display:flex; align-items:center; gap:8px;">
<div style="width:42px; font-size:0.66em; color:#6F7480; text-align:right; flex-shrink:0;">Turn 10</div>
<div style="width:52%; height:22px; background:#FFF500; border-radius:2px;"></div>
<div style="font-size:0.7em; color:#B2B8C4;">6×</div>
</div>
<div style="display:flex; align-items:center; gap:8px;">
<div style="width:42px; font-size:0.66em; color:#6F7480; text-align:right; flex-shrink:0;">Turn 20</div>
<div style="width:72%; height:22px; background:#F46600; border-radius:2px;"></div>
<div style="font-size:0.7em; color:#B2B8C4;">degrades</div>
</div>
</div>
</div>

---

## The fix: fresh context per phase

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
<div style="display:flex; gap:12px;">
<div class="card c1" style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(0,255,255,0.2);">
<div style="padding:10px 14px; background:rgba(0,255,255,0.12); font-size:0.65em; text-transform:uppercase; letter-spacing:0.09em; color:#00FFFF; font-weight:600; text-align:center;">1 · Research</div>
<div style="flex:1; padding:12px; display:flex; flex-direction:column; gap:5px;">
<div style="background:#3E4047; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#B2B8C4; text-align:center;">System Instructions</div>
<div style="background:#3E4047; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#B2B8C4; text-align:center;">Instructions + Tools</div>
<div style="background:#1d4a2a; border:1px solid #4FFF00; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#4FFF00; text-align:center;">/research_codebase</div>
<div style="background:rgba(153,51,255,0.15); border-radius:4px; padding:7px 10px; font-size:0.6em; color:#9933FF; text-align:center;">Task() × 3</div>
<div style="background:rgba(153,51,255,0.15); border-radius:4px; padding:7px 10px; font-size:0.6em; color:#9933FF; text-align:center;">Write()</div>
</div>
<div style="margin:0 12px 12px; padding:8px; background:rgba(244,102,0,0.15); border:1px solid #F46600; border-radius:6px; font-size:0.62em; color:#F46600; text-align:center; font-weight:600;">→ research.md · HUMAN REVIEW</div>
</div>
<div style="display:flex; align-items:center; flex-shrink:0; padding-top:40px;">
<svg width="28" height="20" viewBox="0 0 28 20"><path d="M2 10 L22 10" stroke="#6F7480" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M16 4 L24 10 L16 16" stroke="#6F7480" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
</div>
<div class="card c2" style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(255,245,0,0.2);">
<div style="padding:10px 14px; background:rgba(255,245,0,0.1); font-size:0.65em; text-transform:uppercase; letter-spacing:0.09em; color:#FFF500; font-weight:600; text-align:center;">2 · Planning</div>
<div style="flex:1; padding:12px; display:flex; flex-direction:column; gap:5px;">
<div style="background:#3E4047; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#B2B8C4; text-align:center;">System Instructions</div>
<div style="background:#3E4047; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#B2B8C4; text-align:center;">Instructions + Tools</div>
<div style="background:#1d4a2a; border:1px solid #4FFF00; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#4FFF00; text-align:center;">/create_plan ./research.md</div>
<div style="background:rgba(0,255,255,0.08); border-radius:4px; padding:7px 10px; font-size:0.6em; color:#00FFFF; text-align:center;">Read(research.md)</div>
<div style="background:rgba(153,51,255,0.15); border-radius:4px; padding:7px 10px; font-size:0.6em; color:#9933FF; text-align:center;">Task() × 3 · Write()</div>
</div>
<div style="margin:0 12px 12px; padding:8px; background:rgba(244,102,0,0.15); border:1px solid #F46600; border-radius:6px; font-size:0.62em; color:#F46600; text-align:center; font-weight:600;">→ plan.md · HUMAN REVIEW</div>
</div>
<div style="display:flex; align-items:center; flex-shrink:0; padding-top:40px;">
<svg width="28" height="20" viewBox="0 0 28 20"><path d="M2 10 L22 10" stroke="#6F7480" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M16 4 L24 10 L16 16" stroke="#6F7480" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
</div>
<div class="card c3" style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(244,102,0,0.2);">
<div style="padding:10px 14px; background:rgba(244,102,0,0.12); font-size:0.65em; text-transform:uppercase; letter-spacing:0.09em; color:#F46600; font-weight:600; text-align:center;">3 · Implementation</div>
<div style="flex:1; padding:12px; display:flex; flex-direction:column; gap:5px;">
<div style="background:#3E4047; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#B2B8C4; text-align:center;">System Instructions</div>
<div style="background:#3E4047; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#B2B8C4; text-align:center;">Instructions + Tools</div>
<div style="background:#1d4a2a; border:1px solid #4FFF00; border-radius:4px; padding:7px 10px; font-size:0.6em; color:#4FFF00; text-align:center;">/implement_plan ./plan.md</div>
<div style="background:rgba(0,255,255,0.08); border-radius:4px; padding:7px 10px; font-size:0.6em; color:#00FFFF; text-align:center;">Read() · Edit() · Write()</div>
<div style="background:rgba(153,51,255,0.15); border-radius:4px; padding:7px 10px; font-size:0.6em; color:#9933FF; text-align:center;">MultiEdit() · Task() · …</div>
</div>
<div style="margin:0 12px 12px; padding:8px; background:rgba(79,255,0,0.1); border:1px solid #4FFF00; border-radius:6px; font-size:0.62em; color:#4FFF00; text-align:center; font-weight:600;">Ships ✓</div>
</div>
</div>
</div>

---

## Where context bloat comes from

<div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; flex:1; min-height:0;">
<div class="card c1" style="padding:12px 14px; background:rgba(62,64,71,0.35); border-left:4px solid #F46600; border-radius:0 10px 10px 0; display:flex; flex-direction:column; gap:6px;">
<div style="display:flex; gap:10px; align-items:center;">
<div style="width:22px; height:22px; background:#F46600; border-radius:50%; display:flex; align-items:center; justify-content:center; font-size:0.65em; font-weight:800; color:#1A1A1F; flex-shrink:0;">1</div>
<strong style="font-size:0.82em;">Repeating things in full</strong>
</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4;">If the agent repeats long text instead of pointing to the key part, that text gets paid for again later.</div>
<div style="font-size:0.64em; color:#4FFF00; font-weight:600;">Fix: summarize and point to the key line.</div>
</div>
<div class="card c2" style="padding:12px 14px; background:rgba(62,64,71,0.35); border-left:4px solid #FFF500; border-radius:0 10px 10px 0; display:flex; flex-direction:column; gap:6px;">
<div style="display:flex; gap:10px; align-items:center;">
<div style="width:22px; height:22px; background:#FFF500; border-radius:50%; display:flex; align-items:center; justify-content:center; font-size:0.65em; font-weight:800; color:#1A1A1F; flex-shrink:0;">2</div>
<strong style="font-size:0.82em;">Unused tools</strong>
</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4;">Tools that are loaded but not used still take up space and attention.</div>
<div style="font-size:0.64em; color:#4FFF00; font-weight:600;">Fix: keep only the tools the task needs.</div>
</div>
<div class="card c3" style="padding:12px 14px; background:rgba(62,64,71,0.35); border-left:4px solid #4FFF00; border-radius:0 10px 10px 0; display:flex; flex-direction:column; gap:6px;">
<div style="display:flex; gap:10px; align-items:center;">
<div style="width:22px; height:22px; background:#4FFF00; border-radius:50%; display:flex; align-items:center; justify-content:center; font-size:0.65em; font-weight:800; color:#1A1A1F; flex-shrink:0;">3</div>
<strong style="font-size:0.82em;">Stuff outside the repo</strong>
</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4;">Settings, memory, and imported notes can quietly add weight every session.</div>
<div style="font-size:0.64em; color:#4FFF00; font-weight:600;">Fix: check what loads automatically.</div>
</div>
<div class="card c4" style="padding:12px 14px; background:rgba(62,64,71,0.35); border-left:4px solid #00FFFF; border-radius:0 10px 10px 0; display:flex; flex-direction:column; gap:6px;">
<div style="display:flex; gap:10px; align-items:center;">
<div style="width:22px; height:22px; background:#00FFFF; border-radius:50%; display:flex; align-items:center; justify-content:center; font-size:0.65em; font-weight:800; color:#1A1A1F; flex-shrink:0;">4</div>
<strong style="font-size:0.82em;">Reading the same thing twice</strong>
</div>
<div style="font-size:0.68em; color:#B2B8C4; line-height:1.4;">If the agent keeps going back to the same source, it burns time and context on repetition.</div>
<div style="font-size:0.64em; color:#4FFF00; font-weight:600;">Fix: reference what was already read.</div>
</div>
</div>

---

## Monitor what auto-loads

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
<div style="display:flex; flex-direction:column; gap:10px; justify-content:center;">
<div class="card c1" style="display:flex; gap:14px; align-items:stretch; padding:14px 18px; background:rgba(62,64,71,0.35); border-radius:8px; border-left:3px solid #00FFFF;">
<div style="display:flex; flex-direction:column; gap:4px; flex:1;">
<div style="font-size:0.7em; text-transform:uppercase; letter-spacing:0.08em; color:#00FFFF; font-weight:600;">Connected tools</div>
<div style="font-size:0.78em; color:#B2B8C4; line-height:1.4;">Claude Code: MCP servers and hooks. Claude Desktop: connectors and project tools. Keep only what the work needs.</div>
</div>
</div>
<div class="card c2" style="display:flex; gap:14px; align-items:stretch; padding:14px 18px; background:rgba(62,64,71,0.35); border-radius:8px; border-left:3px solid #9933FF;">
<div style="display:flex; flex-direction:column; gap:4px; flex:1;">
<div style="font-size:0.7em; text-transform:uppercase; letter-spacing:0.08em; color:#9933FF; font-weight:600;">Memory and long chats</div>
<div style="font-size:0.78em; color:#B2B8C4; line-height:1.4;">Old context can quietly shape new answers. Trim stale memory, restart long chats, and keep reusable notes short.</div>
</div>
</div>
<div class="card c3" style="display:flex; gap:14px; align-items:stretch; padding:14px 18px; background:rgba(62,64,71,0.35); border-radius:8px; border-left:3px solid #FFF500;">
<div style="display:flex; flex-direction:column; gap:4px; flex:1;">
<div style="font-size:0.7em; text-transform:uppercase; letter-spacing:0.08em; color:#FFF500; font-weight:600;">Project instructions</div>
<div style="font-size:0.78em; color:#B2B8C4; line-height:1.4;">Claude Code has <code>CLAUDE.md</code>; Desktop has project instructions and attached docs. Keep them short and current.</div>
</div>
</div>
</div>
<div style="padding:10px 16px; background:rgba(0,255,255,0.06); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:0.8em; color:#B2B8C4; display:flex; justify-content:space-between; align-items:flex-start; gap:16px;">
<div>The pattern is the same in both products: auto-loaded instructions, tools, and memory can grow without you noticing.</div>
<div style="font-size:0.85em; color:#6F7480; white-space:nowrap; flex-shrink:0;">Claude Code gives you more knobs; Desktop hides more of them.</div>
</div>
</div>

---

## Agent guardrails

<div style="display:grid; grid-template-rows:auto 1fr; flex:1; min-height:0; gap:8px;">
<div style="font-size:0.75em; color:#6F7480;">Rules a user or team can put in Claude Code's <code>CLAUDE.md</code> or Desktop project instructions</div>
<div style="display:flex; gap:24px; min-height:0;">
<div style="flex:1; display:flex; flex-direction:column; gap:8px;">
<div style="font-size:0.7em; color:#F46600; text-transform:uppercase;">Don't do this</div>
<div style="display:flex; flex-direction:column; gap:8px; font-size:0.76em; line-height:1.4;">
<div style="padding:8px 10px; background:rgba(244,102,0,0.07); border-radius:6px;">Read everything when you only need one part.</div>
<div style="padding:8px 10px; background:rgba(244,102,0,0.07); border-radius:6px;">Search the whole project when a smaller area is enough.</div>
<div style="padding:8px 10px; background:rgba(244,102,0,0.07); border-radius:6px;">Copy long files into the response instead of summarizing.</div>
</div>
</div>
<div style="flex:1; display:flex; flex-direction:column; gap:8px;">
<div style="font-size:0.7em; color:#00FFFF; text-transform:uppercase;">Do this instead</div>
<div style="display:flex; flex-direction:column; gap:8px; font-size:0.76em; line-height:1.4;">
<div style="padding:8px 10px; background:rgba(0,255,255,0.06); border-radius:6px;">Ask for the specific line, section, or detail you need.</div>
<div style="padding:8px 10px; background:rgba(0,255,255,0.06); border-radius:6px;">Limit searches to the relevant file or folder.</div>
<div style="padding:8px 10px; background:rgba(0,255,255,0.06); border-radius:6px;">Cite what matters instead of repeating the full source.</div>
</div>
</div>
</div>
</div>

---

## Audit your load

<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
<div style="display:flex; flex-direction:column; gap:10px; justify-content:center;">
<div class="card c1" style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,0.35); border-radius:8px; font-size:0.82em;">
<span style="color:#00FFFF; flex-shrink:0;">→</span><span>Claude Code: run <code>/context-check</code> to list imported files and line counts</span></div>
<div class="card c2" style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,0.35); border-radius:8px; font-size:0.82em;">
<span style="color:#00FFFF; flex-shrink:0;">→</span><span>Claude Code: size registered skills and always-loaded instructions</span></div>
<div class="card c3" style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,0.35); border-radius:8px; font-size:0.82em;">
<span style="color:#00FFFF; flex-shrink:0;">→</span><span>Claude Desktop: review project instructions, attachments, connectors, and long chats</span></div>
<div class="card c4" style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,0.35); border-radius:8px; font-size:0.82em;">
<span style="color:#FFF500; flex-shrink:0;">→</span><span>Flags files where <strong>less than half</strong> the content is usually relevant</span></div>
<div class="card c5" style="display:flex; gap:14px; align-items:center; padding:11px 16px; background:rgba(62,64,71,0.35); border-radius:8px; font-size:0.82em;">
<span style="color:#FFF500; flex-shrink:0;">→</span><span>Catches <strong>cross-file redundancy</strong> — same rule in two places</span></div>
</div>
<div style="padding:10px 16px; background:rgba(0,255,255,0.06); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:0.82em; color:#B2B8C4;">Run periodically. In Desktop, do the same review manually.</div>
</div>

---

## Five rules for context hygiene

<div style="display:flex; flex-direction:column; gap:10px; flex:1; min-height:0;">
  <div class="card c1" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #00FFFF;">
    <div style="font-size:1.5em; color:#00FFFF; font-weight:800; min-width:28px; line-height:1; flex-shrink:0;">1</div>
    <div style="font-size:0.88em; line-height:1.45;"><strong>Keep it tight from the first turn</strong> — verbose output today is a tax on every future turn</div>
  </div>
  <div class="card c2" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #4FFF00;">
    <div style="font-size:1.5em; color:#4FFF00; font-weight:800; min-width:28px; line-height:1; flex-shrink:0;">2</div>
    <div style="font-size:0.88em; line-height:1.45;"><strong>Always-on vs on-demand</strong> — load sub-skills at the step that needs them, not at session start</div>
  </div>
  <div class="card c3" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #FFF500;">
    <div style="font-size:1.5em; color:#FFF500; font-weight:800; min-width:28px; line-height:1; flex-shrink:0;">3</div>
    <div style="font-size:0.88em; line-height:1.45;"><strong>Reference, don't repeat</strong> — point to the source instead of echoing content already in context</div>
  </div>
  <div class="card c4" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #F46600;">
    <div style="font-size:1.5em; color:#F46600; font-weight:800; min-width:28px; line-height:1; flex-shrink:0;">4</div>
    <div style="font-size:0.88em; line-height:1.45;"><strong>Keep tools on demand</strong> — don't load tools or skills "just in case"</div>
  </div>
  <div class="card c5" style="display:flex; gap:18px; align-items:center; padding:14px 20px; background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #FF00C7;">
    <div style="font-size:1.5em; color:#FF00C7; font-weight:800; min-width:28px; line-height:1; flex-shrink:0;">5</div>
    <div style="font-size:0.88em; line-height:1.45;"><strong>Measure before optimizing</strong> — audit what is loaded before guessing what's bloated</div>
  </div>
</div>

---

## Hands-on: app development with an agentic harness

<div style="display:grid; grid-template-rows:auto 1fr; flex:1; min-height:0; gap:12px;">
<div style="display:grid; grid-template-columns:repeat(4,1fr); gap:10px;">
<div class="card c1" style="display:flex; align-items:center; gap:10px; padding:10px 12px; background:linear-gradient(135deg,rgba(0,255,255,0.18),rgba(62,64,71,0.28)); border:1px solid rgba(0,255,255,0.38); border-radius:8px;">
<div style="width:28px; height:28px; border-radius:50%; background:#00FFFF; color:#1A1A1F; display:flex; align-items:center; justify-content:center; font-size:0.68em; font-weight:900; flex-shrink:0;">1</div>
<div><div style="font-size:0.68em; color:#00FFFF; font-weight:800; text-transform:uppercase;">Sprint Tickets</div><div style="font-size:0.58em; color:#CBD0D8; line-height:1.3;">Scope that survives the chat.</div></div>
</div>
<div class="card c2" style="display:flex; align-items:center; gap:10px; padding:10px 12px; background:linear-gradient(135deg,rgba(79,255,0,0.15),rgba(62,64,71,0.28)); border:1px solid rgba(79,255,0,0.35); border-radius:8px;">
<div style="width:28px; height:28px; border-radius:50%; background:#4FFF00; color:#1A1A1F; display:flex; align-items:center; justify-content:center; font-size:0.68em; font-weight:900; flex-shrink:0;">2</div>
<div><div style="font-size:0.68em; color:#4FFF00; font-weight:800; text-transform:uppercase;">Kanban Board</div><div style="font-size:0.58em; color:#CBD0D8; line-height:1.3;">Status you can inspect.</div></div>
</div>
<div class="card c3" style="display:flex; align-items:center; gap:10px; padding:10px 12px; background:linear-gradient(135deg,rgba(255,245,0,0.14),rgba(62,64,71,0.28)); border:1px solid rgba(255,245,0,0.35); border-radius:8px;">
<div style="width:28px; height:28px; border-radius:50%; background:#FFF500; color:#1A1A1F; display:flex; align-items:center; justify-content:center; font-size:0.68em; font-weight:900; flex-shrink:0;">3</div>
<div><div style="font-size:0.68em; color:#FFF500; font-weight:800; text-transform:uppercase;">Close Gates</div><div style="font-size:0.58em; color:#CBD0D8; line-height:1.3;">Proof before done.</div></div>
</div>
<div class="card c4" style="display:flex; align-items:center; gap:10px; padding:10px 12px; background:linear-gradient(135deg,rgba(255,0,199,0.13),rgba(62,64,71,0.28)); border:1px solid rgba(255,0,199,0.35); border-radius:8px;">
<div style="width:28px; height:28px; border-radius:50%; background:#FF00C7; color:#1A1A1F; display:flex; align-items:center; justify-content:center; font-size:0.68em; font-weight:900; flex-shrink:0;">4</div>
<div><div style="font-size:0.68em; color:#FF00C7; font-weight:800; text-transform:uppercase;">Continuity</div><div style="font-size:0.58em; color:#CBD0D8; line-height:1.3;">Resume with context intact.</div></div>
</div>
</div>
<div style="display:grid; grid-template-columns:1.22fr 0.78fr; gap:18px; min-height:0; align-items:stretch;">
<div style="position:relative; min-height:0; display:flex; flex-direction:column; background:rgba(62,64,71,0.24); border:1px solid rgba(0,255,255,0.22); border-radius:8px; overflow:hidden; box-shadow:0 18px 34px rgba(0,0,0,0.35);">
<div style="position:absolute; top:10px; left:12px; z-index:1; padding:5px 9px; background:rgba(0,255,255,0.92); color:#1A1A1F; border-radius:999px; font-size:0.54em; font-weight:900; text-transform:uppercase;">Harness view</div>
<img src="./agentic-harness-board.png" style="width:100%; height:100%; object-fit:contain; object-position:center top; display:block;" />
</div>
<div style="display:grid; grid-template-rows:1fr auto; min-height:0; gap:12px;">
<div style="position:relative; min-height:0; display:flex; align-items:center; justify-content:center; background:#FFFFFF; border:8px solid rgba(255,255,255,0.12); border-radius:8px; overflow:hidden; box-shadow:0 18px 34px rgba(0,0,0,0.35);">
<div style="position:absolute; top:10px; left:12px; z-index:1; padding:5px 9px; background:#4FFF00; color:#1A1A1F; border-radius:999px; font-size:0.54em; font-weight:900; text-transform:uppercase;">App result</div>
<img src="./agentic-harness-todo.png" style="width:100%; height:100%; object-fit:contain; display:block;" />
</div>
<div style="padding:12px 14px; padding-right:150px; background:rgba(0,255,255,0.07); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0;">
<div style="font-size:0.82em; color:#FFFFFF; font-weight:800;">Build, verify, close.</div>
<div style="font-size:0.64em; color:#B2B8C4; line-height:1.35; margin-top:3px;">A practical workshop for shipping a small app with tickets, board state, close gates, and restartable sessions.</div>
</div>
</div>
</div>
</div>
