# canon vs plain Claude Code (t-e85f)

What canon's sprint adds, in money and minutes, over a plain `claude -p` session doing the same work, scored by tests neither one sees.

## The work

Three requests that build on each other: `step-1.md` (a Node to-do CLI), `step-2.md` (due dates and filters, on the arm's own step 1 code), `step-3.md` (a bug report). Step 3 starts both arms from `baseline-3/`, a reference app with the bug planted, so the fix is compared on equal code.

## The arms

- **plain:** an empty git repo; no canon folder on PATH.
- **canon:** the sprint skill from a scratch clone of this repo at HEAD (`CANON_HOME`), every model tier pinned to Sonnet 5.5, told to run `sprint start` through `sprint complete` with the plan approval and close confirmation given in the prompt.

Both arms run `claude -p --model claude-sonnet-5-5 --setting-sources project,local`, so your own `~/.claude/CLAUDE.md` and settings stay out of both. Each session is capped at `BENCH_MAX_USD` (default 5).

## Running it

```bash
bench/vs-plain/run.sh plain 1 --steps 1     # one session: a dry run of step 1
bench/vs-plain/run.sh canon 1 --steps 1
bench/vs-plain/run.sh plain 2               # all three steps
bench/vs-plain/report.sh                    # the Markdown table from results/results.tsv
```

`run.sh` appends one row per step to `results/results.tsv` (gitignored) and prints where its scratch folder is. It spends real money: a full run is 3 steps × 3 runs × 2 arms = 18 sessions.

## What a row means

- `passed` / `total`: the hidden tests (`hidden/`) for steps 1..N, run from outside the project after the session. `total` comes from the reference app, so an app that does not load scores 0 of the real count.
- `status`:
  - `ok`;
  - `failed`: the session errored, exited non-zero or gave unreadable output (no cost is recorded);
  - `incomplete`: canon only, no sprint was closed;
  - `contaminated`: the session's transcript reads `vs-plain/hidden`, or your canon project list or Cockpit files changed during the session.
  `report.sh` averages only `ok` rows and lists the others.
- canon only: `planning`, `implementation` and `gates` come from `sprint token-spend` (tokens, not $). `gate_runs` lists each gate's tokens and minutes from the subagent log. A value with no data reads `n/a`, never 0.

## Writes outside the scratch folder

Claude Code's own transcripts go to `~/.claude/projects` (the canon arm's `token-spend` reads them). Nothing else does: `skills.sh add` runs under a scratch `HOME`, and `tests/bench-vs-plain.sh` proves it against a stub `claude`.
