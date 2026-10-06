# How canon Works

canon is a local-first agent workflow harness. No SaaS, no cloud state — everything lives in your repo.

## The CLI/Agent Split

canon separates what a CLI can do deterministically from what an agent must judge:

| Layer | Owner | Does |
|---|---|---|
| State | CLI (`sprint`, `tkt`) | Creates tickets, tracks active sprint, enforces close gates |
| Judgment | Agent | Plans work, interprets acceptance criteria, decides what passes |
| Visibility | Board (`sprint-check`) | Reads `.tickets/` and `git log`, surfaces everything locally |

Gates enforce structure; agents enforce meaning. Neither can substitute for the other.

## Live References, Not Copies

Skills are symlinked from `~/.canon/skills/` into each project's `.claude/skills/` (Claude Code) and `.agents/skills/` (Codex/Pi). Update the canon repo once — every project picks it up on the next session. No copies, no drift.

Standards (`standards/efficiency.md`, etc.) are injected via `@`-imports in `AGENTS.md`, and also listed as a row in its `AI-SKILLS` table so a table-only reader still sees them. Same live-reference model.

## Tiered Planning

Simple work stays light. canon chooses the lightest tier that still protects the work:

| Tier | When | What runs |
|---|---|---|
| **Trivial** | Single line, question, mechanical change (never a new file, test/build wiring, hook/pipeline edit, or coordinated multi-file intent) | Work directly |
| **Bugfix** | Single logic file plus its covering test, none of the not-trivial triggers — a *complete-time downgrade* decided from the actual diff | Eval-only: keeps the binding evaluator + a lighter wrapup; skips the advisory reviewer |
| **Normal** | Focused, reversible change | ticket + acceptance + plan + brief research → build → wrapup + reviewer + evaluator |
| **High-risk** | Security, irreversible ops, broad blast radius | Full pipeline: orient (parallel) + grill + impact analysis + required mitigation tests |

## Generator-Evaluator Separation

The agent that wrote the code is the worst possible reviewer of that code. canon enforces separation structurally:

1. `sprint complete` spawns a **fresh subagent** — Read and Bash only, no implementation history — to grade each acceptance criterion against the actual code.
2. The evaluator writes a machine-generated `evaluator-run-id` before grading; the orchestrating agent logs a matching entry to `.claude/subagent-runs.jsonl` via `subagent-log.sh` right after the subagent completes, and the close gate correlates the report to that run by a ±60-minute timestamp window. The run-id is a correlation handle, not a security token — the gate never validates it as `agent_id`. Under Claude Code the gate also requires the harness's own transcript of that subagent (which an agent cannot write) to contain the run-id, the ticket id and every verdict line, so a hand-written report is refused (t-0231); it fails open, with a note, where it cannot check (Copilot CLI, pi, Codex).
3. The CLI blocks close if the field is absent, the verdict isn't `pass` (any `partial` or `not-run` criterion forces the verdict to `fail` — there's no separate non-blocking `partial`/`not-run` verdict), any acceptance or test-plan box is unchecked, `summary.md` is missing, the `## Wrapup Gates` record is absent, a referenced visual mockup was never embedded or its file never copied into the ticket's `visuals/`, or `plan.md`'s Approach or Sign-off is empty or unapproved.

Same-context review reintroduces self-evaluation bias. The protocol fails closed when fresh-context evaluation is unavailable.

## Evals vs Tests

These get conflated because both are "checks," but they sit at different layers and mean different things when they pass. The evaluator does **not** "run the tests" — tests run; the evaluator *judges*.

| | **Tests** | **Evals** |
|---|---|---|
| **Subject** | Code behaviour — given input X, does the function return Y? | Non-deterministic / agentic output — is a skill's output, or the completed work, actually correct? |
| **Runner** | Deterministic test runner (pytest, etc.), no judgment | A **fresh-context agent** with no implementation history, precisely so it can't rubber-stamp its own work |
| **What "pass" proves** | An assertion held | An independent grader re-derived the claim and agreed, with `file:line` evidence |
| **Catches** | Broken logic, regressions | What a test structurally can't: a test that can *never fail*, defensive branches nobody ran, "evidence" that quietly went stale, plausible-but-wrong output |

