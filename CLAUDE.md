# canon: Claude Code config

Anthropic-only, canon-scoped. Universal cross-agent rules live in [AGENTS.md](AGENTS.md); this file holds what only Claude Code should see.

## Advisor

A stronger advisor model is on call for canon's judgment moments — not mechanical edits.

Consult the advisor before:
- An intent-coherence verdict — does this cohere with minimalism? (memory: `canon-core-intent`)
- Rating five-dimension impact, or deciding a HIGH forces mitigation (`docs/sprint-check.md`)
- Changing a gate or state-machine rule in `tools/`
- Closing a sprint (`sprint complete`) — call it after the deliverable is written, before the gate

Give its advice weight; if your evidence contradicts it, surface the conflict in one more call rather than silently switching. Skip it for doc tweaks, HANDOFF refreshes, and skill registration.

## Wrapup extension (canon-only)

After wrapup step 5 (doc-audit), run repo-audit when `skills/`, `standards/`, `tools/`, `scripts/`, or `guides/` changed — or on any high-risk sprint. If any dimension rates Generic, Contradicted, or Broken: resolve before committing, or log a deferral with justification in `DECISIONS.md`.
