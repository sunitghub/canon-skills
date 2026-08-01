# canon LinkedIn Reply Reference

Use this file when a LinkedIn post or comment can be answered through canon's architecture. It is an
editorial map, not product authority and not copy to paste wholesale.

## Source priority

Before making a material product claim, verify it against current tracked sources in this order:

1. Current implementation-facing skills and standards, especially `skills/sprint/SKILL.md`,
   `skills/sprint/reference/`, `skills/wrapup/`, and `standards/ticket-layout.md`.
2. `README.md` and `docs/how-it-works.md` for public positioning and architecture.
3. `DECISIONS.md` for non-obvious constraints and deliberate tradeoffs.
4. `HANDOFF.md` for current work and discoveries.
5. This reference and any maintainer-local post drafts present in the workspace for angles, phrasing,
   and editorial continuity. Those drafts are optional and are not product authority.

If a tracked source conflicts with this file, the tracked source wins. Correct this file when practical;
do not repeat the stale claim.

## Core positioning

canon is a local-first workflow harness for AI-assisted development. It puts plans, acceptance criteria,
decisions, handoffs, evaluation evidence, and delivery records in the repository, then uses CLI gates and
independent agent judgment to move work from plan to close.

Grounded in: `README.md` (opening, “What Makes canon Different,” and “The Two Commands”) and
`docs/how-it-works.md` (“CLI/Agent Split,” “Generator-Evaluator Separation,” and “Session Continuity”).

The shortest useful distinction:

> The agent performs the work. canon governs how that work is planned, checked, remembered, and closed.

Use “governs” carefully. canon governs work run through its workflow; it does not control every action an
agent can take outside that workflow.

## Architecture map

| Layer | canon mechanism | Owner | Safe LinkedIn claim | Current source |
|---|---|---|---|---|
| Standards | Shared skills and project instructions | Repo + agent runtime | Reusable instructions can live outside one chat or model | `README.md` “Why canon”; `docs/how-it-works.md` “Live References, Not Copies” |
| Intent | Ticket, acceptance criteria, research, and plan before implementation | Agent drafts; human approves | The expected outcome is externalized before code is treated as approved work | `skills/sprint/reference/start.md`; `skills/sprint/SKILL.md` |
| Execution | Approved plan and acceptance criteria guide implementation | Working agent | The builder works from durable repo state rather than chat memory alone | `skills/sprint/reference/start.md`; `README.md` “The Two Commands” |
| Continuity | `.tickets/`, `HANDOFF.md`, and `DECISIONS.md` | Repo files | Context and decisions survive compaction, session changes, and agent changes | `docs/how-it-works.md` “Session Continuity”; `tools/handoff.md` |
| Wrapup | Simplification, code, security, repo, and documentation checks as applicable | Orchestrating agent | The close path makes relevant checks visible, including justified skips | `skills/wrapup/SKILL.md`; `skills/sprint/reference/complete.md` |
| Independent judgment | Fresh reviewer and binding fresh evaluator | Separate agent contexts | The builder is not the only agent judging whether the acceptance bar was met | `README.md` “What Makes canon Different”; `skills/sprint/reference/eval.md` |
| Mechanical close | Required artifacts, checked criteria, evaluator verdict, and summary gates | `sprint` CLI | A confident “done” message is not itself the close condition | `docs/how-it-works.md` “Generator-Evaluator Separation”; `tools/sprint` |
| Delivery record | Plan-versus-actual `summary.md` | Agent writes; CLI requires | Each acceptance item is recorded as delivered, waived, deferred, or partial | `README.md` “The Two Commands”; `standards/ticket-layout.md` |
| Visibility | Local `sprint-check` board over tickets and Git history | Board | Status, intent, evidence, and history remain inspectable without hosted workflow state | `README.md` “The Board”; `docs/sprint-check.md` |
| Human authority | Plan approval and human-only evaluator override | Human | The agent may propose an exception but cannot grant itself the documented evaluator override | `docs/how-it-works.md` “The Close Path”; `standards/ticket-layout.md` |

The ownership split matters: the CLI enforces structure, agents judge meaning, the board surfaces state,
and humans retain explicit approval boundaries. Do not flatten those into “canon mechanically proves the
code is correct.”

Grounded in: `docs/how-it-works.md` “CLI/Agent Split.”

## Lifecycle in one line

Plan and acceptance → human approval → implementation → tests and wrapup → fresh review/evaluation →
mechanical close → plan-versus-actual receipt.

