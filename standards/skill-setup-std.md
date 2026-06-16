---
name: skill-setup-std
description: Validates skill files against canon standards. Use when adding a new skill or auditing existing ones.
category: agent-ops
tags: [skills, contributors, conventions]
version: 1.7.0
updated: 2026-06-16
---

# Skill Setup Standard

Rules for adding or modifying skills in canon. Follow these so every skill behaves predictably and the import graph stays clean.

## Validation

Run `./tools/canon-dev.sh lint` to validate all skills against these conventions. Fix any reported violations before committing. The linter checks: required frontmatter fields, `hidden` flag consistency, resolvable `depends` entries, and description quality.

## File Location

Skills follow a two-tier layout under `skills/`:

- **Standalone skills**: `skills/<name>/SKILL.md` — one directory per skill.
- **Hidden/internal skills**: `skills/<name>/SKILL.md` with `hidden: true` — same directory structure as standalone skills; may include `reference/` or `gates/` subdirectories for sub-skill files.

Standards, tools, and other non-skill files remain flat in their own top-level directories (`standards/`, `tools/`). Sub-skill content for a hidden skill belongs in a subdirectory of that skill (e.g. `skills/sprint/reference/`, `skills/wrapup/gates/`).

## Naming

- Lowercase, hyphenated directory name: `skills/sprint/`, `skills/context-check/`
- Use a prefix to signal a skill family: `sprint/`, `sprint-check/`
- Max ~20 characters — the directory name appears in `skills.sh list` output
- The **command name** (what you type after `/`) comes from the directory name, not frontmatter
- The `name:` frontmatter field is a **display label** shown in skill listings — it does not change the command name; by convention keep it matching the directory name for clarity
- The skill file is always named `SKILL.md`

## Frontmatter

Every skill requires these fields:

```yaml
---
name: my-skill
description: One sentence — what it does and when to use it.
category: dev | agent-ops | ops
tags: [tag1, tag2]
---
```

**Write descriptions for models, not just humans.** The `description` field is the primary signal Claude uses to decide when to invoke a skill. Include the action verbs and user intents that should trigger it.

**Always use third person.** The description is injected into the system prompt — first or second person causes discovery problems.

- Good: `"Manages the sprint workflow for focused changes. Use when asked to add, fix, or build anything."`
- Avoid: `"I can help you manage sprints"` or `"Use this to manage sprints"`

**Include what it does AND when to use it.** Both halves are required for accurate skill selection when many skills are loaded.

- Weak: `"Handles code quality tasks"` — no trigger signal, no scope
- Better: `"Runs quality checks and code review after completing a fix or feature. Use when work is done and ready to commit."`

Standalone skills need this most. Hidden skills (only called by parents) can use a simpler description since a human never selects them directly.

**Description length cap.** The combined `description` + `when_to_use` text is truncated at **1,536 characters** in the skill listing. Put the key use case first. Use `when_to_use` to offload additional trigger phrases rather than cramming them into `description`:

```yaml
when_to_use: "Also triggers on: 'summarize my diff', 'what did I change', 'write a commit message'."
```

Optional fields:

| Field | When to use |
|---|---|
| `when_to_use` | Additional trigger phrases or example requests appended to `description` in the listing; counts toward the 1,536-char cap |
| `argument-hint` | Autocomplete hint shown after the skill name, e.g. `[issue-number]` or `[filename] [format]` |
| `arguments` | Named positional args for `$name` substitution in skill content; space-separated string or YAML list |
| `disable-model-invocation: true` | Prevent Claude from auto-loading this skill; description is removed from context; only you can invoke it with `/name`. Use for side-effecting workflows (`/deploy`, `/commit`) |
| `user-invocable: false` | Hide from the `/` menu; Claude can still load it automatically. Use for background knowledge that isn't a meaningful user action |
| `allowed-tools` | Tools Claude can use without per-use approval while this skill is active; space- or comma-separated |
| `disallowed-tools` | Tools removed from Claude's pool during this skill's execution; clears on your next message |
| `model` | Model override for this skill's turn; reverts to session model on your next prompt |
| `effort` | Effort level override (`low`, `medium`, `high`, `xhigh`, `max`) while skill is active |
| `context: fork` | Run the skill in an isolated subagent; skill content becomes the subagent's prompt |
| `agent` | Subagent type to use when `context: fork` is set (e.g. `Explore`, `general-purpose`, or a custom agent name) |
| `hooks` | Hooks scoped to this skill's lifecycle (see On-demand hooks below) |
| `paths` | Glob patterns; skill only auto-activates when Claude is working with matching files. Useful for monorepo domain skills |
| `shell` | Shell for `` !`command` `` blocks: `bash` (default) or `powershell` |
| `summary:` | Longer description for CATALOG.md when `description:` is too short to convey scope |
| `depends: [skill-a, skill-b]` | Informational dependency list — queryable by `skills.sh lint`; not an injection mechanism |
| `hidden: true` | **Canon-linter-only convention** — see Standalone vs. hidden below |

