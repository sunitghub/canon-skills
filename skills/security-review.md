---
name: security-review
description: Identify high-confidence, exploitable security vulnerabilities in code — not theoretical issues
category: skills
tags: [security, vulnerabilities, code-review]
---

# Security Review

Systematically identify exploitable security vulnerabilities. Report only high-confidence findings — skip theoretical issues and framework-mitigated patterns.

## Getting Started

**Step 1 — Register this skill in your project:**
```bash
~/Developer/AI-Skills/skills.sh add security-review /path/to/your/project
```

**Step 2 — Verify:**
```bash
~/Developer/AI-Skills/skills.sh status /path/to/your/project
```

**Step 3 — Use it:**
- **Claude**: "Run a security review" or "Security review my changes."
- **Codex**: "Run a security review."

The agent traces data flow before flagging anything — no noisy pattern-match reports. Findings come back with location, evidence, and a concrete fix.

> Tip: Use `polish` instead if you want simplify + review + security in one go after finishing a task.

## Confidence Threshold

Only report what meets HIGH or MEDIUM confidence:

| Level | Criteria | Action |
|---|---|---|
| HIGH | Vulnerable pattern + attacker-controlled input confirmed | Report with severity |
| MEDIUM | Vulnerable pattern, input source unclear | Note as "Needs verification" |
| LOW | Theoretical or best-practice only | Do not report |

## Do Not Flag

- Test files (unless explicitly asked)
- Dead, commented-out, or documentation code
- Patterns using constants or server-controlled config
- Code paths requiring prior authentication
- Django settings, env vars (`os.environ.get()`), framework constants — these are safe by design

## Process

1. Trace data flow end-to-end before flagging anything.
2. Confirm attacker-controlled input reaches the vulnerable pattern.
3. Check for validation, sanitization, or framework mitigations along the path.
4. Only then report — with exploitability evidence, not pattern matches alone.

## Vulnerability Categories

Injection, XSS, authorization bypass, weak cryptography, unsafe deserialization, SSRF, CSRF, file security, broken authentication, business logic flaws, API security, misconfiguration, error handling leaks, sensitive data in logs.

## Language-Specific Patterns

- **Python** — Django, Flask, FastAPI: SQL via raw queries, template injection, unsafe deserialization formats, open redirects
- **JavaScript** — Express, React, Vue: prototype pollution, `eval`, dangerously set innerHTML, JWT misuse
- **Go** — `exec.Command` with user input, unsafe pointer use, goroutine races
- **Rust** — `unsafe` blocks, FFI boundaries, panics in production paths
- **Java** — Spring: deserialization, XXE, reflected input in responses

## Severity Classification

- **Critical** — direct exploit, severe impact, no auth required
- **High** — exploitable with some conditions, significant impact
- **Medium** — requires specific conditions, moderate impact
- **Low** — defense-in-depth gap, minimal direct impact

## Report Format

```
## Findings

### [SEVERITY] Title
- **Location**: file:line
- **Pattern**: what the vulnerable code does
- **Evidence**: why attacker input reaches it
- **Impact**: what an attacker can do
- **Fix**: concrete remediation

## Needs Verification
Issues where input source is unclear — flag for human review.

## Out of Scope
Patterns reviewed and ruled out (briefly, to show coverage).
```
