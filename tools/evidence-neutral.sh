#!/usr/bin/env bash
# evidence-neutral.sh — the one list of evidence-neutral paths (t-a3d7), sourced by tools/evidence.sh and scripts/test.sh --changed
# (t-2633). These are written at close and read by no test (tests/evidence.sh greps the suite to prove it), so a change to them cannot
# change what a stamped command saw, and a fast pass need not run anything for them. Repo root only, as git pathspecs. Narrower than
# the stale-eval guard's late-doc list in tools/sprint on purpose: tests read the root AGENTS.md and CLAUDE.md, and dist/ holds built
# binaries.
NEUTRAL=(':(exclude).tickets' ':(exclude,literal)LEARNINGS.md' ':(exclude,literal)LEARNINGS-archive.md' ':(exclude,literal)DECISIONS.md'
  ':(exclude,literal)DECISIONS-archive.md' ':(exclude,literal)HANDOFF.md' ':(exclude,literal)PROMOTED.md' ':(exclude,literal).claude/subagent-runs.jsonl')