## Degrees of freedom

Match the specificity of your instructions to how fragile the task is.

- **High freedom** (prose steps): use when multiple approaches are valid and context drives the decision. Example: code review, research synthesis.
- **Medium freedom** (pseudocode or parameterized scripts): use when a preferred pattern exists but some variation is fine.
- **Low freedom** (exact commands, no parameters): use when the operation is fragile, irreversible, or must follow a precise sequence. Example: database migrations, release steps.

A useful mental model: if failure on this step corrupts state or blocks others, give low freedom. If many paths lead to the same good outcome, give high freedom.

## Dynamic context injection

Use `` !`<command>` `` to run a shell command before Claude sees the skill — the output replaces the placeholder inline:

```markdown
## Current diff
!`git diff HEAD`

Summarize the changes above and flag any risks.
```

This is preprocessing, not something Claude executes. Claude only sees the final rendered output. Use this to inject live data (diffs, file lists, environment state) without requiring Claude to run a tool call first.

For multi-line commands, use a fenced block opened with ` ```! `:

````markdown
```!
node --version
git status --short
```
````

Use `${CLAUDE_SKILL_DIR}` to reference scripts bundled with the skill regardless of working directory:

```bash
!`python3 ${CLAUDE_SKILL_DIR}/scripts/analyze.py`
```

Other available substitutions: `$ARGUMENTS` (all arguments passed at invocation), `$ARGUMENTS[N]` / `$N` (positional by 0-based index), `${CLAUDE_SESSION_ID}`, `${CLAUDE_EFFORT}`.

## Arguments

Skills receive arguments via `$ARGUMENTS`. If a skill doesn't contain `$ARGUMENTS`, Claude Code appends `ARGUMENTS: <value>` to the end automatically.

```yaml
---
name: fix-issue
disable-model-invocation: true
---

