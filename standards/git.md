---
name: git
description: Commit, branch, and PR conventions
category: standards
tags: [git, commits, branches, pull-requests]
---

# Git & Commit Conventions

## Getting Started

**Step 1 — Register this skill in your project:**
```bash
~/Developer/AI-Skills/skills.sh add git /path/to/your/project
```

**Step 2 — Verify:**
```bash
~/Developer/AI-Skills/skills.sh status /path/to/your/project
```

**Step 3 — Use it:**

No invocation needed. Once registered, Claude and Codex follow these conventions automatically — commit messages, branch names, PR structure — without being asked.

## Commits

- Message format: imperative mood, present tense ("Add X", "Fix Y", "Remove Z").
- First line under 72 characters.
- Focus the message on WHY, not what (the diff shows what).
- Never skip hooks (`--no-verify`) without explicit user instruction.
- Prefer new commits over amending published commits.
- Stage specific files — never blind `git add -A` that might catch secrets.

## Branches

- `main` / `master` — protected, no direct force-push.
- Feature branches: `feat/short-description`
- Fix branches: `fix/short-description`

## Pull Requests

- Keep scope tight — one concern per PR.
- PR title under 70 characters.
- Body: summary bullets + test plan checklist.
- Don't push to remote unless explicitly asked.

## Safety

- Never run destructive git commands (reset --hard, push --force, branch -D) without explicit user instruction.
- When in doubt about irreversible operations, ask first.
