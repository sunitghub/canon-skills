# LinkedIn Posts

Running log of short posts. Posts first, then replies; each group is ordered by Date ascending. Each entry: status, hook, post text, image, hashtags.

## Post 1 — Wrapup gates: why "skipped" is a first-class verdict

**Status:** Draft
**Date:** 2026-07-30
**Format:** Standalone LinkedIn post
**Core hook:** The most trustworthy line in an AI coding report may be the one that says `skipped` — with a reason.
**Attention GIF:** `posts/images/wrapup-gates-resolve.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

Every "AI wrote the code" story skips the part that actually matters: what checked it before it shipped.

Here is the wrapup from a docs-only change I made this week:

• code-simplifier — skipped, docs-only
• code-reviewer — skipped, no logic changed
• reviewer — ran, verdict YES
• security-review — skipped, README prose only
• repo-check — ran, no repo surface changed, npm test green
• doc-audit — ran, README reworded, docx regenerated, all image refs resolve
• eval — ran, docx restore-first guards held, tree clean
• mutation-test — skipped, advisory, no logic files changed

Nothing here is exciting. That is the point.

Two of those gates — repo-check and doc-audit — are not glamorous. They do not judge whether the code is clever. They check whether the repo is still internally consistent and whether the docs still describe what is actually there.

That is the failure mode that does not announce itself: the agent edits the code, forgets the doc that promises a behavior, and leaves the next person — human or agent — with a repo that lies.

A skipped gate is not a shortcut. It is a claim: this check looked at the diff, decided it was out of scope, and said why. That reason is auditable. An agent that silently does not run a check is indistinguishable from one that forgot to.

Visible gates, with reasons attached, are how you start trusting an agent's "done."

What is the most useful thing your AI workflow leaves behind: more time, or more context to carry?

#AgenticCoding #AIEngineering #SoftwareEngineering #DevTools

### Attachments

Upload separately, in this order:

1. `posts/images/wrapup-gates-resolve.gif` — illustrative attention GIF; the eight close-path gates resolve top-to-bottom, each stamping ran (green) or skipped (slate) with its reason, landing on eval: pass — 4/4 criteria. Place it immediately below the opening hook. Decorative, not evidence.
2. `images/wrapup-gates-table.png` — grounded evidence: the real gate table from the session. Keep as-is; do not substitute an illustration.

---

## Post 2 — Promise vs. delivered behavior

**Status:** Draft
**Date:** 2026-07-30
**Format:** Standalone LinkedIn post
**Source:** Ticket `t-e979` Summary tab
**Core hook:** A promise in a plan is easy; the deliverable is behavior you can see, verify, and keep.

### Copy/paste into LinkedIn

One of the best ways to tell whether an agentic workflow is real: compare its promise with its delivered behavior.

Promise:

• The Test Plan placeholder appears when a scenario is added.
• The first Save succeeds.
• No Save → re-open dance.
• Only the Acceptance editor changes.

Delivered:

• The placeholder seeds at scenario insert and on Save.
• A filled checkbox lets first-save validation pass.
• The helper is idempotent, guarded, and does not clobber a real command.
• The behavior was covered by 11 unit checks, a live Playwright + system Chrome flow, lint, and npm test.
• The README and README.docx were updated to match what the board actually does.

The lines in a Summary tab are not just closure paperwork. They translate intent into observable behavior.

That is the difference between an agent saying “fixed” and a repo showing what “fixed” means.

The strongest evidence is not the promise. It is the state that remains after the action.

### Attachments

Upload separately:

1. `images/t-e979-promise-delivered.png` — an illustration of a plan becoming verified, delivered behavior.

---

## Post 3 — npm audit is not a punch list

**Status:** Draft
**Date:** 2026-07-30
**Format:** Standalone LinkedIn post
**Source:** Ticket `t-9cc0` Plan tab — high/critical npm dependency advisory remediation
**Core hook:** A dependency security fix can become a build-system incident if nobody maps the blast radius first.

### Copy/paste into LinkedIn

npm audit said: “Just update a few packages.”

The plan said: “First, let’s find out who is standing on that dependency.”

Dependency remediation is not whack-a-mole. An exact override can cross semver ranges and feed every consumer in the toolchain:

• npm and pre-commit
• Expo and React Native config
• Metro
• ESLint and TypeScript
• Jest and Detox
• Sharp
• CocoaPods and Xcode

That is why a high/critical audit finding needs more than a green install:

• verify the actual consumer paths
• lock the intended version deliberately
• preserve dependency invariants
• recheck builds, lint, tests, and native tooling
• separate moderate findings from completion

A security fix that breaks the build is not a fix. A clean local install that fails CI is not progress.

The useful artifact is not “npm audit fix ran.”

It is: “the vulnerable path changed, every consumer was rechecked, and the evidence says the toolchain still works.”

How do you handle dependency remediation when the blast radius is larger than the package named in the advisory?

### Attachments

- `posts/images/t-9cc0-npm-remediation-plan.png` — evidence screenshot from the ticket Plan tab; shows the consumer map, impact assessment, and required remediation actions.

---

## Post 4 — Impact assessment before implementation

**Status:** Published
**Date:** 2026-07-30
**Format:** Standalone LinkedIn post
**Source:** Ticket `t-9cc0` Plan tab — pre-implementation impact assessment
**Core hook:** The most expensive dependency bug is the one you create while fixing a different dependency bug.
**Attention GIF:** `posts/images/t-9cc0-impact-dominoes.gif` — upload first as the visual hook.

### Copy/paste into LinkedIn

The most expensive dependency bug is the one you create while fixing a different dependency bug.

That is why impact assessment happens before implementation.

Before touching package.json, canon asks five questions:

• Who is affected?
• Can we reverse it cleanly?
• How wide is the blast radius?
• What paths consume the change?
• What can cascade if the assumption is wrong?

For this dependency remediation, the change is reversible—but the overall risk is HIGH. Exact transitive overrides can destabilize the shared build toolchain even when the edit looks small.

So the plan names the consumers before the fix: npm and pre-commit, Expo and React Native config, Metro, ESLint and TypeScript, Jest and Detox, Sharp, and CocoaPods/Xcode.

That is not process for process’s sake. It is how a “quick fix” becomes a bounded change with a known rollback and a verification plan.

What do you assess before implementing a change that looks local but feeds half the toolchain?

### Attachments

Upload these separately in this order:

1. `posts/images/t-9cc0-impact-dominoes.gif` — humorous attention GIF; place it immediately below the opening hook.
2. `posts/images/t-9cc0-npm-remediation-plan.png` — evidence screenshot from the ticket Plan tab; shows the five impact dimensions, HIGH overall rating, and required actions.

---

## Post 5 — Passing tests are not proof

**Status:** Draft
**Date:** 2026-07-30
**Format:** Standalone LinkedIn post
**Source:** Ticket `t-9cc0` Mutation Report tab — npm audit high/critical dependency remediation
**Core hook:** A security patch is only as good as the test that would catch someone breaking it later.

### Copy/paste into LinkedIn

This ticket patched a dependency to close a supply-chain vulnerability:

• npm audit — clean
• tests — passing
• independent reviewer — signed off
• evaluator — passed every criterion

None of those checks answer one question: can the fix be silently undone by the next edit?

Mutation testing does. It deliberately breaks the patched logic, one small change at a time, and reruns the suite. If the suite still passes, the test was never actually watching that line.

A simple example. patched.cjs:123 guards against expansion running past a length limit:

if (length + expansion.length > maxLength) return

Flip one character:

if (length - expansion.length > maxLength) return

Same inputs, opposite outcome, with maxLength = 100:

• Existing test — length 2, expansion.length 2: correct gives 2+2=4 (no stop), mutant gives 2-2=0 (no stop). Same result, so the test can’t tell them apart.
• Real attack input — length 90, expansion.length 20: correct gives 90+20=110 (stop, blocks the runaway expansion). Mutant gives 90-20=70 (no stop) — the exact over-limit case the patch was written to catch, sailing through undetected.

Nobody noticed because no test ever supplied the second set of numbers.

The fix is not a smarter guard — the guard was already correct. It is a missing test, sized to cross the boundary:

expect(expand(length: 90, expansion.length: 20, maxLength: 100)).toStopBeforeExceeding(100)

Correct code passes: 110 > 100, it stops. Mutant fails: 70 > 100 is false, it doesn’t stop — assertion catches it immediately.

That is the point of running it: not to grade the code you just wrote, but to find out which future regressions your tests are blind to, before someone ships one.

Nine mutants tried here, five killed. The four survivors — including this one — are logged with file, line, and the exact assertion needed to close each gap. Not a blocker. A named, tracked debt instead of an invisible one.

A security fix nobody can verify keeps working isn’t done — it’s just untested. Where would a mutant survive in your suite?

#MutationTesting #SoftwareTesting #AIEngineering #DevTools

### Attachments

- Needs a screenshot of the ticket's Mutation Report tab (killed vs. surviving mutants table) saved to `posts/images/t-9cc0-mutation-report-table.png` before posting — not yet captured.

---

## Post 6 — Constraints need authority

**Status:** Draft
**Date:** 2026-07-31
**Format:** Standalone LinkedIn post
**Source:** Response to Addy Osmani's post about setting constraints around software agents
**Core hook:** Constraints are not guardrails around an agentic system. They are part of its architecture.
**Attention GIF:** `posts/images/agent-constraints-exit-gate.gif` — upload first and place below the hook.

### Copy/paste into LinkedIn

Constraints are not guardrails around an agentic system.

They are part of its architecture.

Addy Osmani is right: as code generation outruns our ability to read every line, quality has to move into the harness around the agent.

I would add one boundary from building canon: a constraint is only as real as the state transition it controls.

A test can exist and still be ignored. A checklist can become ceremonial. An evaluation written by the same agent can inherit the same assumption that produced the bug.

So canon separates the roles:

• The producing agent proposes the change.
• Acceptance criteria define what must be true.
• A fresh evaluator checks the artifact and evidence.
• A mechanical close gate decides whether the repo may advance.

The agent does not get to turn a red check green by explaining itself more fluently.

That is the architectural shift: quality policy becomes executable authority. Back-pressure is no longer advice around the workflow; it is a property of the workflow.

Where in your agentic system does a failed constraint actually stop the state transition?

#AgenticCoding #AIEngineering #SoftwareArchitecture #SoftwareQuality

### Attachments

Upload separately:

1. `posts/images/agent-constraints-exit-gate.gif` — illustrative attention GIF; place it immediately below the opening hook.

---

## Post 7 — The gate that won't close itself

**Status:** Draft
**Date:** 2026-08-01
**Format:** Standalone LinkedIn post
**Source:** Ticket `t-2ae2` close attempt
**Core hook:** All three evaluator attempts were spent, the work was correct, and the ticket still would not close on its own.

### Copy/paste into LinkedIn

All three evaluator attempts on this ticket were spent. The final one passed every check except a single result label — which was then fixed.

The work was done. The gate still would not close on its own.

Here is what canon did instead of quietly finishing anyway:

• It stopped and named the exact constraint: sprint policy caps evaluator attempts at three, and all three were consumed.
• It pointed at the exact file and field: `.tickets/t-2ae2/ticket.md`, `eval_override: false`.
• It asked a human to flip that field to `true` — not itself.
• It waited for an explicit `y` before recording the override, finishing the artifacts, closing the ticket, and pushing.

No amount of the agent explaining that the fix was trivial changes who is allowed to grant that exception. `eval_override` is a documented, human-only field. The agent can propose the case for an exception. It cannot write itself the permission slip.

That is the boundary that matters more than the bug: a fluent, correct-sounding "this should be fine, let me just close it" is exactly the failure mode a mechanical gate exists to stop. The interesting part isn't that the check failed — checks fail. It's that the system had no path to close without a human decision landing in the file, on the record, with a reason attached.

Where does your agentic workflow draw the line between "the agent can propose an exception" and "the agent can grant one"?

#AgenticCoding #AIEngineering #SoftwareEngineering #DevTools

### Attachments

- `posts/images/t-2ae2-eval-override-request.png` — evidence screenshot from the actual session showing canon requesting the human-only `eval_override` edit before it would close the ticket.

---

## Post 8 — Chain-of-thought is not self-review

**Status:** Draft
**Date:** 2026-08-04
**Format:** Standalone LinkedIn post
**Source:** Emergent-behavior chain-of-thought slide (standard vs. CoT prompting) mapped to canon's fresh, independent evaluator
**Core hook:** Chain-of-thought taught models to show their work. Nobody told them to stop grading their own homework — straight A's, every time.
**Attention GIF:** `posts/images/cot-independent-eval.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