Fix GitHub issue $ARGUMENTS following our coding standards.
```

Invoked as `/fix-issue 123` → Claude sees "Fix GitHub issue 123 following our coding standards."

For named positional args, declare them in frontmatter:

```yaml
arguments: [issue, branch]
```

Then use `$issue` and `$branch` in the body. The `argument-hint` field drives autocomplete: `argument-hint: "[issue-number]"`.

## Loading dependencies

Load sub-skills on demand rather than at invocation time. At the step that first needs a dependency, add an explicit instruction:

```
Read `skills/sprint/reference/orient.md`, then run the orient protocol: ...
```

This keeps the always-on context budget proportional — a trivial sprint doesn't pay for wrapup, orient, or impact-analysis.

`@` imports (formerly declared after frontmatter) are retired. Do not add new `@` lines to skill files.

## Progressive disclosure

SKILL.md is a table of contents, not an encyclopedia. Keep it under **500 lines**. Split content into reference files when approaching that limit.

**Patterns:**
- **Pattern 1 — Guide with references**: SKILL.md contains quick-start content and links to deeper files (`See [REFERENCE.md](REFERENCE.md) for full API`). Claude loads reference files only when needed.
- **Pattern 2 — Domain-specific**: organize sub-skill content by domain in a subdirectory (`reference/`, `gates/`). When a task touches one domain, only that file loads. Canon uses this for `skills/sprint/reference/` and `skills/wrapup/gates/`.
- **Pattern 3 — Conditional details**: show basic content inline; link to advanced content only when the user needs it.

**Rules:**
- Keep references **one level deep** from SKILL.md. Nested references (`SKILL.md → A.md → B.md`) cause Claude to partially read files and miss content.
- For reference files longer than **100 lines**, add a table of contents at the top so Claude can see the full scope even when previewing.
- Name reference files descriptively (`form-validation-rules.md`, not `doc2.md`).

## Standalone vs. hidden

A skill is **standalone** if a user registers it via `skills.sh add` and invokes it directly. It should work without knowing what imports it.

A skill is **hidden** (`hidden: true`) if it is never registered by the user — either because it is only called by another skill, or because it is only ever auto-invoked by Claude based on context (never via `/name`). Document this clearly at the top of the file body: `Called automatically by X — do not invoke directly.`

The registration test is the reliable signal: if `skills.sh add <name>` is a meaningful user action, it's standalone. If no user would register it directly — because it's a sub-skill or a context-triggered specialist — mark it hidden.

If a skill is useful both ways, make it standalone and let the parent import it.

**`hidden: true` is a canon-linter convention**, not a platform field. The Claude Code platform uses two separate fields with distinct behavior:

| Intent | Platform field | Effect |
|---|---|---|
| Block user invocation, Claude can still load | `user-invocable: false` | Hidden from `/` menu; description stays in context |
| Block Claude auto-load, user can still invoke | `disable-model-invocation: true` | Description removed from context; user invokes with `/name` |
| Block both (internal sub-skill) | both fields | Hidden everywhere |

`hidden: true` in canon frontmatter signals intent to `skills.sh lint` — the linter checks consistency but the platform ignores the field. For new skills, prefer the explicit platform fields when you need runtime enforcement.

## One job

A skill that does two things is two skills waiting to be separated. If you find yourself writing "and then" in the description, split it. `skills.sh lint` flags an "and then" in a leaf skill's description; orchestrators (skills with a `depends:` list) are exempt because composing children is their job.

Composition is fine — a parent skill imports children and orchestrates them. But each child should be coherent on its own.

## Minimal content

A skill is instructions for an agent, not a manual. Write the smallest body that makes the behavior unambiguous:

- State the job, the steps, and the stop condition. Cut everything else.
- No restating canon-wide standards — `@`-import them instead of copying.
- No motivational preamble, no "why this matters" essays, no duplicated examples.
- If a section does not change what the agent does, delete it.
- **Hard limit: 500 lines** for SKILL.md body. Beyond this, split into reference files (see Progressive disclosure).

Length is a smell, not a limit: a leaf skill that runs long is usually doing more than one job (see above) or repeating context it should import.

## Content guidelines

**No time-sensitive information.** Don't write "before August 2025, use the old API." Put legacy behavior in a collapsible "Old patterns" section instead — it provides context without cluttering the main flow.

**Consistent terminology.** Pick one term per concept and use it throughout. Mixing "endpoint" / "URL" / "route" / "path" forces the agent to infer equivalence instead of following instructions. Inconsistency is a common source of agent errors.

**Offer one default, not a menu.** Don't list three valid libraries and let the agent pick. Choose one and note the escape hatch:

- Good: "Use pdfplumber for text extraction. For scanned PDFs requiring OCR, use pdf2image with pytesseract instead."
- Avoid: "You can use pypdf, pdfplumber, PyMuPDF, or pdf2image depending on your needs."

A menu forces a decision at runtime; a default with an escape hatch is a decision made once.

## Gotchas

Add a `## Gotchas` section to any skill where real usage has revealed failure patterns — edge cases, footguns, or non-obvious constraints that caused problems. This is the highest-signal section a skill can have; keep it growing.

Format: one bullet per gotcha, led by the condition and followed by what to do instead.

```markdown
## Gotchas

- If `sprint start` reports the wrong ticket ID, `.tickets/` state may be out of sync — run `tkt ls` to inspect before retrying.
- `sprint complete` refuses if any `- [ ]` remain in `acceptance.md` — check boxes manually or waive with a documented reason.
```

Start with zero entries and add as problems surface. A skill without gotchas isn't wrong — it just hasn't been used enough yet.

Seed gotchas to consider for new skills:

- If the skill seems to stop influencing behavior mid-session, the content is still present but compaction may have trimmed it — after compaction each skill gets at most 5,000 tokens carried forward (shared 25,000-token budget across all invoked skills). Re-invoke the skill to restore full content.
- Skill content enters context as a single message on invocation and stays for the rest of the session. Write standing instructions, not one-time steps, for guidance that should apply throughout a task.

## On-demand hooks

