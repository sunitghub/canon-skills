# Roadmap

Planned work, kept short. Day-to-day tickets live locally in `.tickets/` (gitignored);
this file is the public-facing shortlist.

## Held — for npm publish
- **Pre-public reference consistency** — verify the npm version badge and `npx canon-skills`
  resolve once the package is published, the package name and links agree, and `sunitghub`
  org references point at the real public repo. Includes aligning the install-terminal
  mockup with the installer's actual output.

## Near-term — operations and board scale

- **Repo sync: canon → canon-skills** — make every meaningful push to the private
  dev repo reach the public install repo. Current path is manual dual-push with
  `public` remote; target state is a GitHub mirror after public-launch cleanup.
  Tracked by `t-4989`.
- **Done-column scale and archive policy** — the board collapses Done/Discarded
  cards visually, but `/api/tickets` still loads all tickets each refresh. Decide
  whether closed tickets need windowed loading, pagination, or an explicit
  archived status. Archive should preserve ticket files and keep historical work
  searchable for `Why`/code archaeology. Tracked by `t-070b`.

## Backlog — ideas from ecosystem research

- **`session-learn` skill** — retrospective scan of `~/.claude/projects/<project>/*.jsonl` to
  surface cross-session patterns that live-memory misses: repeated tool failures, consistently
  rejected approaches, commands that blow up every sprint. Proposes targeted CLAUDE.md / memory
  updates. Inspired by [headroom's `learn` module](https://github.com/chopratejas/headroom).

  Design constraints before building:
  - **Subagent isolation required.** Reading raw JSONL logs into main context is exactly the
    token spend `efficiency.md` warns against. Headroom solves it with a separate model call +
    ~80K digest budget. Canon's zero-install equivalent must delegate to a subagent that returns
    only distilled patterns — not a read → analyze loop in the main session.
  - **Signal threshold: 2+ occurrences or explicit user direction.** Below that, it's noise
    injected into CLAUDE.md. False-positive "learnings" actively hurt. The scan must be strict.
  - **Fits alongside `context-check`**: context-check audits what's loaded now; session-learn
    mines history to improve what gets loaded next time. Natural pairing.
  - Not a fit until canon has meaningful session volume to scan against.

- **JTBD job-type dimension + eval-only `bugfix` tier + `mikado` skill** — three linked ideas
  from reviewing [nWave](https://github.com/nWave-ai/nWave)'s Jobs-To-Be-Done guide (7-wave ODI
  pipeline; cross-wave verbs `root-why`/`mikado`/`mutation-test`). canon routes by *risk*
  (trivial/normal/high-risk); nWave routes by *job shape* (greenfield/brownfield/bugfix/refactor).
  Adopt job-shape as an **orthogonal** planning dimension, not a replacement for risk tiers.

  Design constraints before building:
  - **North-star:** job type may *add* planning steps; only structural risk may *reduce* gates;
    a tracked sprint never drops below the binding evaluator without a recorded `eval_override`
    waiver. Job-type = planning aids; risk-tier = gates. Separate axes.
  - **`bugfix` tier is eval-only, not gate-choice.** A tier between trivial and normal that keeps
    the binding fresh-context evaluator and drops the *advisory* reviewer + heavy wrapup. Do NOT
    build a board gate-picker or a "close with no gates" path — canon already rejected skipping
    gates on low-risk work in favor of cheaper-but-independent review (`t-1477`), the evaluator is
    mandatory at normal+ (`t-c5d4`/`t-5230`), and "none" already exists as trivial tier / `tkt`-only.
  - **Eligibility is structural, never agent judgment.** Reuse the existing file-path/trigger
    low-risk check (`t-8c24`: the classifier never reads plan prose). Qualifies for `bugfix` when
    the change is a single logic file (+ its test), a covering test exists, and none of
    `SKILL.md`'s four categorical not-trivial triggers is present. Board shows the derived tier +
    reason read-only; an evaluator skip is the recorded `eval_override` + dated waiver (`t-d8a1`).
  - **`mikado` is a refactor-phase planning skill, gates unchanged.** Maps the dependency tree,
    does leaf changes first, reverts immediately when a change forces unplanned prerequisites.
    Invoked during orient/plan for a refactor job; produces the plan, touches no close gate.
  - **`root-why` (lightweight 5-Whys)** is the natural bugfix-job planning step, distinct from the
    heavier `docs/production-incident-playbook.md`; candidate for the same JTBD dimension.
  - Ship each of the three as its own gated sprint. This entry is the captured design, not the build.

## Backlog — sprint workflow

- **`demo` mode — one-click time-boxed close for live demos** (captured design, not the build).
  A board **Demo** checkbox on the New-Ticket form (next to CI / Eval-only / Eval Override) that
  makes `sprint complete` run a fast path for 20–30 min demos: **only the binding evaluator (forced
  Haiku) + exactly one wrapup gate (`security-review`)**, skipping the advisory reviewer and the rest
  of wrapup. Requested 2026-07-30; ~80% already exists (`Tier: bugfix` + `Gate model: haiku` gets
  most of it today by hand).

  Design constraints before building:
  - **Never drops below the binding evaluator.** Keeps canon's north-star hard floor (2026-07-25):
    the evaluator always runs. `demo` only reduces the *advisory reviewer + wrapup* gates — the same
    ones the `bugfix` tier already reduces — so it's a user-elected `bugfix`-lite + forced Haiku.
  - **Reduction is by user flag, not structural risk** — the one place this bends the north-star
    ("only structural risk may reduce gates"). Justified as the same class of explicit, human-set,
    auditable override as `eval_override` / `Gate model:`, and paid for by being **loud**: a Demo
    badge on the card, `summary.md` states "closed in Demo mode (security-review + evaluator, Haiku)",
    Wrapup Gates rows read `skipped | demo mode`. A demo close must never look like a full close.
  - **Reuse existing machinery.** Frontmatter `demo: true` (`tkt`-owned, absent=false), `tkt demo
    <id> [on|off]`, parsed into ticket JSON with server.py↔main.go parity — mirror the `ci`/`gate`
    (`t-4e57`) pattern exactly. Model: `demo` implies `Gate model: haiku` unless an explicit value is
    set (explicit wins). This forces Haiku on *any* diff — distinct from the structural low-risk
    downgrade.
  - **Three set-surfaces, editable post-creation.** `demo` is a close-time behavior modifier like
    `Tier` / `Gate model`, so it must be settable *after* creation, not only at New-Ticket time — the
    common flow is `sprint start "Create some app"` then "actually, this is just a demo." Three
    surfaces, all writing the same `demo: true` frontmatter: (1) the New-Ticket form checkbox
    (creation-time), (2) an editable toggle on the **Plan tab** alongside the existing `Tier` /
    `Gate model` dropdowns (decide-later, on the board), (3) `tkt demo <id> [on|off]` (agent/CLI).
    Mirrors how `ci`/`gate` (`t-4e57`) are both New-Ticket-set and post-creation-editable.
  - **Explain via a static tooltip, never injected prose.** To tell the user *what* demo does, add a
    `title=` tooltip on the New-Ticket checkbox and the Plan-tab toggle (mirror the CI badge tooltip,
    `app.html:2065`) — worded generically, e.g. *"Demo mode: fast close — binding evaluator + one
    wrapup gate only, Haiku unless an explicit Gate model is set."* **Do not** inject a per-ticket
    sentence into the Description or Plan at check-time: it duplicates the frontmatter source of
    truth, goes stale on `tkt demo off` (the exact stale-evidence failure the evaluator exists to
    catch), and would be *factually wrong* when an explicit non-Haiku `Gate model` wins or if the
    single gate is later confirmed as `code-reviewer` rather than `security-review`. The *resolved*,
    always-true statement lands in `summary.md` **at close**, where the gate and model are settled.
  - **The one wrapup gate = `security-review`** (recommended; open for confirmation). The evaluator
    covers criteria-vs-code; security is the one defect class unacceptable to ship even in a demo,
    and `bugfix` already retains it. Alternative: the in-context `code-reviewer` (nearly free).
  - **Headless/CI ignores `demo`.** `sprint-headless`/`sprint-headless-eval` always run full — CI
    grades untrusted diffs and must not be softened by a ticket flag. Warn on `ci:true + demo:true`.
  - **Reversible.** A demo-closed ticket can be `tkt reopen`'d and re-run through full close before
    any real merge. Frame `demo` for demonstrations/disposable repos, not production merges.
  - **Naming:** `demo` matches the framing; `express`/`quick` would signal reduced rigor more.

  Phasing (each its own gated sprint): **A** — plumbing (frontmatter + `tkt demo` + JSON parity +
  New-Ticket checkbox + Plan-tab toggle + card badge + checkbox/toggle tooltips; 3-way parity
  surface). **B** — protocol (`complete.md` demo
  close-path + `AGENTS.md`/docs + DECISIONS entry recording the north-star amendment). **C**
  (optional) — headless-path guard + `ci+demo` warning. Suggested order: **B first** (protocol-only,
  testable via a hand-set `demo:true` before touching the board), then A, then C.

## Backlog — workshop examples

- **`dsl-discount-spec` follow-ups** — two small, deferred items from the runner-output work
  (`t-07aa`/`t-295c`/`t-527e`):
  - Regenerate `examples/dsl-discount-spec/discount-spec-demo.{html,pptx}` from the updated `.md`
    on a machine with marp-cli — the `.md` was updated in `t-295c` but the derived renders were
    deferred (marp-cli not installed in the dev env), per the `t-b73e` disclose-don't-ship-stale
    pattern.
  - Optional: unify the JS vs Python runner FAIL-detail idiom (`applied true … "…"` vs
    `applied True … '…'`) so FAIL lines are byte-identical across both runners (~2 lines in
    `dsl_runner.py`). Pre-existing, break-only, cosmetic; PASS output is already identical (`t-07aa`).

## Planned — post-traction

- **Windows 11 CI coverage** — add a WSL2 job to `.github/workflows/ci.yml` once the repo goes public; validates the `ss`/python3 port-detection path that `lsof` currently covers on macOS runners.
- **crit companion note** — document [crit](https://github.com/tomasz-tomczyk/crit) as a complementary tool: canon owns the sprint lifecycle; crit owns the human-in-the-loop diff review. Natural handoff point is `sprint complete` → `crit push` to sync inline comments to the PR. One paragraph in `docs/index.html` or `docs/setup.md`, no code changes.
- **Homebrew install path** — `brew install canon-skills` as an alternative to `npx` for users without Node. Canon's bash/markdown architecture means Homebrew installs a directory (not a binary), which works via `SKILLS_ROOT` but needs testing. A custom tap (`brew tap sunitghub/canon-skills`) is low-friction; homebrew-core requires public traction. Revisit if npm/Node proves a meaningful adoption barrier.
