---
name: agent-design
description: Agent design principles for projects building LLM-powered software — own your prompts, context, control flow, and state. Add with skills.sh add agent-design.
category: agent-ops
tags: [agents, llm, prompts, context, control-flow, state]
inject: true
version: 1.0.0
updated: 2026-06-22
---

# Agent Design Principles

Distilled from [12-factor-agents](https://github.com/humanlayer/12-factor-agents). Apply when building LLM-powered workflows, not just using canon skills for your own dev process.

## Own Your Prompts

Treat prompts as first-class versioned code — review, test, and eval them like any other source file. Don't outsource prompt engineering to a framework's black-box config. Write the exact instructions your agent needs; vague role/goal/personality fields traded away control for convenience.

- Version prompts in source control alongside the code they drive.
- Build evals for prompts the same way you build tests for functions.
- A prompt change without an intent note is archaeology waiting to happen — log what failure or behaviour it was meant to fix.

## Own Your Context Window

The input to the LLM at each step is the primary quality lever. Shape it deliberately — don't let the framework decide what the model sees.

- Context = system instructions + injected data + prior tool calls + results + history. Control all four.
- Prefer token- and attention-efficient formats: dense structured text over verbose JSON where possible.
- Pre-fetch predictable context: if a tool call is nearly certain given the prompt, inline its result before the first LLM call rather than burning a round trip. Don't ask the model to fetch what you already know it needs.

## Compact Errors Into Context

Feed errors back into the context window so the LLM can recover on the next step — don't swallow them or surface them only to humans.

- Append error messages and stack traces as context events; let the model read and adapt.
- Cap consecutive errors (~3 attempts on the same tool call) before breaking the loop and escalating to a human. Unbounded retry loops spin out.
- Error compaction is composable with human escalation: hitting the cap is a natural trigger for `request_human_input`.

## Agent as Stateless Reducer

An agent is a pure function over an accumulated event log: `(events[]) → next_step`. All state lives in the log; nothing relies on in-memory mutable state across turns.

- Serialize the event log; resume from any point by loading it. Restart and resumability are free.
- Execution state (current step, waiting status, retry count) should be derivable from the log — avoid a separate execution-state store unless the log genuinely can't hold it.
- Forking and branching are structurally cheap: copy a prefix of the log into a new context.

## Own Your Control Flow

Write the loop yourself. Framework magic that decides when to pause, retry, or call a human is opacity you'll have to reverse-engineer at 80% quality.

- Build control structures that match your use case: some tool calls warrant a direct loop-continue; others warrant breaking out and waiting for a webhook.
- Pause between tool *selection* and tool *invocation* for high-stakes calls — this is the gate where human review is possible. Most frameworks don't expose this seam.
- Incorporate context compaction, rate limiting, tracing, and durable sleep as explicit steps in your control flow, not afterthoughts.
