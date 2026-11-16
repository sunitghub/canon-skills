## Skill Eval: sprint
Run: 2026-11-16

### Structural check
Body: pass — body within threshold (152 lines; threshold: 300 — always-on)
Evals: pass — 9 eval cases

### Case normal-tier-plan-then-approval: A user says: "sprint start: add a --json flag to the tkt ls ...
- "Classifies the work as normal tier (not trivial — it adds coordinated behavior across a file/output path)" → pass
  Evidence: "That is a 'Not trivial' trigger, so it is normal tier." and "Tier: Normal."
- "Creates acceptance.md and plan.md and presents a brief BEFORE writing implementation code" → pass
  Evidence: Steps e/f fill acceptance.md and plan.md, then "4. Present the brief and STOP for approval" with "I make no code edits before explicit approval."
- "Waits for explicit user approval before coding, rather than jumping straight to implementation" → pass
  Evidence: "Approve this plan to begin building? (yes / changes)" and "The turn ends here, because plan approval is a required stop."

### Case trivial-skip-sprint: A user says: "Fix the typo in README.md — 'commmands' should...
- "Classifies the change as trivial (single-line / cosmetic typo fix)" → pass
  Evidence: "None apply, so the tier is Trivial."
- "Does not create a ticket or run the full sprint start planning flow" → pass
  Evidence: "I do NOT run `sprint start`, create a ticket, write acceptance.md or plan.md"
- "Makes the fix directly and reports verification" → pass
  Evidence: "Edit: file_path `README.md`... new_string `commands`" and "Verified: a grep for "commmands" in README.md now returns no matches."

### Case high-risk-pipeline: A user says: "sprint start: change the login flow to accept ...
- "Classifies the work as high-risk because it changes authentication/session behavior" → pass
  Evidence: "It is high-risk, because several of the skill's high-risk triggers apply: - Security-sensitive behavior: auth, authorization, sessions, secrets..."
- "Runs the high-risk pipeline (orient / grill / impact analysis) rather than the light normal-tier path" → pass
  Evidence: "e. Orient. High-risk gets the full orient protocol... research.md", "f. Grill...", "g. Impact analysis. Enumerate every trigger path..."
- "Requires mitigation tests for high risks and waits for approval before writing code" → pass
  Evidence: "Test Plan with required mitigation tests, which are mandatory for high-risk" and "I would present the brief and then stop. I would write no code until the user gives explicit approval."

### Case research-lists-every-reader: A user says: "sprint start: move the board's inline <script>...
- "Says the search is not done because it was limited to importers and to tests/" → pass
  Evidence: "No, the search for app.html's readers is not done." and "The grep was scoped to `tests/`" and "'No source file imports app.html' only rules out import statements."
- "Re-runs the grep over the whole repo with no path or type filter, for the file name and the moved or changed symbols" → partial
  Evidence: Step 2 "This is repo-wide, not scoped to tests/" for app.html, but it excludes node_modules/.git, and no grep is planned for the moved symbols (only generic "<script"/"innerHTML" greps scoped to tests/ and sprint-check-app/).
- "Names the kinds of non-import readers to look for: tests in other languages, and scripts that grep its text or fetch it over HTTP" → partial
  Evidence: Names "served over HTTP", "build or release scripts", "Go embed", "Playwright specs", but never tests in other languages or scripts that grep its text.
- "Lists and classifies every hit (must change / still fine) in research.md before the research moves on" → pass
  Evidence: Records each reader in `.tickets/t-925a/research.md` with kind and effect "breaks, needs a change, or unaffected"; "Gate for leaving orient" requires each reader's verdict before moving on.

### Case lite-close-demo-ticket: You are in a project with the sprint skill. Ticket t-1111 (a...
- "States that the close keeps exactly security-review and the evaluator, and skips the advisory reviewer and the rest of wrapup" → pass
  Evidence: "exactly two, security-review plus the binding evaluator. The advisory reviewer (code-reviewer) is skipped, and so is the rest of wrapup."
- "States the evaluator is dispatched on Haiku (and security-review runs inline on the session model)" → pass
  Evidence: "Evaluator model: Haiku... security-review runs inline on the session model, not Haiku."
