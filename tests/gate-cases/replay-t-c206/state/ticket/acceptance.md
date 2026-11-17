# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-c206`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->
<!-- Optional style for behavior: When <trigger>, <system> <does response>. Example: When tkt gets an unknown id, it exits 1 and names the id. Docs and files stay free text. -->

- [ ] When `tests/worktree-write-links.sh` runs, it registers every gate scope in a registry inside its own `$W` (`CANON_GATE_SCOPE_DIR`), and the real `/tmp/canon-gate-scope-$(id -u)` holds no record this test made (none naming its `$W/home` or a dir its pinned registry recorded); the test itself asserts both (the pin was used, nothing of its own in the real registry) and fails otherwise.
- [ ] When the test exits (pass or fail), every scope dir its registry recorded is removed, so no `tmp.*` folder it made stays in the system temp folder; if one still exists after removal, the trap exits 1 naming it.
- [ ] Pointing the `CANON_GATE_SCOPE_DIR` export at a second scratch registry the test does not check (in a scratch copy) makes the test fail on its pin-used assertion (revert-proof that never touches the real registry).
- [ ] `scripts/test.sh` passes once with no `CANON_GATE_SCOPE_DIR` pinned from outside, and the real registry listing is unchanged after it (the ticket's 'twice in a row' dropped by the user, 2026-11-16: the test asserts the registry on every run).

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] Criteria 1-2 (the full suite, the release gate, and the user's real `canon update` / `skills.sh` guard): `ls -A /tmp/canon-gate-scope-$(id -u) > before; bash tests/worktree-write-links.sh; ls -A … | diff before -` prints nothing; the test prints its registry-check line. In a scratch clone, a forced `fail` right after the first `pre` exits non-zero and leaves no recorded scope dir (the trap's own check).
- [ ] Criterion 3 (the full suite's isolation guard): in a scratch clone with the export pointed at a second scratch registry, `bash tests/worktree-write-links.sh` exits non-zero naming the pin-used check; the real registry listing is unchanged afterwards.
- [ ] Criterion 4 (release gate): save `ls -A /tmp/canon-gate-scope-$(id -u)` to a file, full-suite stamp from a plain clone (`evidence.sh stamp t-c206 test-sh -- scripts/test.sh`, nothing pinned) exit 0, then `diff` the listing: no change.

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally (test run in the real tree, two scratch-clone revert proofs, one unpinned full suite: revert-proofs.md, evidence/test-sh.log)