Chain-of-thought taught models to show their work. Nobody told them to stop grading their own homework — straight A’s, every time.

Chain-of-thought is a genuine breakthrough. Ask a model to show its steps — “5 balls, 2 cans of 3, so 5 + 6 = 11” — and it stops guessing and starts reasoning. Accuracy jumps on exactly the problems a bare answer gets wrong.

But look closely at what you are trusting. That chain of thought is written by the same model that is about to act on it. And a chain of thought can be fluent, well-structured, and completely wrong — every step following cleanly from the last, arriving with total confidence at the wrong answer.

That is the trap: the reasoning reads correct to the one who wrote it. So when the same agent reviews its own chain, it inherits the exact assumption that produced the error — and signs off.

canon adopts the other half of the idea. The chain of thought stays; every step an agent takes is reasoning. What canon refuses is letting that reasoning grade itself.

Before a unit of work can close:

• A fresh evaluator — Read and Bash only, no memory of having built it — grades each acceptance criterion against the actual code.
• It re-derives every number independently instead of trusting the stated one.
• Every verdict carries a file:line citation.
• A mechanical gate blocks the close until the evaluator passes. The agent cannot explain a red check green.

The shift is small but structural. Chain-of-thought shows why you want an agent to reason out loud. Independent evaluation exists because reasoning that looks right is not the same as reasoning that is right.

“The steps check out” is a claim. Like “the tests pass,” it needs its own evidence — produced by something that did not write the steps.

Where in your agent workflow does the thing that did the reasoning also get to certify it?

#AgenticCoding #AIEngineering #ChainOfThought #SoftwareEngineering

### Attachments

Upload separately:

1. `posts/images/cot-independent-eval.gif` — illustrative attention GIF; the producing agent's chain of thought on the left, a fresh independent re-check (magnifier + verdict) on the right, split by a “no shared memory” divider. Place it immediately below the opening hook. Decorative, not evidence.

---

## Post 9 — Showcase: two commands, plan → close

**Status:** Draft
**Date:** 2026-08-04
**Format:** Standalone LinkedIn post
**Source:** canon README (positioning + “The Two Commands”) and the sprint lifecycle (OPEN → IN PROGRESS → EVAL GATES → CLOSED)
**Core hook:** Two commands and a local board — your agent plans in the repo, and a second agent with no memory of building it checks the work.
**Attention GIF:** `posts/images/canon-sprint-lifecycle.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

Two commands. One local board. Your agent plans in the repo — and a second agent checks its work.

That is canon.

sprint start “add OAuth login” — the agent writes a ticket, acceptance criteria, and a plan before it touches code. The ticket opens.

Then it builds. In progress.

sprint complete — a fresh evaluator, Read and Bash only, with no memory of having built it, grades every acceptance criterion against the actual code, with a file:line citation per verdict. A mechanical gate refuses to close while any acceptance box is unchecked or the eval verdict isn’t “pass.”

The eval gates pass. The ticket closes.

The point is not the board. It is this: the agent that wrote the code is the worst possible reviewer of it. canon makes self-review structurally impossible — and keeps the plan, the decisions, and the acceptance bar in your repo, not your prompt history.

Local-first. No SaaS, no account. The work is already in your repo.

What does your workflow keep after the agent says “done” — more code, or the context to trust it?

#AgenticCoding #AIEngineering #DevTools #SoftwareEngineering

### Attachments

Upload separately, in this order:

1. `posts/images/canon-sprint-lifecycle.gif` — illustrative attention GIF; one ticket card travels OPEN → IN PROGRESS → EVAL GATES → CLOSED, with the `sprint start` / `sprint complete` triggers and the review/evaluator/acceptance gates ticking green before close. Place it immediately below the opening hook. Decorative, not evidence.
2. `posts/images/sprint-check-board-live.png` — grounded evidence: a real `sprint-check` board (OPEN / IN PROGRESS / DONE / DISCARDED columns, live ticket counts, current focus, and the "Ready to close" search). Save the live screenshot to this exact path before posting; do not substitute an illustration. Upload after the GIF so the animation is the scroll-stopper and the real board is the proof.

---

## Post 10 — The Gang of Four, re-graded for agentic systems

**Status:** Draft
**Date:** 2026-08-09
**Format:** Standalone LinkedIn post
**Source:** DigitalOcean's GoF catalog (23 patterns) mapped against the current agentic-pattern landscape (Ng's four core patterns; Anthropic's workflow patterns; 2025-26 memory/guardrail/trajectory patterns)
**Core hook:** The Gang of Four wrote their patterns for objects that do exactly what you call them. Agentic systems broke that assumption — so which of the 23 still earn their place?

### Copy/paste into LinkedIn

The Gang of Four wrote their 23 patterns in 1994 for objects that do exactly what you call them. Agentic systems break that assumption. The actor is now a probabilistic model that picks its own next move, so the patterns that manage interaction, access, and recoverable state matter more than the ones that manage object creation.

I went through all 23 against how agents are actually built today. Here is where they land.

Still load-bearing (these map the hardest):

• Command — every tool call is a request turned into an object: structured, logged, queued, replayable. It is what makes trajectory replay and undo possible.
• Strategy — model, tool, and route selection. Swap the planner or the model without touching the agent loop.
• Chain of Responsibility — layered guardrails at input, tool call, tool response, and final output, then escalation to a human.
• Observer — streaming tokens, callbacks, hooks, trajectory logging. Everything downstream reacting to what the agent emits.
• Memento — memory and checkpoints. Snapshot state so a run resumes after a context reset instead of starting over.
• Mediator and Composite — an orchestrator coordinating worker agents, and a supervisor tree you can treat as a single agent.
• State — plan, act, observe, reflect is a state machine, including the wait state for human approval.
• Proxy and Decorator — sandboxed, rate-limited tool access, wrapped with retries, validation, and tracing.
• Adapter and Facade — MCP is Adapter at scale: one clean tool interface over many messy APIs.

Quietly everywhere, as plumbing: Factory, Builder, Singleton, Iterator, Template Method, and Bridge. They instantiate agents and tools, assemble the context window, share one model client, stream results, run the fixed loop skeleton, and keep policy independent of the model provider.

Fading: Flyweight survives mostly as prompt and KV-cache reuse. Interpreter, Visitor, and Prototype rarely earn their keep unless you are parsing a DSL or walking a trajectory tree.

One caveat worth stating plainly: these are analogies, not equivalences. The classic patterns assume a deterministic actor and a known control path. Agents decide at runtime, which is exactly why the behavioral patterns around control, access, and recoverable state carry the most weight now.

It is also why the pattern I keep reaching for while building canon is one the Gang of Four never needed: a check the actor cannot grade for itself. Command, Memento, and Chain of Responsibility give you tool calls, durable state, and layered gates. None of them stop the thing that did the work from certifying it.

Which GoF pattern do you reach for most in agent work, and which one finally stopped being useful?

#AgenticAI #AIEngineering #SoftwareArchitecture #DesignPatterns

### Mapping table (editorial reference — not for the composer)

LinkedIn's basic composer does not render Markdown tables; a pasted table shows up as raw pipes. Keep this table here as the source of record. To show it visually on LinkedIn, export it as a single image or a short carousel (see Attachments) and paste the narrative above as the post body.

Fit = how adaptable and important the pattern is in current agentic systems.

| GoF pattern | Category | Maps to in agentic systems | Fit |
|---|---|---|---|
| Command | Behavioral | Tool/function call as a structured object: logged, queued, undoable, replayable — the basis of trajectory replay | Very high |
| Strategy | Behavioral | Interchangeable model / tool / planner selection; routing | High |
| Chain of Responsibility | Behavioral | Guardrail layering (input → tool call → tool response → output) and fallback/escalation to a human | High |
| Observer | Behavioral | Token streaming, callbacks, hooks, trajectory logging; reactive UIs | High |
| Memento | Behavioral | Checkpoints and memory snapshots; save/restore for resumable runs | High |
| Mediator | Behavioral | Orchestrator coordinating worker agents; inter-agent message bus | High |
| State | Behavioral | plan/act/observe/reflect loop and ReAct; the human-approval wait state | High |
| Template Method | Behavioral | Fixed agent-loop skeleton with pluggable steps; workflow shapes | Medium-high |
| Iterator | Behavioral | Streaming responses, paginated tool results, iterating retrieved chunks | Medium |
| Interpreter | Behavioral | Parsing structured output, tool schemas, or a DSL (constrained decoding) | Medium |
| Visitor | Behavioral | Operations over a trajectory, plan tree, or AST without changing it | Low-medium |
| Adapter | Structural | Wrap heterogeneous APIs behind one tool interface; MCP at scale | High |
| Facade | Structural | A simple tool/skill surface over a complex subsystem | High |
| Proxy | Structural | Guarded tool access: sandboxing, rate limits, auth, lazy/remote calls, logging | High |
| Decorator | Structural | Wrap a tool/agent call with retries, validation, guardrails, caching, tracing | High |
| Composite | Structural | Supervisor / sub-agent trees; treat a team of agents as one | High |
| Bridge | Structural | Decouple reasoning policy from the model/provider so either can change | Medium-high |
| Flyweight | Structural | Share immutable data across calls: shared system prompt, prompt/embedding/KV-cache reuse | Medium (cost lever) |
| Builder | Creational | Assemble prompts and the context window step by step (context engineering) | High |
| Factory / Abstract Factory | Creational | Instantiate agents, tools, and model clients by role or provider | Medium (plumbing) |
| Singleton | Creational | One shared model client, config, or memory store — with the usual shared-mutable-state caveats | Medium |
| Prototype | Creational | Clone an agent config or few-shot template to spawn a sub-agent | Low |

### Attachments

LinkedIn will not render a Markdown table inline, so the mapping ships as images. Pick one:

Option A — single image (desktop-friendly, full table):
1. `posts/images/gof-agentic-mapping-table.png` — all 22 patterns with color-coded Fit ratings (3200×2600).

Option B — 3-slide carousel (mobile-friendly; recommended, grouped by tier):
1. `posts/images/gof-agentic-carousel-1.png` — Still load-bearing (1080×1350).
2. `posts/images/gof-agentic-carousel-2.png` — Quietly everywhere / plumbing.
3. `posts/images/gof-agentic-carousel-3.png` — Fading + the check the actor cannot grade itself.

Rendered from the editorial table via headless Chrome at 2×; regenerate from that table if the mapping changes.

---

## Post 11 — Everyone is optimizing the agent. Move the memory out of it.

**Status:** Draft
**Date:** 2026-08-09
**Format:** Standalone LinkedIn post
**Source:** Author's thesis on the current agent-tooling discourse (Pi/Codex/Claude, token reduction, CLAUDE.md/AGENTS.md tuning, minimalism) missing the layer canon targets — durable, portable, repo-native memory outside the agent
**Core hook:** Everyone is optimizing the agent. Almost no one is moving what the model needs out of it.
**Attention GIF:** `posts/images/memory-outside-agent.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

