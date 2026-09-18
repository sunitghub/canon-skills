---
name: sdlc-audit
description: Audits a repo's development workflow against Anthropic's AI-Native SDLC Playbook (twenty practices across plan, design, build, test, deploy, maintain) and rates each Covered, Partial, or Gap with file:line evidence. Use when asked to check a repo's dev process maturity, compare a workflow to the AI-native SDLC playbook, or assess how "AI-native" a team's build/test/deploy pipeline is.
category: agent-ops
tags: [audit, sdlc, process, workflow, ai-native]
---

# SDLC Audit

Static audit of a repo's development workflow against the twenty practices named in Anthropic's
"The AI-Native SDLC Playbook" (claude.com/blog/the-ai-native-sdlc-playbook), producing a
per-practice `Covered | Partial | Gap` rating with `file:line` evidence.

A **process** audit, not a code or security audit. It does not overlap `ai-audit` (AI-specific
security surfaces in the system's own code) or `repo-audit` (uniqueness, philosophy coherence,
docs, code quality). This checks whether the *workflow that builds the repo* — planning, review,
testing, deployment, maintenance — matches the playbook's practices. Run from the target repo's
directory; it reads that repo, never canon's own skills.

## Operating constraints

- **Static analysis only.** Read config, docs, and history. Never run pipelines, trigger a deploy,
  or call an external service.
