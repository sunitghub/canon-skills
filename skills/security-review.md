---
name: security-review
description: Identify high-confidence, exploitable security vulnerabilities in code — not theoretical issues
category: skills
tags: [security, vulnerabilities, code-review]
hidden: true
---

# Security Review

## Confidence Threshold

Only report what meets HIGH or MEDIUM confidence:

| Level | Criteria | Action |
|---|---|---|
| HIGH | Vulnerable pattern + attacker-controlled input confirmed | Report with severity |
| MEDIUM | Vulnerable pattern, input source unclear | Note as "Needs verification" |
| LOW | Theoretical or best-practice only | Do not report |

## Do Not Flag

Test files, dead/commented-out code, constants, server-controlled config, code paths requiring prior auth, Django settings / env vars / framework constants.

## Pre-scan (ast-grep)

```bash
command -v ast-grep >/dev/null 2>&1 && echo "available" || echo "not installed"
```

If available, run over changed files (`--json` for structured output):

```bash
# Injection / unsafe exec
ast-grep -p '$F($$$ARGS, shell=True)' -l python --json
ast-grep -p 'exec.Command($CMD, $$$)' -l go --json

# Unvalidated input in queries
ast-grep -p 'f"$$$SELECT$$$WHERE$$$"' -l python --json
ast-grep -p '`$$$SELECT$$$${$VAR}$$$`' -l javascript --json

# Unsafe eval / innerHTML
ast-grep -p 'eval($INPUT)' -l javascript --json
ast-grep -p '$EL.innerHTML = $VAL' -l javascript --json

# Unsafe deserialization
ast-grep -p 'pickle.loads($DATA)' -l python --json
ast-grep -p 'yaml.load($DATA)' -l python --json
```

Adapt patterns to the languages in the changed files. If `scan-rules/` exists at repo root:

```bash
ast-grep scan --rule scan-rules/ --json 2>/dev/null
```

Hits are starting points, not confirmed vulnerabilities. If not available, skip silently and note: `ast-grep not installed — structural pre-scan skipped`.

## Process

1. Run pre-scan if ast-grep is available.
2. Trace data flow end-to-end before flagging.
3. Confirm attacker-controlled input reaches the vulnerable pattern.
4. Check for validation, sanitization, or framework mitigations.
5. Report only with exploitability evidence.

## Vulnerability Categories

Injection, XSS, authorization bypass, weak cryptography, unsafe deserialization, SSRF, CSRF, file security, broken authentication, business logic flaws, API security, misconfiguration, error handling leaks, sensitive data in logs.

## Action Endpoint Patterns

Check on every destructive or irreversible action (send, delete, bulk-update, job trigger, cache flush):

**1. UI-only access control** — hiding a UI element is not authorization. The server-side handler must enforce access control independently of UI state.

**2. Duplicate action triggers** — search for all bindings to the same endpoint. More than one path to a destructive action is a red flag unless every path enforces the same controls.

Detection by framework:
- **HTML forms**: grep for `action="/same-path"` or `method="post"` on multiple forms in the same template
- **ASP.NET Razor Pages**: grep `.cshtml` for `asp-page-handler="X"` and `action="?handler=X"`
- **Django**: grep templates for `action="{% url 'view-name' %}"` across all included partials
- **React/fetch**: grep for all `fetch`/`axios` calls to the same URL — a hook called from two components
- **Express**: grep route registrations for duplicate `router.post('/path', ...)`

## Language-Specific Patterns

- **Python** — Django, Flask, FastAPI: SQL via raw queries, template injection, unsafe deserialization formats, open redirects
- **JavaScript** — Express, React, Vue: prototype pollution, `eval`, dangerously set innerHTML, JWT misuse
- **Go** — `exec.Command` with user input, unsafe pointer use, goroutine races
- **Rust** — `unsafe` blocks, FFI boundaries, panics in production paths
- **Java** — Spring: deserialization, XXE, reflected input in responses
- **ASP.NET Razor Pages** — apply Action Endpoint Patterns above; additionally check `OnGet` handlers that mutate state (should be `OnPost`)

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
Issues where input source is unclear.

## Out of Scope
Patterns reviewed and ruled out (briefly).
```
