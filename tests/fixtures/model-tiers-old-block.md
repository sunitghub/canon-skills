<!-- MODEL-TIERS:BEGIN -->
## Model Tiers

Match model to the sprint work being done. `plan creation` and `grill` usually run inline
in the main session rather than as separate dispatches — the tier below still applies to
whichever session/dispatch does that work.

- `explore` → Haiku, thinking `minimal` — read-only, bounded search/mapping, no judgment calls.
- `plan creation` → Fable or Opus, thinking `medium`/`high` — needs design judgment before scope locks in.
- `implement` → Haiku/Sonnet, thinking `medium` — execution inside an approved plan. Without `advisor`
  configured on Sonnet+Opus, bump to Opus for high-risk sprints instead.
- `review` / `grill` → Opus, thinking `high` — adversarial, judgment-heavy; a weaker model would rubber-stamp.

The board's per-ticket `Gate model:` dropdown (`tools/sprint-check-app/app.html`) reads its live
option list from `tools/sprint-check-app/model-tiers.json` (Admin > Model Tiers, `t-7e36`) —
that file is a seeded, editable mirror of the Anthropic models named above, not a replacement for
this prose; the registry's OpenAI entries run close gates only per ticket, via `Gate model: openai:<id>` under Copilot CLI (`t-ef27`); the Admin OpenAI defaults stay recorded only.

**Close-gate effort** comes from canon's gate agent definitions (`agents/canon-reviewer.md`,
`canon-evaluator.md`: `effort: high`, a `claude-sonnet-5` model floor, read-only tools with `Bash`/`execute` shells), not from this prose.
A dispatch can set only the model, never effort (`t-c774`).

**Exception — sprint close gates** follow their own rule (may downgrade to the Admin > Model
Tiers "Review & Eval" default, applied unconditionally to every interactive close since
2026-09-23; to Haiku on a `demo: true` ticket, evaluator only; or via an explicit user
`Gate model:` override, which always wins) — see the
"Model tier for gates" note in `skills/sprint/reference/complete.md`, not this block.

**Cross-harness note.** Fresh-context dispatch is confirmed working under Codex
(`spawn_agent`/`wait_agent`/`close_agent`). Per-agent model selection is reconciled, not a flat
"unsupported": the live-observed `spawn_agent` call (`agent_type: "default"`) has no `model`
field — that part of the earlier live test holds. But Codex's own docs (learn.chatgpt.com,
checked 2026-09-22) describe a separate real path — a named custom subagent defined in a
`~/.codex/agents/*.toml` file with its own `model` field, which beats
`agents.default_subagent_model` when that named agent type is spawned. So a Haiku-style
downgrade IS achievable under Codex, but only via a predefined custom agent file, not an ad hoc
per-spawn choice on the generic `"default"` agent type. Until a custom agent file is actually
set up and tested live, an explicit `Gate model:` override or full-tier review remains the safe
default. For a **Pi** session,
close gates run on the pi session model, full stop — this file's general `review → Opus` tier
above is **not** the close-gate rule there; see `complete.md`'s pi-dispatch section for the
harness-scoped recipe.

**North-star (gate floor).** Only structural risk may reduce close gates, and a sprint never drops below the binding evaluator. The one documented exception is a user-set `demo: true` light-close (the evaluator still runs). The full policy — demo mode, the model tier for gates, and the north-star amendments — lives in `skills/sprint/reference/complete.md` (see also `DECISIONS.md` 2026-07-25 / 07-30 / 08-02).
<!-- MODEL-TIERS:END -->