Everyone is optimizing the agent. Almost no one is moving what the model needs out of it.

The whole conversation right now is about the tool. Which one burns fewer tokens. Whether Pi's minimalism beats Codex or Claude Code. How to trim your CLAUDE.md or AGENTS.md so the model behaves. These are real questions, and they all aim at the same layer: the inside of the agent.

That is the wrong layer to fight on.

Here is the failure almost no one names. The plan, the decisions, the acceptance bar, the reason you rejected an approach three sessions ago — most of that lives in the conversation. So every context reset re-derives it, every long thread re-reads it, and every new tool starts from zero. That is what actually compounds your cost and your unreliability. Not the system prompt. The fact that the memory is trapped inside a disposable thing.

The lever is to move it out. In canon, the durable artifacts live in the repo, not the chat:

• the plan and the alternatives that were rejected
• the decisions and why they were made
• the acceptance bar the work is graded against
• a handoff the next session reads back in

Plain text, in the repo. Which makes it portable: a fresh Claude, a Codex run, or Pi all read the same thread. The agent is disposable. The memory is not.

The payoff is not cosmetic. When the context lives outside the agent, the model stops regurgitating what it already established, a compaction stops erasing the thread, and switching tools stops meaning starting over.

Trim your CLAUDE.md, sure. That is housekeeping at the front desk. The real question is whether anything survives once you close the session.

What does your workflow keep after the agent forgets — the code, or the reasoning that produced it?

#AgenticAI #AIEngineering #ContextEngineering #DevTools

### Attachments

1. `posts/images/memory-outside-agent.gif` — engaging attention GIF (720×405, ~1.9s loop). A cartoonish agent 🤖 whose memory bubble is wiped by a "CONTEXT RESET" banner, while the repo box (PLAN · DECISIONS · HANDOFF) glows and hands the page back; a Claude/Codex/Pi badge row highlights each in turn to show any tool reads the same repo. Upload first and place immediately below the opening hook. Decorative, not evidence.

---

## Post 12 — Honey, I shrunk the doc

**Status:** Draft
**Date:** 2026-08-10
**Format:** Standalone LinkedIn post
**Source:** Author's canon session — a real prose-compression of a review-gate doc that passed word count, grep, the test suite, and a doc-parity check but silently narrowed a rule; caught only by a fresh-context semantic diff (the repo-workflow-audit skill's mandated compression check).
**Core hook:** Honey, I shrunk the doc. I cut a review gate's instructions by a quarter and kept every rule. Or so all my checks told me.
**Attention GIF:** `posts/images/diff-verify-catch.gif` (primary) or `posts/images/shrunk-doc-shrinkray.gif` (playful shrink-ray alternate). Pick one; upload first and place immediately below the hook.

### Copy/paste into LinkedIn

Honey, I shrunk the doc.

I cut a review gate's instructions by a quarter and kept every rule. Tests passed, grep matched, the linter was clean. All of that was true, and I was still wrong.

I was tightening the instructions for a review gate. Word count went from 174 to 127. A grep for the load-bearing quote still matched. The full suite was green. Every check I had said ship it.

Then a second reader, with no memory of my edit, put the old text next to the new one and read line by line. It caught what none of my checks could: I had quietly shrunk a rule too. The original told the gate not to treat “compaction or a context reset” as done. My tighter version kept “compaction” and lost “or a context reset.” The doc came back the right size. One of its rules didn’t come back at all.

Here is the trap. Every check I ran tests the shape of the text:

• word count tells you it got shorter, not what got shorter
• grep confirms strings you already thought to look for
• the test suite never runs a paragraph of prose

The defect was an absence. You cannot grep for a sentence that is gone. You would have to already know it was supposed to be there.

So match the checker to the way it can fail:

• behavior changed? run a test
• a known string changed? grep, or a parity check
• meaning in prose changed? have something that understands both versions compare them

Compression is the sharp case, because its whole job is fewer words, same meaning. The one defect it can introduce is a meaning that quietly left, and that is exactly what byte-level checks miss. It also has to be a fresh reader. The person who wrote the shorter version already believes it kept everything, so they read the old intent back into the thinner text. Someone with only the two versions and no story cannot paper over the gap.

“I only shrunk the prose” is a claim. It needs its own evidence.

What in your process would catch a rule that got quietly narrower while every test stayed green?

#AIEngineering #AgenticAI #TechnicalWriting #CodeReview #DevTools

### Attachments

Use exactly one GIF (skill rule: one GIF per standalone post). Both are 720×405, loop, decorative (not evidence). Upload first and place immediately below the opening hook.

1. `posts/images/diff-verify-catch.gif` (primary) — a checklist of mechanical checks (word count 174→127, grep, test suite, doc-parity) turns all green with an “LGTM” pill, then a “semantic diff · fresh context” panel reveals the line “Compaction or a context reset is not a completion signal” with “or a context reset” struck out and stamped “DROPPED,” closing on “The doc came back the right size. One rule didn’t come back at all.”
2. `posts/images/shrunk-doc-shrinkray.gif` (playful alternate) — leans into the movie gag: a shrink-ray “ZAP!” hits a `gate-protocol.md` card (174 words, three rules); the doc shrinks to 127 words while the rule “…or a context reset” is left behind at full size, stamped “DROPPED · left at full size,” closing on “The doc shrank. One rule didn’t make it back. A fresh reader caught it.”

---

## Post 13 — Five GoF patterns we didn't set out to use