- **Evidence, not inference.** Every `Covered` or `Partial` rating cites a `file:line` (or a named
  file if line-level doesn't apply, e.g. "present in `.github/workflows/`"). A rating with no
  evidence is a `Gap`, not a guess. This applies even to a practice checking for the *absence* of
  something (e.g. an external tracker) — cite the specific file/convention that establishes the
  absence as deliberate (a README statement, a CONTRIBUTING.md note), not a bare narrative claim
  like "git is the only system observed." No named artifact to cite means the rating is `Gap`.
- **No numeric score.** Report per-practice ratings and one tally, never a percentage or letter
  grade — a single number hides which stage is weak.
- **Scope is the dev workflow, not the product.** Do not audit the application's own runtime
  behavior, security posture, or code quality — those are `ai-audit` and `repo-audit`'s jobs.

## Before auditing

Read these, stop once you can rate every practice:

1. `CLAUDE.md` / `AGENTS.md` (or equivalent agent-instructions file) — conventions, standards,
   recurring-mistake notes
2. `.claude/settings.json` (or equivalent hook/guardrail config) — build-time guardrails
3. CI/CD config (`.github/workflows/`, `.gitlab-ci.yml`, or equivalent) — automated gates, PR
   review automation, eval/regression jobs
4. A skills/prompts/playbooks directory if one exists — institutional knowledge encoded for reuse
5. Ticket or issue conventions (a `tickets/`-style dir, PR template, or issue template) — what
   artifact captures intent and acceptance criteria before code
6. 2–3 recent merged PRs or commits — do commits reference a ticket/plan? Is there review evidence?

If the repo has none of these (no CLAUDE.md, no CI, no ticket convention), say so explicitly and
rate every practice `Gap` rather than inferring good practice from absence of evidence.

## The twenty practices

Grouped by the playbook's own six SDLC stages, plus core principles and cross-cutting practices
that apply throughout. Check for a `Covered` (documented + enforced), `Partial` (present but
informal — documented without enforcement, or enforced without being written down), or `Gap` (no
evidence) signal for each.

### Core principles

1. **Loop, not linear pipeline** — Is there a repeatable unit of work (ticket, issue, task) that
   cycles through plan → build → review → close, rather than a single linear release process?
2. **Committed artifacts chain the audit trail** — Does each stage leave a version-controlled file
   the next stage reads (a plan doc, a spec, review notes), with commits traceable back to the
   originating ticket/issue?
3. **Humans stay accountable for judgment** — Are there explicit approval points (branch
   protection, required review, a defined go/no-go step) before code merges or ships?

### Plan (stage 1)

4. **Capture as intent** — Is there a lightweight pre-spec artifact (a written problem statement,
   RFC, or issue description) captured before formal requirements, distinct from the eventual
   implementation plan?

### Design (stage 2)

5. **Spec reviewed by policy owners before engineering** — Is there a design/requirements doc
   reviewed by a non-engineering stakeholder (security, compliance, product) before implementation
   starts, or does design happen inside the same pass as coding?

### Build (stage 3)

6. **Plan committed before code, diff checked against it** — Is an implementation plan written and
   committed (or otherwise persisted) before code changes, in a form the eventual diff can be
   checked against?
7. **Agent-instructions file** — Does `CLAUDE.md`/`AGENTS.md` (or equivalent) document build/test/
   lint commands, architecture, and known recurring mistakes, kept current?
8. **Institutional knowledge as reusable, versioned units** — Are standards/conventions (security
   rules, API design, brand/style guides) captured in reusable files agents or engineers load, not
   just tribal knowledge?
9. **Build-time guardrails** — Are there enforced hooks/checks that block risky actions
   deterministically (protected-path edits, auto-format/lint, credential stripping) rather than
   relying on instructions alone?
10. **Parallel isolated work** — Is there a mechanism for multiple in-flight changes to proceed
    without colliding (worktrees, isolated branches/environments, scoped subagents/helpers)?

### Test (stage 4)

11. **Self-verification against a quantifiable target** — Does the workflow give the implementer
    (human or agent) a concrete pass/fail check to run before handoff, rather than relying on
    reviewer discovery?
12. **Continuous evals/regression suite in CI** — Is there an automated regression suite that runs
    on relevant changes (not just unit tests — a suite that would catch a workflow/config
    regression), gating merge?

### Deploy (stage 5)

13. **AI or automated review in the PR loop** — Does an automated pass (bot, bundled review tool,
    CI check) review PRs for bugs/security/compliance with ranked findings, separate from human
    review?
14. **Named-approver gates, logged** — Do deploy/release actions require a specific approver
    (not just "someone approved"), with the decision timestamped/logged?
15. **Non-interactive CI/CD with scoped credentials and environment tiers** — Does deployment run
    non-interactively with least-privilege credentials, and are autonomy/permissions different
    across dev/staging/production?

### Maintain (stage 6)

16. **Deterministic monitoring triggers diagnosis** — Is there a monitoring signal (alert, metric
    threshold) that automatically kicks off a defined response, rather than purely manual incident
    discovery?
17. **Recurring scheduled scans** — Do security/quality scans run on a standing schedule (cron,
    scheduled workflow), not only reactively per-PR?

### Cross-cutting

18. **Repo-first source of truth** — Is the repo (git) the canonical record, with any external
    tracker (Jira, etc.) a mirror or reference rather than the primary source?
19. **Four governance layers present** — Advisory (docs/standards), deterministic (hooks/CI gates),
    human-approval (review/branch protection), audit-trail (commit history/logs) — are all four
    distinguishable in the repo, or does everything collapse into one ("just ask for review")?
20. **Named leading/lagging metrics** — Does the team track and name specific process metrics (time
    to first artifact, eval pass rate, rework cycles, defect escape rate), or is process health
    judged informally?

## Report format

Write the report inline and to `critique/sdlc-audit.md` in the repo under analysis, replacing prior
contents. First line is the local DateTime the audit ran:

`Audit run: MM-DD-YYYY hh:mm AM/PM`

```
Audit run: MM-DD-YYYY hh:mm AM/PM

## SDLC Audit: <repo-name>

### Core principles
1. Loop, not linear pipeline — [Covered|Partial|Gap] — <file:line evidence or "no evidence found">
2. Committed artifacts chain the audit trail — [Covered|Partial|Gap] — <evidence>
3. Humans stay accountable for judgment — [Covered|Partial|Gap] — <evidence>

### Plan
4. Capture as intent — [Covered|Partial|Gap] — <evidence>

### Design
5. Spec reviewed by policy owners before engineering — [Covered|Partial|Gap] — <evidence>

### Build
6. Plan committed before code, diff checked against it — [Covered|Partial|Gap] — <evidence>
7. Agent-instructions file — [Covered|Partial|Gap] — <evidence>
8. Institutional knowledge as reusable, versioned units — [Covered|Partial|Gap] — <evidence>
9. Build-time guardrails — [Covered|Partial|Gap] — <evidence>
10. Parallel isolated work — [Covered|Partial|Gap] — <evidence>

### Test
11. Self-verification against a quantifiable target — [Covered|Partial|Gap] — <evidence>
12. Continuous evals/regression suite in CI — [Covered|Partial|Gap] — <evidence>

### Deploy
13. AI or automated review in the PR loop — [Covered|Partial|Gap] — <evidence>
14. Named-approver gates, logged — [Covered|Partial|Gap] — <evidence>
15. Non-interactive CI/CD, scoped credentials, environment tiers — [Covered|Partial|Gap] — <evidence>

### Maintain
16. Deterministic monitoring triggers diagnosis — [Covered|Partial|Gap] — <evidence>
17. Recurring scheduled scans — [Covered|Partial|Gap] — <evidence>

### Cross-cutting
18. Repo-first source of truth — [Covered|Partial|Gap] — <evidence>
19. Four governance layers present — [Covered|Partial|Gap] — <evidence>
20. Named leading/lagging metrics — [Covered|Partial|Gap] — <evidence>

### Summary
Tally: <n> Covered / <n> Partial / <n> Gap
Strongest stage: <stage> — <one sentence why>
Weakest stage: <stage> — <one sentence why>
Top priority: <the single highest-leverage practice to add next, and why>
```

Omit no rows — every one of the twenty practices gets a rating, even if it's `Gap` with "no
evidence found". A missing row is a silent skip; a `Gap` row is an honest finding.
