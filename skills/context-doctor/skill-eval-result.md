## Skill Eval: context-doctor
Run: 2026-11-15

### Structural check
Body: pass — body within threshold (241 lines; threshold: 500 — standalone)
Evals: pass — 7 eval cases

### Case 1: Run context-doctor on this repo. Here is the entire agent c...
- "Rates Rules -> judgement as action, citing CLAUDE.md line 2, and recommends judgment-framed guidance instead of the blanket rule" → pass
  Evidence: "| Rules → judgement | action | `CLAUDE.md:2` ... | Replace with judgment framing: "Match the surrounding code's comment density and idiom...""
- "Rates Conflicting instructions as action, quoting both the 'no comments' (line 2) and 'leave documentation' (line 3) sides" → pass
  Evidence: "`CLAUDE.md:2` "default to writing NO comments..." vs `CLAUDE.md:3` "Always leave documentation as appropriate for the reader.""
- "Produces a Summary table with one row per lens (lens/status/evidence/recommendation)" → pass
  Evidence: "| Lens | Status | Evidence | Recommendation |" with 11 rows (7 lenses, checks 8-11)
- "Overall verdict is trim or overloaded, not lean" → pass
  Evidence: "context-doctor verdict: trim"
- "Emits no numeric score or percentage" → pass
  Evidence: only dates, line counts and line numbers appear

### Case 2: Run context-doctor on this repo. It contains only applicati...
- "States there are no agent-context artifacts (no CLAUDE.md/AGENTS.md/skills) and stops with a limited-scope note" → pass
  Evidence: "Context Doctor: no agent context found" ... "None of them exist."
- "Does NOT fabricate findings on any of the seven lenses" → pass
  Evidence: "Nothing was audited, so there is no Summary table and no verdict."
- "Does not present a misleading verdict as though real context was assessed" → pass
  Evidence: "gave no lean/trim/overloaded verdict"

### Case 3: You are running context-doctor and are about to produce th...
- "Uses the seven lens names with per-lens status and a lean/trim/overloaded verdict, explicitly no numeric score" → pass
  Evidence: names all seven lenses; "Each status is aligned, advisory or action"; "No numeric score ... anywhere."
- "States it is static-only — does not run the repo or edit the audited files" → pass
  Evidence: "No Bash, no running the repo, no executing skills, no model calls, no network, no edits to any audited file."
- "States it writes claude-optimization.md to the repo root after explicit confirmation (overwrite snapshot)" → pass
  Evidence: "On `y`: one Write to claude-optimization.md at the repo root, overwriting any existing copy."

### Case 4: Run context-doctor. The repo's agent context is one always-...
- "Rates Upfront -> progressive disclosure as action and recommends moving the rarely-needed release procedure behind on-demand loading" → pass
  Evidence: "| Upfront → progressive disclosure | action | ... | Move the release procedure into an on-demand skill/reference file"
- "Notes the obvious repo-layout description as low-value always-on context" → pass
  Evidence: "The ~90-line repo-layout section is always-on weight for facts the agent can read from the tree."
- "Does NOT flag the migration-safety rule as over-constraint — recognizes safety/irreversible-action rules should stay explicit" → pass
  Evidence: "| Rules → judgement | aligned | ... | Keep it explicit. It guards an irreversible, destructive action"
- "Overall verdict is trim or overloaded" → pass
  Evidence: "context-doctor verdict: trim"

### Case 5: Run context-doctor on this repo. The running session's syst...
- "The report header says it audited against Claude 5 guidance, detected from the session (not a --model override)" → pass
  Evidence: "Audited against: Claude 5 context-engineering guidance (detected from session: Fable 5.1, claude-fable-5-1)"
- "Rates Reasoning-extraction avoidance as action, citing CLAUDE.md line 2, with a fix that drops the instruction" → pass
  Evidence: "| Reasoning-extraction avoidance (5 only) | action | `CLAUDE.md:2` ... | Delete line 2 ... Read reasoning from summarized thinking blocks instead."
- "Rates Effort-default guidance as advisory (not action), citing line 3's blanket max effort on routine work" → pass
  Evidence: "| Effort-default guidance (5 only) | advisory | `CLAUDE.md:3` ... | ... drop blanket `max`."
- "The Summary table has all eleven rows, including Reasoning-extraction avoidance and Effort-default guidance" → pass
  Evidence: 11 rows, Rules → judgement through Effort-default guidance (5 only)
- "Overall verdict is trim or overloaded, and no numeric score or percentage appears" → pass
  Evidence: "context-doctor verdict: trim"; no score or percentage

### Case 6: Run context-doctor --model 4 on this repo. The running sess...
- "The report header says it audited against Claude 4 guidance, chosen by the --model override" → pass
  Evidence: "Audited against: Claude 4 context-engineering guidance (--model override; session model Fable 5.1 would have detected 5)"
- "The Summary table has no Reasoning-extraction avoidance row and no Effort-default guidance row, and neither is printed as n/a" → pass
  Evidence: rows left out "because the mode is `4`. They are not printed as n/a."
- "Does not raise line 2's 'explain your reasoning' instruction as a reasoning-extraction finding" → pass
  Evidence: checks 10/11 skipped in `4` mode; line 2 cited only under Rules → judgement
- "Rates Checkpoint/pause discipline as action or advisory, citing line 5's 'Shall I proceed?' before every edit" → pass
  Evidence: "| Checkpoint/pause discipline | action | CLAUDE.md:5 "Before every file edit, ask the user 'Shall I proceed?'..." |"
- "The Summary table includes a Progress-claim grounding row with a status" → pass
  Evidence: "| Progress-claim grounding | advisory | CLAUDE.md:4 ..."

### Case 7: Run context-doctor on this repo. The running session's syst...
- "The report header says it audited against Claude 5 guidance, detected from the session" → pass
  Evidence: "Audited against: Claude 5 context-engineering guidance (detected from session)"
- "Identifies the repo's target model as Opus 5 from .claude/settings.json" → pass
  Evidence: "Target model for checks 10-11: Opus 5 (from .claude/settings.json `"model": "claude-opus-5"`)"
- "Does not rate Reasoning-extraction avoidance as action for line 2 (it is aligned, or stated as not applicable to an Opus 5 target)" → pass
  Evidence: "| Reasoning-extraction avoidance (5 only) | aligned (not raised) | ... lacks the reasoning_extraction category"
- "Does not flag line 3's 'default (high)' as a wrong default assumption" → pass
  Evidence: "| Effort-default guidance (5 only) | aligned | ... high is Opus 5's default"
- "No numeric score or percentage appears" → pass
  Evidence: "context-doctor verdict: lean"; no score or percentage

### Summary
30/30 expectations passed
Verdict: pass
Executors and graders: claude-opus-5-5 (every agent dispatched with model `opus`). The first run scored 29/30: case 2 printed "context-doctor verdict: lean (limited scope)" because the Report section required the verdict line while the no-context gotcha said to stop. SKILL.md now exempts the no-context stop from the verdict line (Report and Gotchas); case 2 was re-run on that SKILL.md and is the result above. Cases 1 and 3-7 ran on the SKILL.md before that two-line edit, which changes only the no-context path. Baseline: new cases 5-7 against the pre-mode skill (96273b4b) score 1/5, 2/5, 3/5 (.tickets/t-7e8c/baseline-eval.md).

### Issues
| Issue | Details | Reason |
|---|---|---|
| Verdict line vs no-context stop | Fixed in this run: SKILL.md said the verdict line is always required and also that a no-context repo stops with a limited-scope note | An executor printed a lean verdict for a repo with nothing audited |