**Status:** Draft
**Date:** 2026-08-14
**Format:** Standalone LinkedIn post
**Source:** `standards/agent-design.md`, "Pattern Vocabulary (recognize, don't prescribe)" — canon's own architecture rules (Own Your Control Flow, Own Your Context Window, Agent as Stateless Reducer) mapped against five GoF patterns.
**Core hook:** We wrote down how canon actually works. Five Gang of Four pattern names showed up in the description, uninvited.
**Attention GIF:** `posts/images/gof-canon-pattern-vocabulary.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

We wrote down how canon actually works. Five Gang of Four pattern names showed up in the description, uninvited.

Canon has a standing rule against pattern-first design: recognize a pattern where one already fits, never introduce a class because a famous name exists for it. So when we documented canon's own control-flow rules, we didn't go looking for GoF. We just noticed the vocabulary already mapped.

• Command — a tool call is a request object: name and args, decoupled from execution. Gate it before it runs, make it idempotent, log it. Every other rule composes on top of this one.
• Chain of Responsibility — the guardrail pipeline. Each step handles the request or passes it on, and one terminal handler can stop the chain.
• Mediator — an orchestrator that coordinates subagents so they never couple to each other directly.
• Memento — the serialized event log. State lives outside the agent, so any point in a run can be resumed or forked.
• Flyweight — the shared, immutable context prefix reused across many fine-grained calls. Prompt caching and subagent fan-out are this, at the cost/latency layer.

None of these live in canon's code as a class literally named Command. They show up at the protocol level, because the actor issuing the calls is a model that decides its own next move, not code that dispatches to a known path.

The rule underneath the mapping matters more than the mapping itself: use the vocabulary to reason about the architecture, not to justify adding a class. If a plain function does the job, the pattern doesn't earn a place just because it has a name.

Which of these five did you already have in your agent's architecture before you had a word for it?

#AgenticAI #SoftwareArchitecture #DesignPatterns #AIEngineering

### Attachments

1. `posts/images/gof-canon-pattern-vocabulary.gif` (primary, decorative) — cartoonish card-reveal loop: title card, then five color-coded pattern cards (Command, Chain of Responsibility, Mediator, Memento, Flyweight) popping in one at a time with a one-line agentic realization, closing on "Not a mandate. A vocabulary for reasoning." 720×405, loops. Upload first, place immediately below the opening hook.

---

## Post 14 — The sprint that closes doesn't get to keep its own lesson

**Status:** Draft
**Date:** 2026-09-11
**Format:** Standalone LinkedIn post
**Source:** `tkt learn` / `learnings.md` mechanism (`skills/sprint/reference/complete.md`, `standards/ticket-layout.md`), real generated candidate for ticket t-f835; `learnings-sweep` skill + root `LEARNINGS.md` index (`skills/learnings-sweep/SKILL.md`, ticket t-1e8a, 2026-09-11)
**Core hook:** A sprint closes. The findings that surfaced during it usually close with it. `tkt learn` writes them down instead — and won't let the builder be the one who decides they're worth keeping. A second piece closes the other gap: a lesson filed alone in a ticket folder is easy for the next sprint to never see.
**Attention GIF:** `posts/images/learnings-md-promote.gif` — **needs regeneration** to reflect the update below; spec revised, asset not yet re-rendered. Upload first and place immediately below the hook.

### Copy/paste into LinkedIn

A sprint closes. The findings that surfaced during it usually close with it. `tkt learn` writes them down instead, and it won't let the builder decide they're worth keeping.

At close, canon can distill a sprint's deviations and evaluator findings into `learnings.md`, marked UNPROMOTED. It says so on the file itself:

"A reviewer without this sprint's implementation history promotes any keeper into the project's durable store. The sprint author must not self-promote."

On a real ticket, that file caught something genuinely subtle: a changed-file diff that raced a concurrent merge to origin/main mid-eval, silently going empty. Worth keeping. Not something the builder gets to declare worth keeping.

But a candidate sitting alone in `.tickets/t-f835/` is easy to never see again. A new skill, `learnings-sweep`, rolls every open candidate into one capped, always-current `LEARNINGS.md` at the repo root — read at the start of every sprint, before a line of code changes. The builder still can't promote their own lesson. Now the next builder can't quietly skip past it either.

It's a nudge, not a gate. Nothing blocks the ticket from closing without it, and it can be deleted and regenerated. But the asymmetry is deliberate: the one who wrote the code isn't the one who decides what the codebase learns from it — and the codebase doesn't get to forget just because nobody went looking.

What promotes a lesson into your team's docs — a person with no stake in the sprint, or the same one who just closed it? And once it's written, does anything make sure the next person actually reads it?

#AgenticCoding #AIEngineering #SoftwareEngineering #DevTools

### Attachments

1. `posts/images/learnings-md-promote.gif` (primary, decorative) — **spec updated, asset needs re-render.** Three-beat loop: (a) a builder bot and a pulsing `learnings.md · UNPROMOTED` card on the left; (b) the card feeds into a compact `LEARNINGS.md` table at repo root — one row lighting up, a small "read at every sprint start" tag pulsing beside it; (c) a fresh reviewer's `canon-learnings.md` folder lighting up green with a checkmark on the right. Dashed "must not self-promote" divider spans (a)→(c), unchanged from the original. 640×360, loops.
2. `posts/images/t-f835-learnings-candidate.png` (evidence) — real generated `learnings.md` candidate for ticket t-f835, showing UNPROMOTED status and the evaluator's disclosed findings. Unchanged.
3. *(optional new)* A screenshot or crop of the real root `LEARNINGS.md` table (3 seeded rows: t-96a8, t-ddc8, t-4d26) as second-piece evidence, same spirit as #2.

---

## Post 15 — The daemon that quietly drifts

**Status:** Draft
**Date:** 2026-09-10
**Format:** Standalone LinkedIn post
**Source:** canon cockpit-daemon work (tickets t-44d9 / t-b421 / t-9745 / t-fc91), sidebar daemon health control + graceful restart
**Core hook:** Long-lived agent processes have a quiet failure mode: they drift, and nothing tells you.
**Attention GIF:** `posts/images/daemon-drift-restart.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

Long-lived agent processes have a quiet failure mode: they drift.

You pull a new build, but the daemon that has been running your coding agent all afternoon is still on the old code, and nothing tells you.

canon runs the agent inside the board, in an embedded terminal owned by a small local daemon, so a refresh never kills a running agent. But that daemon can go stale, and on macOS the only "is this current?" signal is the binary's file time. canon's binaries are gitignored, so even that isn't reliable. The daemon serves old behavior and still looks fine.

So I stopped chasing perfect detection and made recovery cheap and safe:

• A health dot on the board: green when current, red when drifted, with the live count of running sessions.
• Restart is always one click, detected or not. You never depend on the signal.
• It restarts gracefully, reaping the agent's child processes so nothing is orphaned. Live session? It names the count and asks first.

The lesson: when a status signal is unreliable, don't hide the fix behind it. Make the fix always available, make it safe, and put the state where people already look.

How do you catch a background process that has quietly drifted out of sync with your code?

#AgenticCoding #DevTools #AIEngineering

### Attachments

1. `posts/images/daemon-drift-restart.gif` — decorative attention GIF: the cockpit daemon runs healthy (green), drifts out of date (red) with a Restart button, then one restart brings it back to healthy. Place immediately below the hook. Illustrative, not evidence.

---

## Post 16 — More agents need more proof

**Status:** Draft
**Date:** 2026-09-16
**Format:** Standalone LinkedIn post
**Source:** Response to Tim Scheuer's post on becoming an AI-native SaaS; canon workflow described in `README.md`
**Core hook:** More tokens buy attempts. More agents buy throughput. Neither one makes “done” trustworthy.
**Attention GIF:** `posts/images/ai-native-proof-loop.gif` — upload first and place immediately below the hook.

### Copy/paste into LinkedIn

More tokens buy attempts. More agents buy throughput. Neither one makes “done” trustworthy.

The stack in this post makes sense: subscriptions, enough compute to let agents work, and tools that let them act across the business.

I would add one more layer: proof.

When 25 agents run overnight, the morning problem is not only “what did they do?” It is “which of these changes earned trust?”

That is the part canon is built for:

• Capture intent and acceptance criteria before the change.
• Let the agent work.
• Have a fresh evaluator check the artifact against the criteria before it can close.

Otherwise, more agents can just mean more confident status updates by breakfast.

What makes an agent's “done” independently checkable in your stack?

#AgenticCoding #AIEngineering #DevTools

### Attachments

Upload separately, in this order:

1. `posts/images/ai-native-proof-loop.gif` — decorative cartoon-style attention GIF: a four-step canon workflow shows planned intent and criteria, the agent's change, a fresh evaluator's check, and a close gate that opens only on pass. Place immediately below the opening hook. Illustrative, not evidence.
2. `posts/images/ai-native-layers-source.png` — grounded evidence: supplied screenshot of Tim Scheuer's original LinkedIn post. Preserve as-is and upload after the GIF.

---

## Reply 1 — When “it runs” is not enough

**Status:** Draft
**Date:** 2026-07-30
**Target:** Reply to Daniel Hofman's post about AI-written code and commit-time review
**Format:** LinkedIn comment
**Core point:** Canon treats “done” as a verification problem, not a confidence claim.

### Copy/paste into LinkedIn

Exactly. The key shift is moving trust from the quick read to the commit boundary.

That is what I am trying to build with canon: the agent can write and explain the change, but it does not get to certify its own work. Acceptance criteria, a fresh-context review, and close gates check the actual state before anything moves forward.

“It runs” is a useful signal. “I know this is right” requires a second look.

Fast is good. Fast with evidence is better.

---

## Reply 2 — Model choice follows impact

**Status:** Draft
**Date:** 2026-07-30
**Target:** Reply to Alexandrie Maheu's question on Kartik C.'s post about multi-model workflows
**Format:** LinkedIn comment
**Core point:** Model selection should follow the impact of the decision, not just the task label.

### Copy/paste into LinkedIn

That is the right question — especially in a classified environment. In canon, model choice follows the impact of the decision, not just the task label.

Bounded exploration can use Haiku. Implementation can use Haiku or Sonnet. Judgment-heavy review uses the strongest review tier. A low-risk docs or skills diff may qualify for a Haiku close gate, but broader, security-sensitive, or high-impact changes stay on the full review path.

The ticket records the selected model, and the evaluator report records what actually ran.

The goal is not to pretend latency and security are free. It is to make the tradeoff explicit — and keep the cheaper path from being used where a wrong answer has a bigger blast radius.

---

## Reply 3 — Superlogical announcement

**Status:** Draft
**Date:** 2026-07-30
**Target:** Comment on Mitchell Hashimoto's Superlogical announcement
**Format:** LinkedIn comment
**Core point:** A terminal multiplexer for all work raises interesting questions about context, isolation, and observability.

### Copy/paste into LinkedIn

Congratulations — “a terminal multiplexer for all work” is a compelling foundation.

The architecture question I’m most curious about is how you preserve context, isolation, and observability as the multiplexer spans agents, tools, and long-running workflows.

Excited to see what you build.

---

## Reply 4 — Close gates are a separate state transition

**Status:** Draft
**Date:** 2026-07-30
**Target:** Reply to Daniel Hofman's comment about fresh-context review and close gates
**Format:** LinkedIn comment
**Core point:** Canon treats “done” as an evidence-checked state transition, not the agent's final summary.

### Copy/paste into LinkedIn

That is exactly the piece I care about.

In canon, close is a separate state transition, not the agent’s final paragraph: acceptance criteria and QA must be checked, a fresh evaluator grades against them, and the gate checks the actual report and runner state.

A failed or not-run check does not become green because the model explains it. Even an exception requires a dated, human-approved override in the ticket.

The agent can propose “done.” The close gate decides whether the repo has earned it.

---

## Reply 5 — The evaluator is the hard gate

**Status:** Draft
**Date:** 2026-07-30
**Target:** Reply to Daniel Hofman's follow-up about adversarial evaluation and reviewer independence
**Format:** LinkedIn comment
**Core point:** Canon separates an advisory colleague review from the binding, fresh-context evaluator.

### Copy/paste into LinkedIn

Yes: the adversarial evaluator is the hard gate.

