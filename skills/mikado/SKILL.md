---
name: mikado
description: Maps the dependency tree for a refactor before changing code, using the Mikado Method — attempt the goal, revert on breakage, record prerequisites, execute leaves-first. Use when a refactor is likely to cascade into prerequisite changes or touch interdependent modules.
category: dev
tags: [refactoring, planning, dependencies, reversible]
---

# Mikado

Plan a cascading refactor as a dependency graph you discover by *attempting* it, so the tree
stays green at every step and nothing is half-migrated.

## When to Use

- A refactor likely to cascade: renaming or moving a widely-used symbol, extracting a module,
  inverting a dependency, replacing an API many callers touch, splitting a god-object.
- You are not sure what a change will break until you try it.

**Not for:** a self-contained one-file change with no dependents — that is a normal edit, not a
Mikado goal.

## The Method

1. **Set the Mikado Goal.** State the end refactor in one sentence (e.g. "PaymentService no
   longer imports the HTTP layer"). This is the root node.
2. **Attempt it naively.** Make the direct change toward the goal.
3. **Observe breakage.** Build, type-check, and run the tests. Compile errors, failing tests,
   and broken callers are the *prerequisites* the naive change revealed.
4. **If clean** (nothing breaks): the node is a leaf — keep it, mark it done.
5. **If broken:** for each breakage, write a **prerequisite node** — the change that must happen
   *first* — as a child of the current node. Then **revert the naive change immediately**
   (`git checkout -- <files>` / undo). Never leave the tree red between steps.
6. **Recurse.** Each prerequisite becomes a sub-goal; repeat steps 2–5 on it until you reach
   leaves — changes that break nothing on their own.
7. **Execute leaves-first.** Work bottom-up: do the deepest leaves, verify the tree is green
   after each, then move up toward the goal. If a step surprises you with a new breakage, add a
   new prerequisite node and revert — **do not push through**. The graph grows; the tree stays green.

The goal change is done *last*, and by then every prerequisite is already in place, so it applies
cleanly.

## The Mikado Graph (durable artifact)

The graph is the plan. Record it in `plan.md` under `## Approach` (or a `## Mikado` subsection).
Root = goal; children = prerequisites; check off leaves-first.

```
Goal: PaymentService no longer imports the HTTP layer
- [ ] Introduce a PaymentGateway interface in the domain
      - [ ] Move the HTTP client behind an adapter implementing PaymentGateway
            - [ ] Extract the request-building helper (leaf — no dependents)
      - [ ] Inject PaymentGateway into PaymentService via constructor
            - [ ] Add a constructor param with a default (leaf)
```

Execution order is deepest-first: the two leaves, then their parents, then the interface, then
the goal. Each checkbox is flipped only after the tree is verified green.

## Rules

- **Always revert on breakage.** A discovered prerequisite is recorded, not forced through.
- **The tree is green between every executed step** — never commit a half-migrated state.
- **The graph is the source of truth** for the change order; keep it in `plan.md`.
- Prefer many small reversible leaves over one large risky change.

## Boundaries

Mikado is a **planning aid only**. It produces the reversible change path and the graph; it
**touches no close gate**. Risk tiers and the sprint reviewer/evaluator gates are unchanged —
mikado decides *what order to change things in*, never *what verification runs*.

Inside a canon refactor sprint, run mikado during orient/plan and log the graph in `plan.md`.
It is also invokable standalone, outside a sprint, to produce a change plan.

## Triggers

| Agent | How to trigger |
|---|---|
| Claude Code | `/mikado <refactor goal>` |
| Codex / Pi | "Plan this refactor with mikado" / "Map the dependencies for <goal>" |
