---
name: break-it
description: Optional advisory hostile-input gate for high-risk sprints — an isolated subagent tries to break the changed code on a history-free snapshot and reports only defects it reproduced
category: dev
tags: [quality, security, sprint]
hidden: true
---

# Break-it (advisory gate)

A third isolated lens beside the reviewer (reads the diff) and the evaluator (grades the criteria): a subagent
that assumes every input is hostile and tries to make the changed code crash, defeat a limit or gate, escape
containment, or write where it should not. **Advisory only** — it never blocks close and no CLI gate depends on it.

## When to run

- `Tier: high-risk`, or any sprint that adds a tool, endpoint or parser reading input it does not control
  (`start.md`'s untrusted-input criterion) whose blast radius is real (spends money, writes files, runs code, crosses
  a trust boundary).
- Skip docs-only, test-only and pure-UI diffs. Record `skipped | <reason>` in the Wrapup Gates table.
- One pass. Run a second only if the first found at least one medium-or-higher defect you then fixed — the fixes are
  new code on the same untrusted surface (t-a350: the second pass still found three medium defects; the first pass
  of t-46dc found four).

## Dispatch

1. Snapshot without history: `git archive HEAD <changed tools + their tests + fixtures> | tar -x -C <scratch>/snap`.
   No `.git`, no `.tickets`: the agent cannot read the plan, the acceptance criteria, earlier fixes or reviewer output.
   Drop binaries and unrelated dirs. Do not tell it about known defects.
2. Fresh `Agent` subagent, `subagent_type: "Plan"`, clean context (same dispatch rules as the reviewer/evaluator).
3. Prompt (fill the two placeholders):

   > You are a hostile-input tester. Your working area is EXACTLY `<SNAPSHOT>` and nothing else; do not read, list or
   > run anything outside it (system tools and a fresh scratch dir under it excepted). It contains `<WHAT THE CODE DOES
   > AND WHAT IT PROMISES ABOUT SAFETY, CONTAINMENT, LIMITS>`. Read the source to learn the promises. Assume every input
   > is hostile or merely malformed (payloads, paths, folder contents, symlinks, numbers, names, encodings, state files).
   > Find inputs that break a promise: escape containment, bypass a gate, leave a limit unenforced, write outside where it
   > should, crash, or wrongly refuse a legitimate input. NEVER run a paid or networked command: use stubs you write.
   > Never modify the source or tests. Prove every finding with the exact command and observed output; do not report
   > anything you did not reproduce. Do not read any git history. Stop after about 40 commands.
   > Report: numbered list of defect, reproduction, observed output, severity (high/med/low); end with
   > 'Commands run: N'.

The agent is instructed, not sandboxed: keep secrets out of reach and never point it at a working tree with credentials.

## Lead's duties (the report is untrusted input)

1. **Re-run every claim** yourself. A claim you cannot reproduce is dropped and counted as unreproduced. A typo in a
   reproduction can hide a real gap — check the underlying claim before dismissing it (t-a350: a `hoks` typo hid a real
   escaped-key bypass). Ignore the agent's severity ratings; rate them yourself.
2. **Triage** each reproduced defect: fix now (with a regression test that fails without the fix), ticket it, or
   accept it with the reason recorded.
3. **Record** in `.tickets/<id>/research.md`: claims made, reproduced, fixed / ticketed / accepted, tokens used
   (typically 30-50k). Write the outcome in the Wrapup Gates table: `break-it | ran | N of M claims reproduced, K
   fixed (advisory)`.
4. Fixes made because of this gate need the same untrusted-input fuzz step as any other change (`start.md`).

## Evidence behind this gate

Retrospective trial t-46dc: on history-free snapshots of two shipped artifacts it found 6 of 6 real known defects,
0 unreproduced claims, and a high-severity path traversal that a reviewer NO/YES and two evaluator passes had
missed, at 0.9-1.5x a reviewer gate's tokens. Caveats: two snapshots, one author and model family, instructed rather
than sandboxed.