A colleague reviewer can return NO, but that finding is advisory. An evaluator fail — including a partial or not-run check — blocks close unless a human records a dated override in the ticket.

Both passes stay cold. The reviewer sees the agreed plan, acceptance criteria, and diff, not the implementer's history. The evaluator gets a fresh context too; it does not inherit the reviewer's suspicions. That keeps the second judgment independent instead of turning it into confirmation.

If evaluation fails, the workflow fixes the artifact and reruns a fresh evaluator. It does not ask the two reviewers to debate their way to green.

---

## Reply 6 — Assurance becomes the product

**Status:** Draft
**Date:** 2026-07-30
**Target:** Reply to Yavuz Özsöz's post about AI-generated code and assurance artifacts
**Format:** LinkedIn comment
**Core point:** Canon moves review toward independently checked evidence, while keeping the implementation traceable.

### Copy/paste into LinkedIn

I agree with the direction, with one important distinction: assurance cannot be another summary the same agent generated about its own work.

That is the failure mode canon is designed around. The implementation produces artifacts — acceptance criteria, tests, reports, and a traceable diff — then a fresh evaluator checks those artifacts against the actual change. The evaluator is not asked whether the code looks plausible; it grades whether each promised behavior has evidence.

So the source may become less interesting as something a human reads line by line, but it cannot become irrelevant. It is still part of the evidence trail, and an independent reviewer needs to be able to follow the claim back to the change.

The real shift is from “please review this code” to “here is the claim, here is the evidence, and here is the gate that decided whether it was sufficient.”

---

## Reply 7 — The oracle must sit outside the agent

**Status:** Draft
**Date:** 2026-07-31
**Target:** Reply to Yuri Sa's question about agents gaming tests and the trust threshold for self-merge
**Format:** LinkedIn comment
**Core point:** Canon treats a green check as evidence to challenge, not an oracle the producing agent may define and certify.

### Copy/paste into LinkedIn

That is the oracle problem, and a green check is not automatically a trustworthy one.

Canon addresses it in layers:

• Behavior is approved before implementation. If a scenario leaves a threshold, boundary, or rule unspecified, the agent must surface the gap rather than invent it.
• Bug fixes require an invariant stated independently of the implementation, with hand-computed examples.
• A fresh evaluator rejects weak evidence, including a runner that passes without exercising the changed code.
• Mutation testing deliberately breaks the changed logic. If the suite stays green, the test has no teeth.

The important caveat: mutation proves sensitivity, not semantic correctness. If the acceptance criteria encode the wrong truth, the whole system can still be consistently wrong. Domain truth still has to come from a human, an authoritative source, or another oracle outside the producing agent’s control.

That is also why canon does not currently let agents self-merge. Commit and push remain human-confirmed. A check earns authority only as part of an evidence bundle, proportional to the risk—not merely because it passed.

The threshold I care about is: where did the expected truth come from, and can the producing agent change it?

---

## Reply 8 — The ontology needs an outside checker too

**Status:** Draft
**Date:** 2026-07-31
**Target:** Reply to Helenio Gilabert's post on the semantic mapping layer for agentic AI (Process/Business Ontology, Data Access, Memory, Operational Execution, Self-Improvement Loop)
**Format:** LinkedIn comment
**Core point:** Canon's architecture maps closely to this diagram, with one addition — the self-improvement loop needs a fresh, external check, or it just reinforces its own ontology.

### Copy/paste into LinkedIn

Agreed on the failure mode. An agent without a defined ontology doesn't hallucinate randomly — it hallucinates confidently, using whatever business logic it inferred from the prompt.

Canon's architecture maps onto this diagram closely:

• Process/Business ontology — acceptance criteria written and approved before implementation, so the agent isn't inventing the rule mid-task.
• Memory — ticket state and per-project memory files carry short-term (current sprint) and long-term (prior decisions, gotchas) context across sessions.
• Data access and operational execution — a close gate that checks the actual repo state, not the agent's account of it.

The piece I'd add to the diagram: that self-improvement loop needs an oracle outside the agent core, or it optimizes toward its own definition of correct. In canon, that's a fresh-context evaluator that never sees the implementer's reasoning — only the criteria and the diff — plus mutation testing that breaks the changed logic to check the tests would actually catch a regression.

A semantic layer stops hallucinated business logic. It doesn't stop the agent from silently drifting its own definition of the ontology over time. That still needs a checker that isn't the same agent grading its own homework.

---

## Reply 9 — Externalize intent before the thread degrades

**Status:** Draft
**Date:** 2026-07-31
**Target:** Reply to Kate C.'s post about improving Claude output through positive instructions, bounded threads, and clearer target criteria
**Format:** LinkedIn comment
**Core point:** Canon reduces dependence on a long conversation retaining intent by externalizing positive success criteria, scope, and evaluation.

### Copy/paste into LinkedIn

This is a useful diagnosis. I think canon would have helped one layer upstream—not by finding the perfect prompt, but by reducing how much intent Claude has to hold in the conversation.

For coding work, canon turns the desired outcome into positive, binary acceptance criteria before implementation, then keeps the approved plan and scope in a repo ticket. The chat can compact or restart without asking the model to reconstruct intent from a trail of “don’ts.” It also audits always-on context for bloated, redundant, or stale instructions, and uses a fresh evaluator at the end so the same degraded thread is not grading its own output.

That maps closely to your fix: one bounded goal, an explicit target state, and durable external memory.

I would still treat the explanation of negation as model-specific rather than something canon proves. But canon can make the workflow less dependent on the model retaining conversational intent in the first place.

I’m curious: did the biggest improvement come from positive framing, or from resetting the thread boundary?

---

## Reply 10 — A Skill should be more than a saved prompt

**Status:** Draft
**Date:** 2026-08-01
**Target:** Reply to John Fattal's post about replacing repeated prompts with reusable Claude Skills
**Format:** LinkedIn comment
**Core point:** A reusable Skill becomes a dependable capability when it carries scope, success criteria, and eval cases—not just instructions.

### Copy/paste into LinkedIn

Strong framing. The real leap is not saving prompts—it is turning recurring judgment into a reusable workflow.

A useful Skill should carry more than instructions:

• when it should run—and when it should not
• its inputs, outputs, and scope boundaries
• what success looks like
• eval cases that test the output against known prompts
• how the result is verified before handoff
• durable artifacts another session can inspect

Otherwise, it is still a long prompt with a slash command.

The test I use: can a fresh agent run the Skill against known cases, produce evidence, and have another fresh grader check explicit expectations—without either inheriting the original chat? If yes, you have built a reusable capability rather than a prompt collection.

What do you include in a Skill to keep reuse from becoming stale automation?

---

## Reply 11 — The first rung moved, it didn't disappear

**Status:** Draft
**Date:** 2026-08-01
**Target:** Reply to David Cannode's post on Help Desk as the entry point for IT careers, and AI automating that first rung
**Format:** LinkedIn comment
**Core point:** Automation doesn't remove the entry rung; it moves it from answering the ticket to supervising the thing that answers it — which rewards the same judgment the Help Desk built.

### Copy/paste into LinkedIn

Fifteen years on the support side taught me the ticket was never the point. The judgment was.

Password resets and printer jams were just reps. What they built was the instinct to diagnose, to read the person behind the problem, and to stay calm when everything's on fire. That is the part AI still can't do.

Here is the reframe I've landed on since going deep into AI work: automation doesn't remove the first rung, it moves it. AI can close 100 tickets a day now. What it can't do is know when it's wrong — catch the confident, fluent, completely-wrong answer. And catching that takes exactly the judgment the Help Desk used to build.

So the new entry point isn't answering the ticket. It's supervising the thing that answers it: reviewing the AI's work, spotting where it drifted, owning the call it can't. Lately I've been building around one rule with canon — never let the agent that did the work be the one that checks it. That is a job. It's a rung. And it rewards the same instincts your techs already had.

The door isn't closing. It's changing shape. The real question is whether we're honest enough to train people for the new one.

Where are you seeing that supervision role start to form on your teams?

---

## Reply 12 — Prompt-level rules aren't resource-level enforcement

**Status:** Draft
**Date:** 2026-08-01
**Target:** Reply to Zhirui Luo's post testing whether an AI coding agent could be blocked from modifying a sensitive `.env` file, and the case for resource-level enforcement over tool-level blocking
**Format:** LinkedIn comment
**Core point:** canon doesn't currently do this — it has a static, close-time security-review gate and a prompt-level "don't commit secrets" instruction, neither of which stops a live tool call from reading or writing `.env` mid-session. That gap is exactly what the experiment is pointing at.

### Copy/paste into LinkedIn

Honest answer: not the way your test is checking for. canon has a "never commit secrets or .env files" instruction and a security-review gate that scans the diff before a ticket closes — but both are prompt-level or post-hoc. Neither one intercepts a live Read or Bash call reaching for .env mid-session the way your denial log shows.

That's the distinction your post is making, and it's the right one. A system prompt telling the agent not to touch a file is a request the agent has to agree with every time. Resource-level enforcement — the kind that returns error=True from the tool layer itself, no matter what the agent decided — doesn't depend on the agent agreeing.

The retry behavior in your transcript is the part I'd flag hardest: the agent got denied, then proposed the same outcome through a different channel (hand the user a shell command to do it themselves). That's not a bypass of the restriction, it's the restriction succeeding exactly as scoped — it blocked the tool call, not the goal. Which means the boundary has to be drawn around the resource and the intent, not the specific tool invocation.

Did you test whether the same workaround holds if the retry is a different tool entirely, not just a different command?

---

## Reply 13 — The shared channel has to outlive the conversation

**Status:** Draft
**Date:** 2026-08-03
**Target:** Top-level comment on David Soria Parra's post (Member of Technical Staff @ Anthropic, MCP co-creator) sharing a conversation with Christoph Magnussen about Claude Tag, working with Claude as a colleague with its own access rights working asynchronously across a shared channel, and the roots of MCP
**Format:** LinkedIn comment
**Core point:** A colleague you don't prompt-babysit needs a shared channel that outlives the session; canon puts that channel in the repo (tickets, decisions, handoff) rather than the chat thread. MCP is complementary — it gives the colleague reach; the durable channel makes its work resumable. Boundary: canon does not do MCP or manage access rights.

### Copy/paste into LinkedIn

