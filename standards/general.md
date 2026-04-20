---
name: general
description: Language-agnostic coding principles and security rules
category: standards
tags: [coding, quality, security]
---

# General Coding Standards

## Getting Started

**Step 1 — Register this skill in your project:**
```bash
~/Developer/AI-Skills/skills.sh add general /path/to/your/project
```

**Step 2 — Verify:**
```bash
~/Developer/AI-Skills/skills.sh status /path/to/your/project
```

**Step 3 — Use it:**

No invocation needed. Once registered, Claude and Codex apply these standards automatically to every piece of code they write or modify in this project.

## Principles

- Prefer editing existing files over creating new ones.
- Delete dead code completely — no commented-out blocks, no `_unused` renames.
- No feature flags or backwards-compat shims when you can just change the code.
- No docstrings/comment blocks for things well-named identifiers already convey.
- No multi-line comment explanations of WHAT the code does.

## Security

- Never introduce: command injection, XSS, SQL injection, or other OWASP top 10 issues.
- If insecure code is written, fix it immediately.
- Never commit secrets, credentials, or `.env` files.

## Dependencies

- Don't add dependencies for problems solvable with existing tools.
- Prefer stable, well-maintained packages.

## Testing

- Write tests at system boundaries, not for internal implementation details.
- Don't mock what you can integration-test cheaply.
- A passing test suite verifies code correctness — not feature correctness. Test both.