Normal work uses that path. Trivial, bugfix, high-risk, and demo flows vary the amount of planning or
advisory review; do not describe every ticket as running every gate.

Grounded in: `skills/sprint/SKILL.md` “Workflow tiers” and `docs/how-it-works.md` “Tiered Planning.”

## LinkedIn theme map

Use this table to find the honest connection between an external post and canon. Pick one primary angle,
not every possible feature.

| External theme | canon connection | Useful mechanism | Boundary to state when relevant | Sources |
|---|---|---|---|---|
| Long chats, context loss, prompt fatigue | Direct | Approved ticket docs and handoff externalize current intent | Durable files reduce dependence on chat memory; they do not make all context correct | `docs/how-it-works.md` “Session Continuity”; `tools/handoff.md` |
| AI guardrails and action boundaries | Direct | Closing work is a separate, checked state transition | The gate governs canon's close path, not every action an agent can perform | `tools/sprint`; `skills/sprint/reference/complete.md` |
| Trust in AI-generated code | Direct | Fresh evaluator grades acceptance criteria against actual work | Evaluation is evidence, not a mathematical correctness proof | `skills/sprint/reference/eval.md`; `README.md` “What it actually caught” |
| “The tests pass” | Direct | Tests and evals are separate; mutation testing probes whether tests can fail | Mutation proves sensitivity, not semantic truth | `docs/how-it-works.md` “Evals vs Tests”; `skills/mutation-test/SKILL.md` |
| Reusable prompts or skills | Direct | Skills define scope and workflow; skill evals exercise known cases | A saved prompt is not automatically a dependable capability | `standards/skill-setup-std.md`; `skills/skill-eval/SKILL.md` |
| Multi-agent workflows | Direct | Roles are bounded; evaluator context is separated from implementation | More agents alone do not create independence or correctness | `README.md` “What Makes canon Different”; `skills/sprint/reference/eval.md` |
| Agent or model portability | Direct | Durable workflow state lives in repo files; agent adapters remain thin | Runtime capabilities still differ; canon does not make agents identical | `README.md` “Why canon”; `docs/how-it-works.md` “Live References, Not Copies” |
| Risk-based governance | Direct | Tiered planning and impact-aware close paths | Lower-cost paths are bounded by structural rules or explicit user flags | `skills/sprint/SKILL.md`; `docs/how-it-works.md` “Tiered Planning” |
| Ontologies, semantic layers, domain rules | Partial | Acceptance criteria externalize expected behavior; evaluator checks delivery | Domain truth must come from a human or authoritative oracle outside the producing agent | `README.md` “Not just CRUD”; `skills/sprint/reference/start.md` scenario rules |
| Documentation accuracy and claims | Supporting | Documentation audit checks absolutes, stale commands, and scope inflation | A doc audit is part of applicable wrapup, not a guarantee every sentence is true forever | `skills/doc-audit/SKILL.md`; `skills/wrapup/SKILL.md` |
| AI/LLM application safety | Supporting | `ai-audit` scans AI-specific risk surfaces | It is static analysis and returns ship/conditional/hold; it is not runtime monitoring | `skills/ai-audit/SKILL.md` |
| Microsoft Copilot or office productivity | Complementary, not direct | canon can govern development of agent-led workflows and preserve their evidence | canon does not operate Outlook, Teams, Word, Excel, or PowerPoint, and does not replace Copilot | `README.md`; `docs/how-it-works.md`; current absence of Microsoft 365 integrations in `MAP.md` |
| Project management and hosted coordination | Adjacent, not replacement | Tickets provide local workflow state for agent work | canon is not a general hosted project-management surface | `README.md` opening and “The Board”; `docs/how-it-works.md` “CLI/Agent Split” |

## What canon does not claim

Keep these boundaries visible when the external post makes a broader claim:

• It is not a general office assistant and does not directly send email, summarize Teams meetings, or
  manipulate Word, Excel, PowerPoint, and Outlook content. Source: current product surface in `README.md`
  and directory map in `MAP.md`.

• It does not publish to LinkedIn or call a LinkedIn API. The LinkedIn skill stops at copy preparation
  and manual attachment instructions. Source: `skills/linkedin-posts/SKILL.md` and `DECISIONS.md`
  decision `t-a4df`.

• It does not guarantee semantic correctness. Bad acceptance criteria can make an implementation and its
  checks consistently wrong. Source: `README.md` “Not just CRUD” and `docs/how-it-works.md` “Evals vs Tests.”