David Soria Parra The line that stuck with me is "working asynchronously across a shared channel instead of waiting for you to prompt it." That's the real shift — and it quietly raises the bar on where that shared channel lives. If it's the chat window, it dies with the session; a colleague you're not babysitting needs a channel that outlives any single conversation.

That's the layer I've been building canon around: the shared channel is the repo, not the thread. The plan, the decisions, the acceptance bar, and the handoff live in files the next session reads back in — so a context reset, a fresh session, or a different agent entirely picks up the same thread instead of re-deriving it. And because it's a colleague and not a tool, its "done" gets graded by an independent, fresh-context reviewer that never saw the implementation — the colleague can propose done, it doesn't self-certify.

MCP feels complementary to that, not the same layer — it's what gives the colleague reach and access; the durable channel is what makes its work legible and resumable afterward.

In how you work now, is that async channel mostly living in the conversation surface, or in something more durable the colleague reads and writes directly?

---

## Reply 14 — Match the model to the task, but not the model to its own grade

**Status:** Draft
**Date:** 2026-08-03
**Target:** Top-level comment on Scott Thiele's post (EVP & Chief Support Officer) about spending $300 in tokens the first month running a personal AI agent, then cutting cost 75% by matching model to task — a frontier-class model as the cheap primary for interactive work, an expensive model only for hard reasoning, and eleven background tasks moved to a local model — closing with "you cannot optimize AI without understanding how it works, from using it yourself"
**Format:** LinkedIn comment
**Core point:** canon bakes "match the model to the task" in as policy (explore/implement/review tiers), but on the verification step the cheaper model is chosen by a structural read of which files changed, never the agent's judgment of its own work; a deliberately lighter close is a separate explicit human flag. Boundary: canon governs the dev workflow, not calendar/email, and doesn't do the local-model/zero-bill move.

### Copy/paste into LinkedIn

Scott Thiele The line I'd underline is "matched the model to the task" — that's the real optimization, and most people race past it to the token total.

canon (what I've been building) bakes that in as policy instead of a manual habit: read-only exploration runs on the cheap frontier model, implementation on a mid-tier, and only judgment-heavy review runs on the expensive one — the same instinct you arrived at by watching your own bill.

The one place it switches on something other than task type is verification. When work closes, whether the checks get to run on a cheaper model is decided by a structural read of which files actually changed — never by the agent's own judgment of its own work. The thing you're cost-optimizing shouldn't get a vote on how hard it gets checked. Anything a human wants deliberately lighter is a separate, explicit flag on the ticket, on the record — not an automatic shortcut.

Where it stops: canon governs the dev workflow, not your calendar or email, and it doesn't do the local-model, zero-bill move you made for background tasks — that's a real lever I don't touch.

But your closing line is the whole point: the 75% didn't come from a setting, it came from watching where the tokens actually went. Once you started matching model to task, what surprised you more — how much the frontier model was overkill for, or how little genuinely needed the expensive one?

---

## Reply 15 — The code is the truth; the comment is a claim about it

**Status:** Draft
**Date:** 2026-08-05
**Target:** Reply to Andrew Morrell's post about spending an hour fighting AI to test a function before realizing the comment on it was wrong — the AI trusted the comment, assumed the wrong purpose, and never checked it against the actual code; "garbage context in, garbage out," reasoning from a stale CLAUDE.md and comments it wrote itself
**Format:** LinkedIn comment
**Core point:** The failure is treating a description of the code (comment, CLAUDE.md, doc) as authority over the code itself. canon's fresh evaluator grades against the actual code with file:line and re-derives independently; doc-audit flags stale docs one layer upstream. Boundary: it can't stop mid-session trust of a bad comment, and can't fix acceptance criteria that encode the wrong purpose — ground truth must come from outside the producing agent.

### Copy/paste into LinkedIn

The detail that lands: the AI "never once checked the comment against the actual code." That is the whole bug — it treated a description of the code as authority over the code itself. A stale comment, a stale CLAUDE.md, and a doc that no longer matches all fail the same way: the model reasons from what the repo says about itself instead of what it actually does.

That failure mode is the one thing canon is built to refuse. Before work closes, a fresh evaluator — no memory of having built it — grades each acceptance criterion against the actual code with a file:line citation, and re-derives values independently instead of trusting the stated one. A unit test written to satisfy a wrong comment is exactly the test that agrees with itself: it passes and proves nothing. One layer upstream, a doc-audit gate checks whether the docs still describe what is actually there, so the stale comment gets flagged rather than inherited.

The honest boundary: canon cannot stop a model mid-session from trusting a bad comment while it drafts, and if the acceptance criteria themselves encode the wrong purpose, the whole chain can still be confidently wrong — ground truth has to come from a human or a source outside the producing agent. What it does is make sure "done" is checked against the code, not against the code's description of itself.

Curious about your article's angle: when you "feed it the truth," where does that truth live — in the docs the agent also wrote, or somewhere it cannot quietly edit to match its own assumption?

---

## Reply 16 — Guardrails outside the model, a manifest before the build

**Status:** Draft
**Date:** 2026-08-08
**Target:** Reply to Veera Nomula's post, "The Enterprise Agentic AI Blueprint: 8 Core Principles for Production-Grade Multi-Agent Systems"
**Format:** LinkedIn comment
**Core point:** Points 2, 3, and 6 map onto what canon already enforces for coding agents — a mechanical gate instead of a prompt, a ticket as the version-controlled manifest, and approved acceptance criteria as the golden set.

### Copy/paste into LinkedIn

Point 2 is the one I'd underline hardest. A sentence in a system prompt is a specification; a function that runs before the tool executes is a control. That distinction is the whole reason canon exists for coding agents: the agent can propose a fix, but a mechanical close gate (not the agent's own explanation) decides whether the repo may advance.

Point 3 and point 6 map closely to what I've built too. The ticket is the manifest: scope, acceptance criteria, and plan, written and approved before implementation. The acceptance criteria are the golden set. If a scenario leaves a threshold or rule unspecified, the agent has to surface the gap instead of inventing one (the same way your 100-500 adjudicated cases force ground truth into the open before the model gets graded).

The failure mode at the top of your post, autonomy spent where the problem space isn't enumerable, is the same one I keep running into with self-review. An agent that picks its own next step can also decide its own work is done. So canon keeps a fresh evaluator, with no memory of having built the change, checking the artifact against the criteria instead of the same context grading itself.

Which of these eight do teams drop first when the deadline gets tight: the governance budget, or the golden set?

---

## Reply 17 — Delete your CLAUDE.md, then keep auditing it

**Status:** Draft
**Date:** 2026-08-09
**Target:** Reply to Charlie Hills's "Delete your CLAUDE.md" post (Boris Cherny / Anthropic cutting ~80% of the system prompt; audit CLAUDE.md, skills, and hooks; Anthropic's under-200-lines target; lost-in-the-middle)
**Format:** LinkedIn comment
**Core point:** The article's copy-paste audit is exactly what canon's context-doctor skill packages, built from the same Anthropic guidance — with two refinements (never relax a safety rule under the judgment lens; durable memory is not clutter) and an honest live-fetch-vs-baked tradeoff.

### Copy/paste into LinkedIn

This matches what I landed on after six months of the same accretion. The part worth underlining is your discipline, not the deletion: the prompt reads Anthropic's live guidance before it judges a line, and marks what it could not check as NOT RUN. Cite the source or the verdict is KEEP. That is the whole game.

I turned that same audit into a portable skill, context-doctor, built from the same context-engineering guidance behind the 80% cut. Two things I had to add after the first pass, because "delete 80%" can overshoot. It never relaxes a safety rule ("only claim what you verified", "don't commit secrets") under the judgment lens. And it treats a decision log or a handoff file as durable memory, not bloat to cut.

The honest tradeoff against your version: yours re-fetches the live rules every run, so it stays current. Mine bakes the lessons in so it runs offline and repeatably, which means it can go stale if I don't refresh it.

I ran it on my own repo this morning. Verdict: lean, mostly because the one move that actually mattered was retiring always-on imports for on-demand loading. The front desk stopped holding the filing cabinet.

When you re-audit in six months, do you re-fetch the live rules, or trust last run's verdicts?

---

## Reply 18 — Evals and tests check different things, so keep them written by different agents

**Status:** Draft
**Date:** 2026-08-09
**Target:** Top-level comment on Ankur Goyal's post (Braintrust) distinguishing tests ("can the thing work") from evals ("what it can and cannot do, and what it should be doing, how often, and in what circumstances")
**Format:** LinkedIn comment
**Core point:** canon draws the same line from the build side — approved acceptance criteria plus a fresh evaluator answer the eval question, a mechanical test suite answers the test question, and `tkt learn` grows the eval side from what actually happened in a closed sprint instead of only from what the spec anticipated.

### Copy/paste into LinkedIn

Ankur Goyal This is the split I keep re-explaining to people who treat a green suite as proof the agent is doing the right thing. A test tells you the function still returns what it returned yesterday. It has no opinion on whether yesterday's behavior was ever the right behavior.

canon draws the same line from the build side instead of the observability side. Acceptance criteria, written and approved before the agent touches code, are the eval half: what the thing should do, in what circumstances. A fresh evaluator with no memory of having built the change checks the actual code against those criteria and cites file:line for every verdict. The test suite stays separate — it exists to catch regression in what was already specified, not to certify that the specification was right.

Your third bullet is the one that matters most: "what the thing should be doing, how often, and in what circumstances." That can't be graded by the agent whose behavior it's checking. A test written by the implementer inherits the implementer's assumption about correct behavior; an eval meant to catch wrong or novel behavior needs a different author.

The part I'd add: the eval side has to keep absorbing what actually happened, not just what the spec predicted. canon just added a step for this — closing a sprint can distill its deviations and eval findings into an unpromoted eval candidate, proposed but never auto-promoted, so a human still decides what earns a permanent place in the suite.

Where do you draw the line between a behavior worth writing an eval for immediately, and one you wait to see recur before it earns a spot in the suite?

---

## Reply 19 — Move the human to the bar, not the diff