"Eval" covers two related things in canon:

1. **Skill evals** (`skill-eval`, cases in `skills/<name>/evals/evals.json`) — verify a *skill* produces correct output for a known set of prompts. Because the thing under test is an agent behaviour, not a pure function, they run via an **executor + grader subagent pair in fresh context** (≥3 cases: a control plus boundary / over-caution / compliance types).
2. **The evaluator gate** at `sprint complete` (`skills/sprint/reference/eval.md`) — a fresh-context adversarial agent that grades each acceptance criterion against the delivered code and writes `eval-report.md`. This is a *review gate*, not a test suite.

Both are distinct from **tests**, which are the deterministic checks that ship with the code and are exercised by a runner. The evaluator may *inspect* the tests as evidence (e.g. confirming a test can actually fail) — but grading criteria is not the same as executing a test suite.

Rule of thumb: **tests keep the code honest; evals keep the agent honest.**

## Session Continuity

`HANDOFF.md`, the active ticket, and recent closed tickets are read explicitly by `sprint start`'s context step — canon installs zero Claude Code hooks. A context reset or fresh session never loses the thread — the plan, decisions, and acceptance bar are in `.tickets/<id>/`, not the chat history.

## The Close Path

```
sprint complete
  └── Wrapup: simplify → code-review → security → repo-check → doc-audit
  └── Reviewer (fresh subagent, normal+ tier — runs on the Admin > Model Tiers "Review & Eval" default, or any model the user names via plan.md's Gate model: field)
  └── Evaluator (fresh subagent, non-trivial tiers — bugfix/normal/high-risk) — adversarial, blocks on fail (same model rule)
  └── Acceptance check — CLI blocks on unchecked items
  └── summary.md — plan-vs-actual table, one row per criterion
  └── tkt close
```

The one documented way past a `fail` evaluator verdict is a human-only escape hatch: a person hand-edits `eval_override: true` in the ticket's `ticket.md` frontmatter and records a dated waiver in `acceptance.md`. No `tkt` command sets it and no agent may write it — agents must refuse even if asked — so a close override always has a human in the loop (see `standards/ticket-layout.md`; the CI equivalent is in `docs/headless-ci.md`).

The one documented way to *reduce* the close gates by user choice (rather than by structural risk) is **demo mode**: setting `demo: true` on the ticket runs a time-boxed close of only `security-review` + the binding evaluator (evaluator forced to Haiku), skipping the advisory reviewer + rest of wrapup. It never drops below the binding evaluator, and is marked loudly in the Wrapup Gates rows and `summary.md`. Headless/CI never *reduces the gate set* for it: `sprint-headless` runs its full pipeline and ignores `demo` entirely, while `sprint-headless-eval` (already eval-only) also runs its full gate set but does read `demo: true` to default the evaluator to Haiku when no `--model` is given — a model choice, never a skipped gate. It is the single flag-driven exception to canon's "only structural risk reduces gates" invariant — see `AGENTS.md`'s north-star exception.

Gates don't make agents smarter. They make certain failures impossible — and turn the ones that remain into data.

## Known Upstream Issue: Opus 5 Delegation Gate

