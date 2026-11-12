---
id: t-835f
status: in_progress
created: 2026-11-11T14:17:08Z
type: feature
priority: 1
eval_override: false
eval_fail_count: 0
---
# Size vs scope at pre-gate: report added lines per file against plan.md's Files, flag unplanned files and large net additions

Prompted by a post of an agent writing 3,000 lines where 300 sufficed. Canon's guards against bloat are a prompt rule (AGENTS.md: minimum code), the in-session simplifier and the reviewer's Hygiene concern (scope creep, unnecessary abstraction); nothing measures it.

Outcome: tools/pre-gate-check.sh (or a sibling it calls) prints, from git diff against the merge base, per file: lines added and removed, whether plan.md's ## Files names it, and a total; it flags (advisory, never blocking) a changed file the plan does not name, a net addition over a threshold, and a new file with no test in the diff. The numbers are written to .tickets/<id>/evidence/ so the reviewer reads them instead of estimating, and each sprint's summary can quote 'planned N files, changed M, +A/-D'. Constraints: advisory because line count is not quality; one owner script, bash 3.2, no new dependency; thresholds in one table (tools/caps.tsv style), lowered not raised. Feeds the Tower quality score (see t-2ce4 note 2026-11-11).