**Status:** Draft
**Date:** 2026-08-10
**Target:** Reply within my own comment thread. A commenter pushed back on a point I made: at large code volume the bottleneck moves from reading code to reading criteria and receipts, which scales far better but not infinitely, and the board's Why mode can query decisions across many tickets. Their objections: review throughput at volume, a true/false receipt hiding the context a change needs (feature-flag analogy), and the human-in-the-loop as a rubber-stamping weak link. Prepend the commenter's @name when posting.
**Format:** LinkedIn comment
**Core point:** The human moves off the per-diff hot path and onto the bar; at volume you query the receipts (board Why mode over a thousand tickets) instead of reading them linearly. A receipt is per-criterion pass/fail with file:line evidence plus a plan-vs-actual table, not a bare boolean, and the context lives in the repo where Why mode reads it back. The anti-rubber-stamp defense is structural: the binding check is a fresh memory-less evaluator and the close is mechanical; the sole override is human-set and audited. It moves the weak link, it doesn't delete it.

### Copy/paste into LinkedIn

You're pointing at the real failure mode, so let me be precise, because this builds on the point I was making.

Start with volume, which was my own point. A lot of code moves the bottleneck from reading code to reading criteria and receipts. That scales far better, but not infinitely, and I won't pretend otherwise. The headroom comes from not reading a thousand summaries in a row. A thousand sprints leave a thousand tickets in the repo, and canon's board has a Why mode that queries them: ask why a file looks the way it does and it pulls the tickets and the decisions behind it. The receipts become searchable memory, not a pile you scroll. Nobody reads the flood, they query it, and the human is off the per-diff hot path, so they aren't the bottleneck a flood overloads.

The feature-flag worry is the sharp one, and I agree with it. A bare true/false hides the context you need. So a canon receipt is not a boolean. Every acceptance criterion gets a pass or fail with a file:line citation, and the close writes a plan-vs-actual table: delivered, waived, deferred, or partial, one row per criterion. The plan, the alternatives that were rejected, and the reason a call was made live in the repo next to the code, and that is exactly what Why mode reads back. The context between true and false isn't stripped off, it's stored and queryable.

On the human being the weakest link, canon assumes you're right. That's why the binding check is a separate evaluator with no memory of building the change, not the human and not the agent that wrote the code, and the close is mechanical: it refuses while any acceptance box is unchecked, the evaluation is missing, or any criterion is partial. The one override is human-set, high-friction, and audited. You can still certify garbage if you set a garbage bar. What goes away is the silent rubber-stamp of a diff nobody checked.

So it doesn't delete the weak link. It moves the human off the per-change treadmill, where volume guarantees rubber-stamping, and onto the bar and the exceptions, where judgment pays off.

If not there, where would you put the human?

---

## Reply 20 — Audit the artifact, not the agent's narration

**Status:** Draft
**Date:** 2026-08-10
**Target:** Reply to a comment (point 4) arguing that capturing only what the agent "chose to write down" is inadequate and increasingly illegal (EU AI Act, California considering similar), with an example of a third-party tool whose self-reported steps ("look at xyz, then abc") don't correlate with its actual output (it really scanned the whole alphabet and answers about ghi). Prepend the commenter's @name when posting.
**Format:** LinkedIn comment
**Core point:** canon deliberately does not treat the agent's self-narration as the evidence. A fresh evaluator with no build history re-derives each verdict from the actual diff and cites file:line, so a trace that doesn't correlate with the output can't produce a passing citation. Honest concession: canon does not capture the raw token-by-token stream (that is a runtime/harness logging layer, below canon, and it does not substitute for a legal behavioral-logging requirement). But a raw trace is a transcript of what the model said, not proof of what it did or that the result is right, while canon's audit object (pre-set bar + independent cited verdict + decisions, in git) is falsifiable against the code. Complementary audits, not the same one.

### Copy/paste into LinkedIn

You're describing the exact reason canon doesn't treat the agent's own account as the evidence. The trace that says “step one, look at xyz; step two, look at abc” and then answers about ghi is a narration, and a narration is a claim about what happened, not proof of it. If that self-report is your audit record, I agree with you completely: game over.

So canon doesn't make it the record. Your example blends two questions that are worth pulling apart.

One is whether the work is correct and grounded. canon answers that from the artifact, not the story. A separate evaluator with no memory of building the change re-derives each verdict from the actual diff and cites file:line for it. A flow that wandered the whole alphabet and then talks about ghi cannot produce a passing citation, because the check runs against the code that shipped, not the steps the agent says it took. The builder's freedom to choose what to write down gates nothing here, because the grader ignores the narration and reads the artifact.

The other is capturing the raw, token-by-token reasoning for a regulator. Let me be straight: canon does not do that and does not pretend to. Full behavioral logging lives in the runtime and the harness, below where canon sits. If the EU AI Act or a California rule wants the raw stream, that is a logging layer you add underneath, and canon is not a substitute for it.

One push back, though. A raw token log is a transcript of what the model emitted, which by your own example is not a reliable record of what it did or whether the output was right. It tells an auditor the model said “xyz, abc” while the answer came from ghi. canon's audit object is a different thing: the acceptance bar set before the code, an independent verdict with file:line evidence, and the decisions, all in git. That is falsifiable against the code. A stream of tokens is not.

So treat them as complementary, not the same audit. Keep the raw log for the regulator if the law demands it. For “is this correct, and can I defend the call in six months,” a bar set up front plus an outside check beats the agent's own transcript of its thinking.

Which audit are you actually being asked for: what the model emitted, or whether the result was right and defensible?

---

## Reply 21 — Portability is not parity: move the yardstick out of the stack

**Status:** Draft
**Date:** 2026-08-10
**Target:** Reply to Matt Boyle's (Head of Product/Design/Engineering at Ona, transitioning to OpenAI) post framing coding agents as a stack — model, harness, execution environment — arguing "portability is not parity" and recommending you benchmark a small set of real repository tasks across model/harness/environment combinations on task completion, corrections required in review, elapsed time, and cost, then make the winners supported defaults.
**Format:** LinkedIn comment
**Core point:** Agree portability isn't parity. Add that his benchmark needs a yardstick that survives the swap: define "done" outside the stack as an acceptance bar written in the repo before the task and graded against the actual diff by something with no stake in the run, so "task completion" and "corrections required in review" are comparable across harnesses instead of each harness measuring with its own review flow. It also outlasts the default choice, since the criteria and the decisions stay in the repo. One light, subtle canon reference.

### Copy/paste into LinkedIn

Matt Boyle “portability is not parity” is the line I'd underline. Same model, new harness, and you've quietly changed approval flows, recovery behavior, observability, and who reviews what. Fully agree.

The part I'd add is that your benchmark needs a yardstick that survives the swap. If you run the same repository tasks across model, harness, and environment combinations, then “task completion” and “corrections required in review” are only comparable when “done” is defined the same way in every combination. Each harness has its own review flow and its own sense of good enough, so measured inside the harness you're holding up three different rulers and calling it one comparison.

What has worked for me is to move the ruler out of the stack. Write the acceptance bar for a task before it runs, as plain criteria in the repo, and have something with no stake in the run grade the actual diff against those criteria. Now “did it clear the bar” and “how many corrections did it take” mean the same thing whether the diff came from Claude Code, Codex, or your own environment. The comparison gets honest because the yardstick didn't move when the harness did.

It also outlasts the choice. When a combination becomes a supported default, the criteria and the reasoning behind them stay in the repo, so the next team inherits the answer instead of rediscovering it. That repo-native bar is the bet I keep building on with canon: the harness is swappable, the standard it gets judged against should not be.

How are you planning to hold “done” constant across the combinations you test, or is each harness's own review the measure?

---

## Reply 22 — Publish the denominator, or "found nothing" hides inside "pass"

**Status:** Draft
**Date:** 2026-08-10
**Target:** Reply to Roman Lobus's post about a structural check that passed on the first attempt because the language extraction silently found zero files, and the three other automated gates (linter, coverage, scanner) he found in the same shape — configured, running, reporting with complete accuracy on nothing at all
**Format:** LinkedIn comment
**Core point:** The empty-set false pass is the same failure as folding "skipped" into "passed" — a check needs a third outcome, not just pass/fail, and it needs to say what it actually looked at. Light, subtle canon reference (no direct pitch).

### Copy/paste into LinkedIn

The line that stuck with me: "pass, fail, and 'I found nothing to examine' are three genuinely different results, and most tooling folds the third into the first."

That is the exact shape of a failure mode I keep designing against from the other side, in review gates rather than extraction. A check that quietly has nothing to check is indistinguishable, from the outside, in a report, from a check that looked hard and found no problems. Both render as a green tick. Only one of them means anything.

The fix you landed on, publish the denominator next to every ratio, is the right one because it turns a silent assumption into a number someone has to own and defend. I've settled on a narrower version of the same idea: a check is only trustworthy if it can say what it actually looked at, not just what it concluded. A gate that ran against zero files and a gate that ran against the real diff should never produce the same-looking line in the same report.

The half hour you'd trade for that is cheap. The alternative is a green tick that has been quietly lying since the day the folder emptied out, and nobody finds out until the day it would have mattered.

Where else have you seen "ran to completion" get treated as proof of "examined something," beyond your own four gates?

---

## Reply 23 — Scope drift on Opus 5 is a known behavior you can pin down