Claude Code 2.1.219+ injects a default-on system-prompt section, gated by the `opus_5_prompt_bundle` model capability (Opus 5 only, no Sonnet/Fable/Haiku), reading *"Do not call the AgentTool unless the user requested it"* / *"Do not use workflows or deep-research unless the user requested it"* — no `settings.json` key or CLI flag disables it ([anthropics/claude-code#80988](https://github.com/anthropics/claude-code/issues/80988)).

canon's skills lean on **standing** delegation triggers written into `SKILL.md`/`CLAUDE.md` rather than a literal per-turn ask (`sprint`, `wrapup`, `mutation-test`, `repo-workflow-audit`, `skill-eval`, and the `Explore`-agent guidance all fork subagents this way). Named/specific triggers still register as "requested"; fuzzy standing triggers — the shape most of the above use — can be silently suppressed on Opus 5, with no error surfaced. A run with delegation quietly disabled looks identical to a normal one.

Check exposure: `claude --version` (only Opus 5 sessions are affected) and, if run on Opus, watch whether a task that should clearly hand off to a subagent actually dispatches one.

canon installs zero Claude Code hooks by design (see Session Continuity above); the standing fix for this — a `UserPromptSubmit` hook that injects a delegation "request" every turn, satisfying the tool's own escape clause — is an opt-in per-user mitigation via the `update-config` skill, not something canon wires in automatically. Tracked in `t-643c`.

## Not Just CRUD

Most agent harnesses are demonstrated on todo apps and CRUD endpoints, where "correct" is obvious
and a wrong answer is visibly wrong.

canon's harder workout has been **standards-governed industrial work** — a knowledge-graph agent
answering questions against [CFIHOS](https://www.jip36-cfihos.org/) (the IOGP capital-facilities
handover specification) and ISO 14224 failure taxonomy, where every answer must cite a source and an
uncited one is marked unverified.

That domain punishes a harness differently. Correctness is *semantic*: a plausible, fluent, well-cited
answer can still be wrong because a threshold came from the wrong source. Domain conventions are
non-negotiable in ways no linter knows about. And the failure mode isn't a crash — it's an answer that
looks authoritative and isn't. Adversarial review earns its cost fastest exactly there.

## The Two Commands

**`sprint start "<what>"`** — Make your agent plan before it codes.

Creates a ticket, defines acceptance criteria, and writes the plan before touching source. Normal changes stay light; a `bugfix` tier (a single logic file plus its covering test) runs eval-only — it keeps the binding evaluator but skips the advisory reviewer and heavier wrapup; high-risk changes add parallel subsystem mapping (one agent per independent subsystem, run concurrently), gray-area resolution, five-dimension impact analysis, any required human checkpoint, and adversarial review. The plan lives in `.tickets/<id>/` and survives context resets.

**`sprint complete`** — Block close until every box is checked.

Runs the close path: simplify → code-review → security → repo/doc audit → **reviewer** (fresh subagent, advisory) → **evaluator** (fresh subagent, binding) → acceptance check → close. The evaluator — Read and Bash tools only, no implementation history — grades each acceptance criterion against the actual code. It writes a machine-generated `evaluator-run-id` before grading; the CLI blocks close if the field is absent or the verdict isn't `pass`. Any `partial` or `not-run` criterion forces the verdict to `fail` — there's no separate non-blocking `partial`/`not-run` verdict — and either blocks close the same way.

When the sprint closes, the agent writes `summary.md` — a plan-vs-actual table, one row per acceptance criterion, showing whether each was delivered, waived, deferred, or partial. Deviations must appear in the table; the agent can't bury them in prose. The **Summary** tab on the ticket board makes this permanent and queryable: find out whether the spec was fully met without scrolling through chat history.

Each sprint produces up to eight docs:

| Doc | Written | Contains |
|---|---|---|
| `acceptance.md` | sprint start | Done criteria · test plan · QA sign-off |
| `plan.md` | sprint start | Approach · decisions made along the way |
| `research.md` | sprint start | Objective truth: relevant files, system model, constraints, unknowns — brief for normal tier, full orient protocol for high-risk/brownfield |
| `review-notes.md` | sprint complete (normal+) | Advisory reviewer findings — code quality, scope, standards — with a YES/NO verdict |
| `eval-report.md` | sprint complete (normal+, incl. bugfix) | Adversarial criterion grades · pass/fail with file:line evidence |
| `mutation-report.md` | sprint complete (optional) | Advisory: surviving mutants when logic files changed — never close-gated |
| `learnings.md` | sprint complete (optional, via `tkt learn`) | UNPROMOTED lessons candidate — the sprint's deviations + evaluator and reviewer findings, for a non-builder to promote |
| `summary.md` | sprint complete | Plan-vs-actual table · close prose |

Root `LEARNINGS.md` keeps a capped, always-current index of every open `learnings.md` candidate —
the `learnings-sweep` skill upserts one row per ticket close (the sprint agent runs it right after
`tkt learn`, per the close protocol), and its `--full` mode backfills/reconciles by hand; it is a
skill, not a shell command. It's read alongside `HANDOFF.md` at
every `sprint start`, and never promotes anything itself — see `skills/learnings-sweep/SKILL.md`.

All are plain markdown in `.tickets/<id>/` and are read into the agent's context by `sprint start` — so a context reset or a fresh session never loses the thread. Projects can track that workflow state in git or keep it local; canon itself keeps its working tickets ignored.

**Gated, not vibes.** The CLI owns state; the agent and evaluator judge whether the work behind the gates is true. The board surfaces the same checks early — cards flag `incomplete` in red well before close-time.

**[What each wrapup gate checks — and doesn't →](wrapup-gates.md)** — the checks/skips reference for every close-path gate, and the install-time/runtime security it deliberately leaves out of scope.

Layering is intentional: `sprint complete` is CLI-enforced; planning, audits,
test judgment, and clean-context evaluation are agent-required; `sprint-check`
is board-surfaced visibility while the work is still in progress.

### Two ways to grade headless — `sprint-headless` vs `sprint-headless-eval`

Both grade a diff that **already exists** and both **run only against a base ref** — you never let
them write code. The difference is ceremony: the full pipeline runs three gates against an
approved ticket; the eval-only command runs one gate against anything with checklist criteria.

| | `sprint-headless` | `sprint-headless-eval` |
|---|---|---|
| Gates | reviewer + evaluator + security-review (`bugfix` tier: evaluator + security-review) | evaluator only |
| Input | ticket id + committed, approved `plan.md`/`acceptance.md` | a ticket id (grades its `acceptance.md`) **or** any markdown file with `- [ ]` criteria |
| Requires | `tkt ci <id> on`, `- [x] Plan approved`, ticket committed | just the ticket/spec + a git repo |
| Writes | `review-notes.md` + `eval-report.md` in `.tickets/<id>/` | `eval-report.md` in the ticket folder, or next to the spec file |
| Cost | ~100k+ tokens (three subagents) | ~30–40k tokens (one subagent) |
| Verdict | `HEADLESS_VERDICT: PASS`/`FAIL` → exit 0/1; any gate fail → FAIL | same; any `partial` or `not-run` forces `fail:` |

**Neither headless command runs your code.** Both dispatch through `claude -p --permission-mode
dontAsk` with Bash whitelisted to `git diff/log/show/status` plus read-only tools — so they grade
by *reading the diff and citing `file:line`*, never by executing a test suite or rendering a
browser. That means an acceptance item phrased as "run `npm test …`" or "render and assert the
DOM" can't be *executed* here; it will be graded statically (or land `not-run → fail`). Execution
lives at the **interactive `sprint complete`** close, whose evaluator gets full Bash and *does*
run your tests / a headless browser and grades by exit code. Rule of thumb: write headless
criteria to be verifiable by reading the diff; reserve run-it-and-watch-it-fail checks for the
interactive close.

**Cache an unchanged diff (opt-in).** Re-grading a diff you haven't touched costs tokens for a
verdict you already have. Pass `--cache` (or set `CANON_GATE_CACHE=1`) and either headless command
reuses the prior verdict — keyed on the exact diff content — without re-dispatching `claude -p`,
announcing loudly that it did. Off by default (canon never *silently* reduces gate assurance);
`--no-cache` always wins. Both PASS and FAIL are cached; edit the code to force a fresh grade. See
**[Headless CI grading → Verdict Caching](headless-ci.md)**.

> **No remote?** The base ref defaults to `origin/main` → `main`. If neither resolves (e.g. your
> branch is `master`, or there's no remote), it silently falls back to diffing against the repo's
> **root commit** — which makes the whole tree look "changed." Tag a real baseline
> (`git tag seed <commit>`) and pass `--base-ref seed` so the diff means "what this sprint
> changed." Verified end-to-end on Windows-on-ARM (Git Bash `MINGW64_NT…ARM64`), where the
> bundled x64 `sprint-headless-json-win.exe` runs under emulation and no `ANTHROPIC_API_KEY` is
> needed if `claude` is already logged in.

**[Headless CI grading →](headless-ci.md)** — full prerequisites, the spec-file format, model/cost control, waivers, and consumer-project CI wiring.

### Which model runs the close gates

The close gates stay mandatory regardless of model — this only decides *which* model runs the
reviewer and the binding evaluator. First match wins:

| # | Condition | Set by | Model used | Scope |
|---|---|---|---|---|
| 1 | `Gate model:` is a model id (`haiku`/`sonnet`/`opus`) | User only — live instruction or manual edit in `plan.md` | that model | Both gates; overrides everything below, any risk tier |
| 2 | `Gate model: session` | User only | current session model | Forces full session-model review; skips the rows below |
| 3 | `demo: true` on the ticket (and no `Gate model:`) | User, via the demo flag | Haiku, on any diff | Evaluator only — `security-review` runs inline on the session model |
| 4 | Admin "Review & Eval" default (`defaults.eval.anthropic` in `tools/sprint-check-app/model-tiers.json`) | Admin > Model Tiers, applied to **every** interactive close regardless of diff risk | the registry model's alias (e.g. `sonnet`) | Read directly from disk; interactive `sprint complete` only — headless is unchanged |
| 5 | Fallback — registry missing/unreadable, or the default has no matching alias | Automatic | the gate definition's floor, `claude-sonnet-5` (`agents/canon-*.md`); the session model only if the gate fell back to `Plan` | Never silently inherits an expensive session model |

The gates run as canon's own agent definitions, `canon-reviewer` and `canon-evaluator` in `agents/`. `skills.sh add sprint`
and `refresh` link or copy them into `.claude/agents/`. The definitions fix what a dispatch can't: **effort `high`** and
a read-only tool set (Read, Grep, Glob, plus a shell: `Bash` for Claude Code, `execute` for Copilot CLI). The table above still picks the model, and a dispatched `model` overrides
the definition's `claude-sonnet-5` floor. A project that hasn't been refreshed falls back to the built-in `Plan` type,
recorded as `(fallback: Plan)` on the gate's row. On Windows, write agent/skill files from a shell or a code editor:
Notepad's Markdown mode saves the frontmatter's `---` as `\---`, which silently drops it. Also open the project by its
path's real case (`ToDo`, not `todo`), because Claude Code keys workspace trust by the exact path string. `add`/`refresh` also
offer deny rules for system-wide installers (`brew`/`apt`/`choco`/`winget install`) in `.claude/settings.json`, after asking;
the board's register flow applies them without a prompt, like the subagent-log permission. Codex mirrors ship in
`agents/codex/*.toml` (unverified live); copy them into `.codex/agents/` yourself.

The gates run on whatever you set in Admin > Model Tiers (row 4), unless a ticket's own `Gate model:`
or the demo flag (rows 1–3) says otherwise — a human's setting, never the agent's own judgment of
its own work. Note this applies to code changes too, not just docs-only diffs: pick a weak model there
and every close uses it unless overridden. The chosen model and its source are recorded on the `eval`
row as `(model: <id> — <source>)` for audit. (Applying the Admin default is confirmed only under Claude Code.) Full logic:
[`skills/sprint/reference/complete.md`](../skills/sprint/reference/complete.md) → "Model tier for gates."
