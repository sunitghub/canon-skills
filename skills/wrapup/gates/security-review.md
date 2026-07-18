---
name: security-review
description: Identify high-confidence exploitable vulnerabilities in code
category: dev
tags: [security, vulnerabilities, code-review]
hidden: true
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git merge-base:*), Bash(git rev-list:*), Read, Glob, Grep, LS
---

# Security Review

## Scope

If an explicit `Base ref` was passed (headless CI dispatch grading an existing PR/diff), run `git diff --name-only <base-ref> HEAD`. Otherwise (normal interactive close), run `git diff --name-only $(git merge-base HEAD origin/main) HEAD` — the same base ref every other close gate uses by default. (Same base-ref branching as `shared-gate-protocol.md` — mirror, keep in sync; locked against it by `tests/doc-mirror-parity.sh` Checks A/D.) Analyze only the resulting changed files — do not scan the full codebase.

If that fails — `origin/main` does not exist (no remote, detached HEAD) **or** the directory is not a git repository at all — fall back in two tiers, same as `shared-gate-protocol.md` (mirror — keep in sync):
- If `HEAD` resolves (the repo has ≥1 commit): diff against the repo's first commit instead — `git diff --name-only $(git rev-list --max-parents=0 HEAD) HEAD`, plus untracked files (`git status --porcelain`) — and scan those real changed files.
- If `HEAD` does not resolve (zero commits) or git itself is unavailable: log a warning noting no git baseline is available and scan every file currently in the working tree (excluding `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next`) rather than falling back to `.tickets/<id>/plan.md ## Files` — this gate needs actual source to scan for vulnerabilities, not a file-name list.

## Confidence Threshold

Report only HIGH or MEDIUM confidence:

| Level | Criteria | Action |
|---|---|---|
| HIGH | Vulnerable pattern + attacker-controlled input confirmed | Report with severity |
| MEDIUM | Vulnerable pattern, input source unclear | Note as "Needs verification" |
| LOW | Theoretical or best-practice only | Skip |

## Do Not Flag

Test files, dead/commented code, constants, server-controlled config, code paths requiring prior auth, Django settings, env vars, framework constants.

Additionally exclude:
- Denial of Service, rate limiting, or resource exhaustion issues
- Environment variables and CLI flags — treat as trusted; attackers generally cannot modify them
- Regex injection or regex DoS
- React/Angular XSS — these frameworks are safe by default; only flag if using `dangerouslySetInnerHTML`, `bypassSecurityTrustHtml`, or equivalent unsafe methods
- Command injection in shell scripts — only flag with a concrete, specific attack path for untrusted input
- Log spoofing or logging un-sanitized user input to logs
- Missing audit logs
- Lack of hardening measures — flag concrete vulnerabilities only, not absent best practices
- Vulnerabilities only in `*.ipynb` notebooks unless there is a concrete attack path for untrusted input

## Optional Scanner Evidence

If the repo already provides a scanner or rule set, run it when it is relevant to
the changed files. Scanner hits are leads, not findings; trace exploitability
before reporting. If no scanner is available, note `optional scanner unavailable`
and continue with manual review. Scanner absence is not a skipped security gate.

## Process

1. Use available scanner output as leads when relevant; otherwise proceed manually.
2. Trace data flow end-to-end before flagging.
3. Confirm attacker-controlled input reaches the vulnerable pattern.
4. Check for validation, sanitization, or framework mitigations.
5. Report only with exploitability evidence.

## Vulnerability Categories

Injection, XSS, authorization bypass, weak crypto, unsafe deserialization, SSRF, CSRF, file security, broken auth, business logic flaws, API security, misconfiguration, error leaks, sensitive logs, agent/MCP security (permission scope, tool over-provisioning, MCP server config exposure), secrets (hardcoded credentials, API keys, tokens).

## Action Endpoint Patterns

Check every destructive or irreversible action: send, delete, bulk-update, job trigger, cache flush.

**1. UI-only access control** — server handlers must enforce authorization independently of UI state.

**2. Duplicate action triggers** — find every binding to the same endpoint; each path must enforce the same controls.

Detection by framework:
- **HTML forms**: grep for `action="/same-path"` or `method="post"` on multiple forms in the same template
- **ASP.NET Razor Pages**: grep `.cshtml` for `asp-page-handler="X"` and `action="?handler=X"`
- **Django**: grep templates for `action="{% url 'view-name' %}"` across all included templates
- **React/fetch**: grep for all `fetch`/`axios` calls to the same URL — a hook called from two components
- **Express**: grep route registrations for duplicate `router.post('/path', ...)`

## Language-Specific Patterns

- **Python** — Django, Flask, FastAPI: SQL via raw queries, template injection, unsafe deserialization formats, open redirects
- **JavaScript** — Express, React, Vue: prototype pollution, `eval`, dangerously set innerHTML, JWT misuse
- **Go** — `exec.Command` with user input, unsafe pointer use, goroutine races
- **Rust** — `unsafe` blocks, FFI boundaries, panics in production paths
- **Java** — Spring: deserialization, XXE, reflected input in responses
- **ASP.NET Razor Pages** — apply endpoint checks; flag mutating `OnGet` handlers

## Severity Classification

- **Critical** — direct exploit, severe impact, no auth required
- **High** — exploitable with some conditions, significant impact
- **Medium** — requires specific conditions, moderate impact
- **Low** — defense-in-depth gap, minimal direct impact

## Report Format

```
## Findings

### [SEVERITY] Title
- **Location**: `file:line — \`quoted vulnerable snippet\`` — the exact line(s) containing the pattern
- **Pattern**: what the vulnerable code does
- **Evidence**: why attacker input reaches it
- **Impact**: what an attacker can do
- **Fix**: concrete remediation

## Needs Verification
Issues where input source is unclear.

## Out of Scope
Patterns reviewed and ruled out (briefly).
```