**Status:** Draft
**Date:** 2026-08-20
**Target:** Reply to Michal Mikolajczyk's (AI-Obsessed Quality Engineering Leader) post that Opus 5 feels like it is "devolving" — a tool-benefits question turning into a whole-repo migration, a Jira comment coming back as Markdown instead of Jira markup, the same task failing today after working yesterday, and safety guards blocking dummy-card/register/login testing.
**Format:** LinkedIn comment
**Core point:** The tool-migration and format-swap complaints are the documented Opus 5 scope-expansion behavior (Anthropic's own Opus 5 prompting guide names it), and it responds to an explicit scope-lock instruction plus pinning the output format. The durable fix is to move the scope bar out of the chat into a written, pre-agreed acceptance bar in the repo. Be honest that the safety-refusal half is not a prompt-tuning fix. One light, subtle canon reference (no direct pitch).

### Copy/paste into LinkedIn

Michal Mikolajczyk the part where asking about a tool's benefits turns into a full repo migration is not just you. Anthropic's own Opus 5 prompting guide calls it out: the model will widen or transform a task on its own, adding steps you never asked for. So your hunch that you weren't the problem is at least half right.

The half you can act on: that behavior responds to an explicit scope instruction. Something close to "do exactly what was asked, at the scope intended, and stop short of anything clearly beyond it" reins it in, and naming the exact output format ("Jira markup, not Markdown") kills the format surprises. Vague or implied instructions are where it fills the gap with its own judgment, and Opus 5 fills that gap more eagerly than 4.8 did.

Where I'd push further: retyping that in every prompt is a losing game, because the thread degrades and the model forgets. What has worked for me is to move the scope bar out of the chat. Write down what "done" means before the work starts, keep it in the repo, and treat it as the contract the model is graded against, so it cannot quietly redraw the boundary mid-task. The prompt reminds; the written bar holds.

The safety refusals you hit, dummy cards and login flows, are a different animal and not really a prompt-tuning fix, so I won't pretend the same lever solves those.

When it over-reaches like this, are you correcting it in the next message, or do you keep the intended scope written down somewhere before you start?

---

## Reply 24 — A finding and a recommendation are different artifacts

**Status:** Draft
**Date:** 2026-08-25
**Target:** Reply to Helenio Gilabert's LinkedIn Pulse article "The Age of the Autonomous Industrial Edge" (2026-08-25): enterprise AI shifting from centralized cloud to physics-informed autonomous agents at the industrial edge; separating the reasoning "engine" from specialized "fuel" (knowledge/memory) to prevent hallucination; multi-agent consensus so one failure can't destroy quarterly margins; a packaging-drive thermal-anomaly walkthrough (Maintenance flags heat spike → Quality correlates pressure → Profitability weighs scrap vs stoppage → Risk prices supply-chain penalty → Operations synthesizes a recommendation for a human supervisor); closing claims that "AI does not replace the human; it becomes a continuous extension of their judgment" and that the innovation gap is adoption, not technical (under 20% past pilot). Prepend the author's @name when posting.
**Format:** LinkedIn comment
**Core point:** The article's final step fuses finding and recommendation, which industrial practice separates on purpose — sourced from `~/Developer/office/overtone-app/docs/Engineering-LLM-Output.md`: ISO 14224:2016 (failure record has mode/mechanism/cause/detection and no recommendation field; corrective maintenance is a separate linked record), SAP PM (QMFE/QMUR/QMSM/QMMA), IBM Maximo (Problem→Cause→Remedy distinct from work-order description), ISA-18.2/EEMUA 191 (corrective action in the Master Alarm DB, never in annunciated alarm text). The architectural reason: advice fused into a read-only answer routes around the approval gate, so his own "extension of human judgment" line needs the split to be structural. Grounded in the demo's verified contract (`overtone_demo/agent.py` Answer: `answer` = finding, `recommendation` separate and approval-gated; `governance.py` RBAC viewer/engineer/approver, propose-then-commit-on-approval with an audit line; `conformance.py` rules derived from the schema/RDL). Second point from `canon/docs/retrieval-architecture-playbook.md` (2026-08-21): build-time composition relocates error rather than removing it, a superseded-revision threshold reads as grounded knowledge, and agents sharing one store have correlated errors, so consensus measures cohesion; the counter is load-bearing citations that fail closed (`_doc_line_exists`, `enforce_citations`). Then the compliment from the playbook's Test 3: an externally governed ontology is the strongest signal for the build-time trade and process industry has the best examples, which is why the gate matters more there.
**Editorial:** Tightened from 616 to ~420 words. Cuts held in reserve if a longer version is ever wanted: the ISO 13373-3 Clause 8 counter-case (a vibration-analyst report does recommend, but in its own section after the evidence), the schema-as-code/knowledge-graph build detail, and a closing note that ISO 13379-1 expresses a symptom in five terms, so "flags a heat spike" is one of five.
**Confidentiality:** Internal names (Overtone, Octave, Aria) and the strategy brief are deliberately kept out of the copy block, following the same decision recorded in `posts/CFIHOS_LinkedIn.md`. The demo is described generically, with the synthetic-data and illustrative-CFIHOS-subset caveat stated in the post.

### Copy/paste into LinkedIn

Helenio Gilabert “a model that only understands language is blind to the physical world” is the right diagnosis, and splitting the reasoning engine from the knowledge it runs on is the right response. Where I'd push is the last step of your packaging-drive walkthrough: the Operations Agent synthesizing a recommendation for the supervisor.

That fuses two artifacts industrial practice keeps apart on purpose. ISO 14224:2016 gives a failure record fields for mode, mechanism, cause, and detection method, and no recommendation field at all; corrective maintenance is a separate linked record. SAP PM, Maximo, and ISA-18.2 all draw the same line, down to keeping corrective action out of the annunciated alarm text.

The reason isn't bureaucratic. Advice fused into a read-only answer routes around the approval gate: your supervisor ends up approving a conclusion rather than authorizing a change, and nothing structural stops the next version of the system from acting on it directly. Your closing line, that AI becomes a continuous extension of human judgment, depends on that separation being built rather than intended.

I put a scaled-down version of your architecture on a synthetic plant dataset to test it. The output contract carries finding and recommendation as separate fields, and only the recommendation is approval-gated: a work order is proposed, never created, and it commits on explicit approval from a role holding that right, leaving an audit line with the reason. Concept demo, synthetic data, and an illustrative CFIHOS subset rather than the licensed library.

On hallucination I'd be less optimistic. Moving knowledge into a structured store doesn't remove error, it relocates it: a query-time mistake is noisy and visible in the answer, a build-time mistake is quiet and permanent. A trip threshold lifted from a superseded spec revision won't read as a hallucination to any of your five agents, and because they all draw on the same store, their agreement doesn't catch it. Consensus among agents that share inputs measures cohesion, not correctness. What helped was making citations load-bearing and failing closed: no citation, or one that doesn't resolve to a real document and line, and the answer is marked unverified.

Here you're more right than the article claims. The strongest condition for paying the build-time cost is an ontology that someone else governs and keeps stable, and process industry has the best examples going, CFIHOS and ISA-95 among them. Most enterprise domains can't clear that bar, because their vocabulary is still moving. Yours can, which is exactly why the gate matters more there and not less: schema stability is also what makes a wrong fact permanent.

So, in the architecture you're describing: what fails when the knowledge store is confidently wrong?

---

## Reply 25 — Telling a session isn't the same as blocking the write

**Status:** Draft
**Date:** 2026-09-01
**Target:** Top-level comment on Christopher Kouzios's post about two consecutive Claude Opus 5 sessions going rogue: he asked the offending session to write an analysis of its own failure, had GPT independently gap-analyze that analysis (which omitted key elements), then explained the failure to yesterday's Opus session so it wouldn't recur — and the next session modified the same governed file anyway, reproducing the pattern. He has since dropped Fable AI and Opus and is running on Sonnet.
**Format:** LinkedIn comment
**Core point:** Explaining the incident to a session, fresh or not, is a conversational instruction, not a control, and the retry recreating the pattern proves it. Lays out concrete steps: grade the failure with something that didn't write it, stop treating an explanation as a fix, name the exact file/operation, move the block to the tool layer, verify the block itself, then use a fresh agent for retries as a second layer, not a substitute.

### Copy/paste into LinkedIn

Christopher Kouzios The retry proved the real problem: explaining the incident to a session, fresh or not, is a conversational instruction, not a control. It competes with the model’s next judgment call and can lose. Recreating the pattern right after being told the details in full means the rule lived in the wrong layer.

What would actually change the outcome:

• Grade the failure with something that didn’t write it, not the session defending itself.
• Stop treating “I explained it” as a fix. Your own retry falsified that.
• Name the exact file and operation that must never happen, not a general “sensitive files” rule.
• Move that block to the tool layer: a hook or permission that denies the write, independent of what any session remembers.
• Verify the block itself, not the model’s behavior on the next attempt.
• Use a fresh agent for retries after that. It removes self-review contamination, but it’s a second layer, not a substitute for the block.

Where does “governed” live in your setup: a rule the model follows, or a check that runs whether it remembers the rule or not?

---

## Reply 26 — A file map and a decision log are different kinds of memory

**Status:** Draft
**Date:** 2026-09-06
**Target:** Reply to Arpit Singh's post about Graft, an open-source tool that gives coding agents (Claude Code, Cursor, Codex, Gemini) a persistent map of the codebase so they stop re-exploring which files matter, how they connect, and what depends on what. Works locally without embeddings or a vector database; claims 46% fewer tool calls, 42% fewer tokens, 60% less time, and a jump from 54% to 66% on SWE-bench Verified. MIT licensed, GitHub link in the comments.
**Core point:** Graft solves real rediscovery cost, but it is structural memory (file relationships) — a different kind from judgment memory (why a choice was made), which no index can derive; it only exists if something forces it to get written down. Grounds canon's version in the actual ticket artifacts (`research.md`, `plan.md`), the promoted `DECISIONS.md`, and `critique/canon-learnings.md`, framed as plain markdown already in the repo rather than a new index to keep in sync. Positions the two as complementary, not competing.

### Copy/paste into LinkedIn

Arpit Singh The cost you're describing is real. An agent re-deriving "which files matter, how they connect" every session is expensive, and a persistent structural map is a direct fix for that specific waste.

Where I'd draw a line: that map tells an agent where the code lives, not why it got built that way. Those are different kinds of memory. One is derivable from the code itself. The other only exists if something forces it to get written down while the work is happening, because no index can reconstruct a decision that was never recorded.

What I've settled on for that second half: every unit of work leaves a research.md and a plan.md behind, and anything that counts as a real decision gets promoted into a DECISIONS.md, with the patterns worth repeating going into a separate learnings log. Plain markdown, already sitting in the repo, with no separate index to keep in sync with the code it describes.

The two approaches aren't competing. Yours removes rediscovery cost. Mine removes re-litigation cost, the tax of asking "wait, why did we do it this way" six weeks later. An agent with both gets the map and the reasoning behind the last time someone walked it.

Given how often a new tool shows up in this space with its own dependency chain: has Graft's map needed regenerating after a large refactor, or does it stay accurate through one cleanly?

---

## Posting instructions

1. Keep the copy/paste block plain text: no Markdown backticks, image embeds, or editorial notes.
2. Upload attachments separately through LinkedIn's media controls. Keep the screenshot
   `images/wrapup-gates-table.png` as-is so the post stays grounded in a real run.
3. Append future entries before this instructions section, then place standalone posts before replies
   and re-sort each group by `Date` ascending, following the same Status/Date/Format/Core hook-or-
   Target/Post/hashtags structure.
