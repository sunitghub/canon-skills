# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `<id>`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->

- [ ] Plan approved — proceed to implementation

## Detect

What triggered this? (metric drop, test failure, automated alert — not a user complaint)

## Diagnose

Root cause: data problem, prompt problem, or model drift?
Where did correct → wrong? (file:line or pipeline stage)

## Contain

Blast radius: what is currently affected?
Rollback available? (prompt version, config, feature flag)
Containment action taken before fix:

## Fix

Targeted change (not a 3am hotfix):
New test case added for this exact failure:
Promotion process followed?

## Prevent

Eval coverage expanded — what case was added?
What would have caught this earlier?
Append a row to `bugs/patterns.md`: symptom, root cause category, fix pattern, ticket reference.

## Decisions
<!-- Record non-obvious tradeoffs and why. Keep this heading unchanged. -->
