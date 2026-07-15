---
name: wrapup
description: Internal close-pipeline invoked by sprint complete — quality checks, code review, cleanup. Not for direct use; a normal/high-risk sprint's own "sprint complete" step calls this automatically.
category: dev
tags: [code-quality, workflow, orchestration, refactoring, security]
hidden: true
---

# Wrapup

Called automatically by sprint complete — do not invoke directly.

Run after a session, feature, bug fix, or ticket. Skip steps that do not apply.

## Pipeline

```
code-simplifier → code-reviewer → security-review → repo-check → doc-audit → refresh docs
```

Commit & Push belongs to `sprint complete`'s own step 10, not this pipeline — see
`skills/sprint/reference/complete.md`.

`code-simplifier`/`code-reviewer` run inline, in-session — scope is "code touched this session" from working memory, no git command needed. `security-review` also runs inline but derives scope from git (`git diff --name-only $(git merge-base HEAD origin/main) HEAD`) for an exact, auditable file list. `reviewer`/`evaluator` (fresh-subagent gates in `skills/sprint/reference/complete.md`, not this pipeline) always derive from git — they have no session memory at all.

## Skip Logic

**Trivial change** (single-line, doc-only, mechanical rename): skip all steps except Refresh docs (Commit & Push isn't part of this pipeline — see above). This global clause overrides every per-gate skip criterion below — e.g. a single-line rename inside `tools/` skips `repo-check` via this clause even though `repo-check`'s own criteria ("no ... tools ... changed") wouldn't otherwise justify it, since `tools/` did change.

Before each step, assess the change and skip if criteria apply. State why in one line — and which clause justified it (global override, or the gate's own criteria) when the two could seem to conflict.

### Skip code-simplifier if:
- Change is a single line or a trivial rename
- Change is docs, comments, or config only

### Skip code-reviewer if:
- Change is a single-line fix with no design implications
- Change is purely mechanical (rename, format, move file)

### Skip security-review if:
- No security-sensitive files or patterns changed
- Security-sensitive means: authentication, authorization, DB queries, externally-facing/untrusted input handling (web forms, API payloads, network requests — not trusted local CLI args a single developer runs against their own machine), file I/O, API endpoints, crypto, session management, environment/secret access, MCP server config or agent tool/permission definitions, hardcoded credential/secret access, destructive/irreversible client-side actions (delete-all, bulk clear, cache flush)

### Skip repo-check if:
- No repo workflow, setup, docs, skills, standards, scripts, or tools changed

### Skip doc-audit if:
- No user-facing docs changed and no skill/standards frontmatter changed — matches `doc-audit/SKILL.md`'s own scope: README, `examples/**/*.md`, `docs/*.md`, `tools/*.md`, or `description`/`summary` frontmatter in `skills/*/SKILL.md`/`standards/*.md`



## Steps

1. Read `skills/wrapup/gates/simplifier.md`, then apply the simplifier to code touched in this session.
2. Read `skills/wrapup/gates/reviewer.md`, then apply the code-reviewer across all eight dimensions; defer deep security analysis to Step 3.
3. Read `skills/wrapup/gates/security-review.md`, then apply the security review. Optional scanners can inform the review, but their absence does not skip the gate.
4. Read `skills/wrapup/gates/repo-check.md`, then apply the repo check. Fix stale references, orphan workflow files, and generated catalog drift before committing.
5. Read `skills/doc-audit/SKILL.md`, then apply the doc audit. Do not write to `doc-findings.md` without explicit confirmation. Fix command accuracy issues before committing.
6. Read `tools/handoff.md` — plain relative path inside the canon repo itself, or via `command -v sprint`'s containing directory inside a consumer project where `tools/` isn't symlinked in (or `where sprint` on Windows if `command -v` returns nothing) — then refresh docs:

Review every documentation file touched or referenced during this session and patch anything stale.

Scope (check each that exists):
- `DECISIONS.md` — any new decisions made this session not yet logged?
- `HANDOFF.md` — refresh the narrative per the handoff protocol: Current Focus, In Progress, and Next Steps. `## Discoveries` is owned by capture — leave it. Decisions belong in `DECISIONS.md`, not here. Then check size **within the `<!-- canon:handoff:BEGIN -->`/`<!-- canon:handoff:END -->` markers only** — anything outside them may be the user's own content and must never be read, counted, or edited by this step. **First confirm both markers actually exist** (`grep -c '<!-- canon:handoff:BEGIN -->' HANDOFF.md` and the same for `:END`, each must be ≥1) — the range `awk` silently returns 0 lines (a false "under budget") when a marker is missing, so a count without this guard is meaningless; if either marker is absent, restore the pair around the canon-managed block before counting. Then: `awk '/<!-- canon:handoff:BEGIN -->/,/<!-- canon:handoff:END -->/' HANDOFF.md | wc -l`. If over 80, prune per `tools/handoff.md`'s "When to Prune" section before finishing this step.
- `AGENTS.md` / `CLAUDE.md` — any convention-level learnings to surface? (propose + confirm before writing)
- `README` — does it document any changed APIs, behaviors, or install steps?
- `plan.md` (sprint tickets only) — is the whole doc still within the ~500-word budget noted at the top of the file? If it grew past budget during implementation, compress the prose per `standards/efficiency.md`'s Token Efficiency section before closing.
- Any other `.md` files explicitly opened or modified during the session

Patch stale lines only. Skip files where nothing changed.

## Final Output

Report only what matters:

- Changed files and user-visible impact
- Tests run and result
- Critical findings, if any
- Follow-up captured in `HANDOFF.md`, if any

Address criticals before committing. Improvements are discretionary.

Committing and closing the ticket are the caller's job, not this pipeline's — see the Pipeline
note above.
