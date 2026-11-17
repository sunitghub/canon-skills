# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-c206`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
Tier: normal | Risk: one test file; a wrong trap could rm a path outside $W (only dirs read from its own pinned registry). Spec-check findings 1, 2, 3, 5 adopted; one suite run (user, 2026-11-16).
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Reviewer and Evaluator defaults. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

- [ ] Plan approved — proceed to implementation
Approved: sha256:61edca9b151fbb7e7ea98955d85af1f552dd6c7604b5e2ef42ae930b67753b9d 2026-11-16T00:54:14Z
Pipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier,code-reviewer,doc-audit

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->

Tier: normal (a test file; bug job type, root-why below). One file: `tests/worktree-write-links.sh`.

1. Next to the existing HOME/TMPDIR export, `export CANON_GATE_SCOPE_DIR="$W/registry"`, and record the real registry's entry list (`/tmp/canon-gate-scope-$(id -u)`, empty if absent) before any `pre`.
2. Extend the EXIT trap: remove every `dir=` path the pinned registry recorded (macOS `mktemp -d` ignores TMPDIR, so they are outside `$W`), exit 1 naming any that still exists, then `rm -rf "$W"`.
3. At the end, assert the pinned registry has entries (the pin was used) and no real-registry record names `$W/home` or a recorded dir; print one line.
4. Revert-prove in a scratch clone (export pointed at a second scratch registry: step 3 fails; a forced fail after the first `pre`: no recorded dir left), then one full-suite stamp from a plain clone, nothing pinned, with the real registry listing diffed before/after.

Not changed: `gate_scope_create`'s bare `mktemp -d` in `tools/gate-scope-lib.sh` (a gate file; it only matters for scopes a test leaves without `post`). NOTICED in summary.

### Root-why
- Symptom: a full-suite run fails in canon-migrate.sh with "a canon close gate is running", and leaves live scopes that refuse the user's real home for 2 h.
- Why: a scope is registered in the real /tmp registry. Why: worktree-write-links.sh runs `pre` without the `CANON_GATE_SCOPE_DIR` pin the other gate tests set. Why: t-f7e6 added gate-snapshot to its sweep and copied the HOME/TMPDIR pins but not the registry one; nothing checks a test leaves the registry as it found it.
- Root cause: missing `CANON_GATE_SCOPE_DIR` export in tests/worktree-write-links.sh (and scope dirs outside `$W` that its trap never removes).
- Invariant: after the test, `/tmp/canon-gate-scope-$UID` lists exactly what it listed before, and no scope dir the test made exists. Example 1: registry empty before → empty after (sweep makes ~80 scopes). Example 2: registry holds one unrelated entry before → that one entry, unchanged, after. Edge: registry folder absent before → still absent (or empty) after.

## Files
<!-- List files to create or modify. -->

- `tests/worktree-write-links.sh`

## Decisions
<!-- Record non-obvious tradeoffs and why. Answer each item under the ticket's ## Open questions here, or write "carried forward: <question>". Keep this heading unchanged. -->

- One full-suite run, not the ticket's 'twice in a row' (user approved, 2026-11-16): the invariant is checked by the test itself on every run, so a second 6-minute suite adds no evidence (t-dd2f: no repeat runs).
- The prod `mktemp -d` stays: changing a gate file needs its own release path, and production scopes are always ended by `post`.
