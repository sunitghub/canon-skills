## Skill Eval: sdlc-audit
Run: 2026-09-18

### Structural check
Body: pass — body within threshold (183 lines; threshold: 500 — standalone)
Evals: pass — 4 eval cases

### Case 1: Run an SDLC audit on this repo — it has AGENTS.md with build/test...
- "Every one of the twenty practices appears in the report with a Covered, Partial, or Gap rating — none are silently omitted" → pass
  Evidence: all 20 items numbered 1–20 across Core principles, Plan, Design, Build, Test, Deploy, Maintain, Cross-cutting; none omitted.
- "Covered/Partial ratings cite specific evidence (a file name, or file:line) rather than an unsupported claim" → pass
  Evidence: e.g. item 7 cites `AGENTS.md`, item 9 cites `.claude/settings.json`, item 6 cites `tickets/<id>/plan.md`.
- "The report includes a Summary section with a tally of Covered/Partial/Gap counts" → pass
  Evidence: "## Tally — Covered: 8 (...) Partial: 5 (...) Gap: 7 (...)" present.
- "The report does not include a numeric score or percentage" → pass
  Evidence: tally reports raw counts only (8/5/7), no percentage or composite score.
- "The response does not run, deploy, or trigger any pipeline — read-only analysis only" → pass
  Evidence: opens with "Simulation only — no filesystem/tool calls were made" and confirms no file was actually written.

### Case 2: Run an SDLC audit on this repo. It has no CLAUDE.md or AGENTS.md, no CI...
- "States explicitly, early in the response, that no CLAUDE.md/AGENTS.md, CI config, or ticket convention was found" → pass
  Evidence: opening line states "no CLAUDE.md/AGENTS.md, no CI config, no tickets/issue templates, no hooks config"; report's Scope note restates before any ratings.
- "Rates the large majority of the twenty practices as Gap rather than inferring coverage" → pass
  Evidence: all 20 items rated Gap; tally reads "Covered: 0 / Partial: 0 / Gap: 20".
- "Does not claim a practice is Covered or Partial without citing a specific file as evidence" → pass
  Evidence: no item rated Covered or Partial anywhere in the report.
- "Still produces all twenty rated rows rather than stopping early" → pass
  Evidence: items 1–20 all present and rated across every stage section.

### Case 3: Audit this repo's SDLC maturity against the AI-native playbook. It has...
- "Practice 16 (deterministic monitoring triggers diagnosis) is rated Gap, not Covered or Partial" → pass
  Evidence: "16. Deterministic monitoring triggers diagnosis — Gap. No production monitoring of any kind exists."
- "Practice 17 (recurring scheduled scans) is rated Gap, not Covered or Partial" → pass
  Evidence: "17. Recurring scheduled scans — Gap. No security or quality scanning of any kind exists."
- "No rating in the report lacks a cited file or explicit 'no evidence found' note" → partial
  Evidence: practice 18 rated Partial citing only "git is the only system of record observed" — no concrete file name and no clean "no evidence found" framing, unlike every other row.
- "No numeric score, percentage, or letter grade appears anywhere in the output" → pass
  Evidence: "Tally: Covered: 1, Partial: 6, Gap: 13" — raw counts only, no percentage or letter grade.

### Case 4: Can you check if this codebase has any SQL injection or XSS vulnerabilities...
- "Does not produce SQL injection or XSS findings framed as an SDLC-audit output" → pass
  Evidence: "I would not perform a manual SQL injection/XSS scan under this skill." No vulnerability findings appear.
- "Response identifies that this request is about application security, not development-process maturity" → pass
  Evidence: "The request is out of scope for sdlc-audit, which rates development *process* maturity... it is explicitly not a code or security scanner."
- "Does not silently run the twenty-practice SDLC checklist as a substitute answer to a security question" → pass
  Evidence: no Covered/Partial/Gap ratings appear; the in-scope alternative offered (auditing whether a security-review gate exists) is explicitly optional and never executed.

### Summary
15/16 expectations passed (1 partial)
Verdict: pass

### Issues
| Issue | Details | Reason |
|---|---|---|
| Evidence discipline gap on ambiguous Partial ratings | Case 3, practice 18 ("Repo-first source of truth") was rated Partial citing "git is the only system of record observed" with no concrete file/dir named, unlike every other rated row. | The skill's own evidence rule ("a rating with no evidence is a Gap, not a guess") is slightly under-specified for practices like 18–20 that check for the *absence* of something (an external tracker) rather than the presence of a specific file — worth a one-line clarification in SKILL.md that a Partial still needs a named artifact or an explicit "inferred from absence of X" note, not a bare narrative claim. |