For skills that need to restrict agent behavior (block dangerous commands, lock edits to specific paths), prefer the `disallowed-tools` frontmatter field — it removes named tools from Claude's pool for the duration of the skill without any hook registration or cleanup:

```yaml
disallowed-tools: Bash(rm *) Bash(git push --force *)
```

The restriction clears automatically when the user sends their next message.

For more complex runtime enforcement (path-scoped locks, conditional blocking, cross-turn restrictions), implement the restriction as a `hooks` entry in the skill frontmatter:

```yaml
hooks:
  - type: PreToolUse
    matcher: "Bash"
    command: "echo 'Blocked in careful mode'"
```

This keeps the hook scoped to the skill's lifecycle rather than always-on.

Document any restrictions clearly at the top of the skill so users know what is being restricted and for how long.

## Update vs. new skill

A nuance to address is first a decision: does it edit an existing skill or become a new one? Apply the one-job test.

- **Edit in place** when the nuance changes *how* a skill already does its single job — a sharper step, a new edge case, a corrected instruction.
- **New skill** when the nuance is a *distinct* job. If describing the change makes you write "and then," or the skill's `description` would stop being one coherent sentence, split it out.

When in doubt, prefer editing — a new skill earns its place only when it has a coherent standalone job (see "Standalone vs. hidden"). If the file carries `version:` / `updated:` frontmatter (standards do; skills usually do not), bump them in the same edit.

## Testing

Every skill should ship with at least two execution eval test cases. These live in `skills/<name>/evals/evals.json` and are run via the `skill-eval` skill.

**Format:**

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "The user prompt that should trigger the skill's behavior",
      "expected_output": "Human-readable description of what a correct response looks like",
      "expectations": [
        "The response includes X",
        "The skill performed step Y",
        "Output format matches Z"
      ]
    }
  ]
}
```

**Running evals:**

```bash
/skill-eval <name>
```

This spawns an executor subagent (fresh context, skill content injected) and a grader subagent per eval case, then reports pass/fail per expectation.

**Coverage — case types:** Aim to cover at least three of these five types across your eval set:

| Case type | What it tests |
|---|---|
| `control` | Happy path — basic correct behavior |
| `edge` | Capability boundary — unusual input the skill may mishandle |
| `compliance` | Does the skill follow its own rules and constraints? |
| `boundary` | Does it know when NOT to handle something (escalate, decline, stop)? |
| `over-caution` | Does it avoid refusing or hedging when it shouldn't? |

Add an optional `case_type` field to each eval to document coverage:

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "case_type": "control",
      "prompt": "The user prompt that should trigger the skill's behavior",
      "expected_output": "Human-readable description of what a correct response looks like",
      "expectations": [
        "The response includes X",
        "The skill performed step Y",
        "Output format matches Z"
      ]
    },
    {
      "id": 2,
      "case_type": "boundary",
      "prompt": "A prompt that should cause the skill to decline or escalate",
      "expected_output": "Skill declines and explains why, or routes to the right handler",
      "expectations": [
        "Did not attempt to handle the request directly",
        "Provided a reason or next step"
      ]
    }
  ]
}
```

`case_type` is optional and author-facing — `skill-eval` does not filter by it. Its value is coverage awareness: if all your evals are `control`, you probably have blind spots.

**What to test:** Expectations should be explicit, binary, numbered criteria — assertions the grader can verify unambiguously from the executor's output. Write them as observable facts: "writes to HANDOFF.md", "does not print to stdout", "includes the ticket ID in the first line". Avoid prose that requires interpretation ("handles it correctly", "responds appropriately").

**Out of scope:** Trigger eval (whether the skill fires for the right description) and benchmark/improve modes. For those, see [skill-creator](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md).

## Adding a new skill

1. Create a directory `skills/<name>/` and write the skill as `skills/<name>/SKILL.md`; add `hidden: true` if it is only invoked by other skills
2. Run `skills.sh list` to confirm it appears with the right name and description
3. Update `CATALOG.md` by running `skills.sh catalog` (or manually if the script doesn't support it)
4. If the skill is imported by an existing skill, add it to that skill's `depends:` list
5. If it's standalone, document it in README.md if it warrants a mention
6. Write at least 2 eval test cases in `skills/<name>/evals/evals.json` and run `/skill-eval <name>` to verify
