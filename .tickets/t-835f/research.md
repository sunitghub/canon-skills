# Research
- tools/pre-gate-check.sh already stamps one line (shellcheck, node --check, go vet, gate cases, advisory dead code) through evidence.sh into `.tickets/<id>/evidence/pre-gate.log`; changed files = `git diff --name-only $base HEAD` minus `.tickets/` (lines 28-30). The size report belongs there: no new script, no new evidence file.
- `--run` mode has no ticket id today; the id arg is only used by the outer stamp call. The size step needs it to find plan.md: pass `PRE_GATE_ID` through the env.
- plan.md `## Files` is free text (`tools/a.sh; tests/b.sh; docs/c.md ...`), so "planned" = the path (or a listed directory ending `/`) appears as text in that section.
- caps.tsv units are defined in Go (`canon-go caps`); a new unit there would make this a daemon release. A sibling `tools/size-caps.tsv` read by the shell keeps it shell-only.
- Callers of pre-gate output: complete-checklist.md step "Pre-gate"; the reviewer reads the log. tests/pre-gate-check.sh (191 lines) already builds a scratch repo with a base commit.