• It does not eliminate human responsibility. Plans require approval, material scope changes return to
  the user, and the evaluator override is human-only. Source: `skills/sprint/reference/start.md` and
  `standards/ticket-layout.md`.

• It does not make every check mechanical. The CLI owns deterministic state and gates; agents own
  interpretation and judgment. Source: `docs/how-it-works.md` “CLI/Agent Split.”

• It does not make agent runtimes identical. It keeps durable workflow and state portable while runtime
  adapters remain specific. Source: `docs/how-it-works.md` “Live References, Not Copies.”

• It does not treat every green test as an oracle. Tests prove their assertions held; evaluators judge
  acceptance evidence; mutation testing only checks whether selected changes trigger failures. Source:
  `docs/how-it-works.md` “Evals vs Tests” and `skills/mutation-test/SKILL.md`.

## Evidence bank

Prefer one concrete mechanism or lived artifact over a stack of abstract promises.

• Fresh evaluator: criterion-by-criterion grading with evidence and a binding pass/fail close result.
  Sources: `skills/sprint/reference/eval.md`, `meta/screenshots/Eval.jpg`.

• Delivery receipt: `summary.md` compares each planned criterion with its actual disposition. Sources:
  `README.md` “The Two Commands,” `meta/screenshots/summary-tab-dark.png`.

• Context survival: ticket plan, research, acceptance, decisions, and handoff remain in repo files.
  Sources: `docs/how-it-works.md` “Session Continuity,” `tools/handoff.md`.

• Tests with teeth: mutation testing deliberately changes logic and expects the suite to fail. Sources:
  `skills/mutation-test/SKILL.md`, `README.md` “What it actually caught.”

• Visible enforcement boundaries: `docs/how-it-works.md` explicitly separates CLI state, agent judgment,
  and board visibility.

Do not turn a draft anecdote from `posts/` into a current claim without checking its ticket or tracked
source. Do not use private-project ticket details unless the user asks and the context is appropriate.

## Reply voice

Existing successful drafts use a peer contribution, not a product pitch:

1. Lead with the author's specific idea—not “Great post.”
2. Say where canon maps to it and at which layer.
3. Add one concrete mechanism or evidence point.
4. State the meaningful boundary if the mapping is partial or adjacent.
5. End with one focused question only when it advances the conversation.

Additional rules:

• Keep canon lowercase unless it begins a sentence.
• For comments, prefer one to four short paragraphs; match the depth of the thread.
• Do not list every canon feature. One relevant mechanism is usually stronger.
• Avoid external links in the first comment unless the user explicitly wants one.
• Do not hijack someone else's post with a generic canon introduction.
• Preserve uncertainty: use “maps to,” “helps with,” or “works one layer upstream” when the relationship
  is indirect.
• Reuse ideas, not identical sentences, across adjacent threads.

Maintainer-local editorial precedent, when those ignored drafts exist: `posts/LinkedIn_Posts.md`
replies 7–10 and `posts/linkedin_replies.md` “Research principles applied” sections.

## Five-part reply recipe

Use only the parts the thread needs:

1. **Mirror:** identify the external post's strongest idea in its own language.
2. **Layer:** say whether canon is direct, supporting, complementary, or out of scope.
3. **Mechanism:** contribute one factual canon mechanism.
4. **Boundary:** name what canon does not solve or prove.
5. **Invitation:** ask a narrow question if a reply would benefit from dialogue.

Example for an adjacent product:

> This is a useful map of where Copilot removes task-level friction inside Microsoft 365. canon works at
> a different layer: it reduces workflow-level friction when an AI agent plans, builds, and verifies
> development work. The agent performs the task; canon preserves the approved intent and puts close
> behind independent evaluation. It does not operate the Microsoft 365 apps themselves, so the two are
> complementary rather than substitutes.

Verify the current mechanisms before using this example. Rewrite it around the actual post rather than
copying it mechanically.

## Final grounding check

Before handing off a canon-related LinkedIn reply:

- Is the connection classified honestly as direct, supporting, complementary, or out of scope?
- Does every product claim still match a current tracked source?
- Is there one concrete mechanism rather than a feature dump?
- Is the most important limitation visible?
- Does the reply add to the author's point instead of redirecting the thread to canon?
- Is the copy block plain text, with editorial notes and attachments kept outside it?
- Has publishing stopped at manual handoff?