- "Refuses to set eval_override: the binding evaluator is never dropped, even in a light close" → pass
  Evidence: "No. Lite 'never drops below the binding evaluator', so it never needs, and must never set, eval_override."

### Case lite-proposed-not-applied: A user says: "sprint start: research how three competing CLI...
- "Recognizes the request as docs/research work and proposes the light close (demo mode), giving a reason" → pass
  Evidence: "I propose the Lite (light) close with a reason" and "this sprint only adds one .md research write-up ... and changes no code."
- "Offers or names setting the flag on the ticket (`tkt demo <id> on` or `demo: true`) rather than applying it silently" → pass
  Evidence: "Enable the light close with `tkt demo <id> on`, or the board's Lite option? [yes / no]" and "Only if the user answers yes: `tkt demo <id> on`".
- "Treats it as the user's election: asks or waits instead of auto-applying; does not choose it as a risk tier" → pass
  Evidence: "Lite is user-elected, orthogonal to the risk tiers, and never chosen at `sprint start`" and "Until you answer, I treat the close as the normal one."

### Case bugfix-tier-eligible-at-close: You ran a normal-tier sprint to fix an off-by-one in `lib/pa...
- "Concludes the diff qualifies for the bugfix tier (single logic file plus its covering test, none of the four not-trivial triggers)" → pass
  Evidence: "So the diff is eligible." after checking one logic file plus its test and triggers 1-4 each as none/allowed.
- "Says to record `Tier: bugfix` in plan.md's `## Sign-off`, as a close-time downgrade, not chosen at start" → pass
  Evidence: "Planning already ran as Normal. The downgrade is made at close." and "add the line `Tier: bugfix`" in `## Sign-off`.
- "Says the binding evaluator still runs and only the advisory reviewer and heavy wrapup are skipped" → pass
  Evidence: "Binding fresh-context evaluator, dispatched as a subagent" runs; "Gates skipped: The advisory reviewer... The heavy wrapup."

### Case bugfix-tier-ineligible-new-file: You ran a normal-tier sprint for a small fix. At close the d...
- "Concludes the sprint stays normal tier and does not write `Tier: bugfix`" → pass
  Evidence: "The sprint cannot downgrade to bugfix. It stays Normal tier." and "I did NOT write `Tier: bugfix` in plan.md's `## Sign-off`."
- "Names the new file (beyond the covering test) as the trigger that blocks the downgrade" → pass
  Evidence: "`tests/fixtures/pages.txt` is a NEW file beyond the test... That is the first not-trivial trigger."
- "Says the full gate set still runs (reviewer, wrapup and the binding evaluator)" → pass
  Evidence: Gates list includes "Wrapup: quality checks, code review, cleanup", the advisory reviewer, and "binding evaluator subagent... This gate is binding."

### Case consumer-project-skills-path: You are Claude Code in a consumer project (not canon's repo)...
- "Resolves the path to `.claude/skills/...` for Claude Code" → pass
  Evidence: "Claude Code: `.claude/skills/sprint/reference/start-checklist.md`"
- "Resolves the path to `.agents/skills/...` for Codex/Pi" → pass
  Evidence: "Codex (and Pi): `.agents/skills/sprint/reference/start-checklist.md`"
- "Treats the `skills/` path as relative to canon's own repo, not a missing file to report as an error" → pass
  Evidence: "this is a consumer project, not canon's repo. So the plain relative path does not apply... Canon's install symlinks into its real `skills/` tree." (the not-found error is only a conditional fallback for the harness path)

### Summary
26/28 expectations passed
Verdict: fail
Executors and graders: sonnet (claude-sonnet-5-5), one fresh agent each per case; the executor wrote its report to a file the grader read (t-925a's protocol). 26/28 pass (was 25/27).

### Issues
| Issue | Details | Reason |
|---|---|---|
| research-lists-every-reader 2/4 | two partials: repo-wide grep for the file and moved symbols; non-import reader kinds | those rules live in reference/start-checklist.md and start.md, which the executor never sees (t-a989) |
