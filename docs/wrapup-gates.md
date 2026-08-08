# Wrapup Gates — What Each Check Does and Doesn't Cover

canon's close path runs a series of gates before a ticket can close. Some are advisory; two
(`reviewer`, `evaluator`) run as fresh subagents with no implementation history; one (`evaluator`)
is the binding gate that blocks the close. This page is a reference for **what each gate checks and,
just as importantly, what it does not** — so a passing close is never mistaken for a guarantee it
was never designed to make.

See the [README](../README.md#the-two-commands) for the lifecycle overview,
[`docs/how-it-works.md`](how-it-works.md) for the CLI/agent split, and
[`skills/sprint/reference/complete.md`](../skills/sprint/reference/complete.md) for the authoritative
close-path logic. Each gate's own definition lives in `skills/wrapup/gates/*.md`,
`skills/doc-audit/SKILL.md`, and `skills/sprint/reference/eval.md`.

The wrapup pipeline itself is `code-simplifier → code-reviewer → security-review → repo-check →
doc-audit → refresh docs`. The `reviewer`, `evaluator`, and advisory `mutation-test` gates are driven
from `complete.md`, not the wrapup pipeline, but they surface together on the board's **Wrapup Gates**
table, so they're included here.

**Demo mode.** When a ticket carries `demo: true` (a user-elected light-close for a live demo or a
docs/research/UX sprint — see [`complete.md`](../skills/sprint/reference/complete.md)'s "Demo mode"),
`sprint complete` keeps only **`security-review` + the binding `evaluator`** and skips every other
gate below (advisory `reviewer`, `code-simplifier`, `code-reviewer`, `repo-check`, `doc-audit`) — a
superset of what the `bugfix` tier trims. `security-review` always runs even with no security surface
(its `ran` row records that), and the evaluator is forced to Haiku. Each skipped gate's Wrapup Gates
row reads `skipped | demo mode`, so a demo close never looks like a full close.

## What each gate checks

| Gate | Checks | Does NOT check / out of scope | Skips when |
|---|---|---|---|
| **code-simplifier** | Structure & clarity of code *touched this session*: reduces nesting/redundancy, better names, no nested ternaries; **behavior must stay identical** | Correctness/behavior changes, security, tests, docs; untouched code | Single-line/trivial rename; docs/comments/config-only |
| **code-reviewer** (inline, advisory) | 8 dimensions on session code: plan/acceptance alignment (scope drift), correct solution, design fit `[SRP][OCP][LSP][ISP][DIP][DRY][LoD][CoC]` + GoF `[pattern-fit]` (misapplied/missing patterns, default-to-silence), bugs/edge cases, test coverage, shallow security, efficiency, style | *Deep* security (deferred to security-review), runtime behavior, repo/doc consistency; **does not mandate patterns** — forcing an abstraction is itself flagged `[KISS]`/`[YAGNI]`; advisory — doesn't block close | Single-line fix, no design implications; purely mechanical |
| **reviewer** (fresh subagent, advisory) | Independent clean-context review of the diff vs approved plan/acceptance; YES/NO verdict on quality, scope, standards | Binding authority — a NO is advisory only; has no implementation history | Trivial/bugfix tiers (normal+ only); also skipped in **demo mode** |
| **security-review** (static, diff-scoped) | HIGH/MED-confidence *exploitable* vulns in changed files: injection, XSS, authz bypass, weak crypto, unsafe deserialization, SSRF/CSRF, broken auth, secrets/hardcoded creds, **agent/MCP security** (tool over-provisioning, permission scope, MCP config exposure), third-party data egress, destructive action endpoints | **Never runs the system** (no runtime posture); credential blast radius; anomaly/behavioral detection; rate-limiting/DoS; regex DoS; log spoofing; missing audit logs; general hardening gaps; env vars/CLI flags (trusted); framework-safe XSS; LOW/theoretical; test/dead code | No security-sensitive files/patterns changed (but in **demo mode** it always runs — it is the one wrapup gate demo retains) |
| **repo-check** | Repo surface vs README intent: stale paths/removed commands, skill graph (`skills.sh list` + `canon-dev lint`), script/tool surface wired, **sprint-check board visual render**, `CATALOG.md` drift, syntax checks (`bash -n`, `py_compile`) | Product-code logic/correctness, security, runtime behavior beyond board render | No repo workflow/setup/docs/skills/standards/scripts/tools changed |
| **doc-audit** | User-facing doc accuracy: overstated automation, missing prerequisites, absolute claims, scope inflation, internal consistency, affected-doc coverage, command accuracy, workflow-gate accuracy, heading case, **private content/PII** | Code correctness; doc *completeness* beyond accuracy; won't auto-write findings or redact without confirmation | No user-facing docs changed and no skill/standards frontmatter changed |
| **eval / evaluator** (fresh subagent, **binding**) | Each acceptance criterion + test-plan item graded pass/fail/partial from clean context against *actual changed files*, with `file:line` + quoted-text evidence; runs executable specs, renders visual criteria, rejects weak evidence. Any `partial` → `fail`; only `^pass:` closes | Anything outside `acceptance.md` scope (must not over-reach); the "Tested locally" QA checkbox; files outside the changed list; **semantic truth if the criteria themselves are wrong** | Trivial tier only (runs on bugfix/normal+) |
| **mutation-test** (advisory) | Test *sensitivity*: mutates logic and checks whether the suite fails; logs surviving mutants with `file:line` + the assertion needed | Semantic correctness (sensitivity ≠ truth); **never close-gated** | No logic files changed |

## What none of them check

Every gate above is either **static** or **diff-scoped** — none of them execute the running system,
make deployment/install-time trust decisions, or watch behavior over time. `security-review` states
this explicitly: it is a static, diff-scoped review that never runs the system, and "enforcement
lives in ongoing management, not at sign-in."

So install-time and runtime security — the concerns in an *AI extension security policy* (vetting an
MCP server before installing, deciding whether to grant a Skill Bash/Write access, reviewing what a
plugin bundles, minimum-permission tokens, production write-access, credential blast radius,
rate-limiting) — are **out of scope** for the close pipeline. The gates will catch a *diff* that
hardcodes a token or over-provisions a tool in code, but they will not make the trust decision to
install an extension, nor enforce anything at runtime. Per canon's own docs, that surface belongs to:

- the **human install decision** (canon does not self-merge; commit and push stay human-confirmed),
- [`docs/production-incident-playbook.md`](production-incident-playbook.md) — runtime posture,
  blast radius, and anomaly detection, and
- [`skills/ai-audit/SKILL.md`](../skills/ai-audit/SKILL.md) — the static AI-app risk surfaces
  (`agency-scope` / `resource-control` / `observability`).

## How gate results are recorded

At close, each gate is logged on the ticket's **Wrapup Gates** table as `ran` or `skipped`, always
with a one-line reason — a skip is a reasoned, auditable verdict, not a silent shortcut. The
`reviewer` and `eval` rows additionally record the model that ran them as `(model: <id>)`; which
model runs those two gates is decided by the rules in the README's
[Which model runs the close gates](../README.md#which-model-runs-the-close-gates) table and
[`complete.md`](../skills/sprint/reference/complete.md)'s "Model tier for gates."

The distinction that matters: the CLI mechanically enforces that the gates ran and that the binding
`evaluator` verdict is `pass`; the agents and evaluator judge whether the work behind the gates is
actually true. A gate that only ever passes is theatre; a gate that only ever fails is noise — canon's
are designed to do neither.
