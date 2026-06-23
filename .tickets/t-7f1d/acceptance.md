# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-7f1d`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [x] Windows workshop users can run canon from VS Code on Windows without WSL and without installing Python.
- [x] Git for Windows/Git Bash is the only allowed Windows prerequisite documented for the workshop path.
- [x] The workshop zip includes Windows command shims for `tkt`, `sprint`, and `sprint-check` so PowerShell/cmd/VS Code terminals can invoke the tools by name.
- [x] The workshop zip includes a Windows `sprint-check` path that does not call `python3`.
- [x] Existing macOS/Linux/Git Bash usage remains compatible with the current scripts and Python fallback.
- [x] `dist/README.md` explains the Windows VS Code workshop path and removes WSL/Python as workshop requirements.
- [x] `dist/canon-workshop.zip` is regenerated from the updated include list.
- [x] `dist/canon-workshop.zip` includes `examples/canon-todo-walkthrough` and `examples/todo-app`.
- [x] The workshop zip includes enough setup tooling for the walkthrough, including `skills.sh`, `skills.cmd`, helper libs, and the copy script.
- [x] The Todo walkthrough has a Windows 11 / VS Code setup path that does not require WSL or Python.
- [x] Windows `install.ps1` treats the extracted canon folder as the workshop install and adds that folder's `tools` directory to PATH without copying to `%USERPROFILE%\.canon`.
- [x] `dist/README.md` uses paths relative to the extracted canon folder for Windows workshop setup and walkthrough copying.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [x] Run `bash scripts/build-zip.sh` and verify `dist/canon-workshop.zip` is regenerated.
- [x] Inspect `unzip -l dist/canon-workshop.zip` and verify the Windows shims and no-Python sprint-check artifact are present.
- [x] Run `npm test`.
- [x] Run a local launcher smoke test for the non-Windows path.
- [x] Review Windows commands statically for quoting, PATH behavior, and Git Bash invocation.
- [x] Inspect `unzip -l dist/canon-workshop.zip` and verify walkthrough/reference app files are present.
- [x] Run `npm test` and `npm run serve` in `examples/todo-app`.
- [x] Grep the walkthrough/reference app for stale Python-only or missing-script setup instructions.
- [x] Inspect `install.ps1` output and README commands to confirm they no longer point Windows users at `%USERPROFILE%\.canon`.
- [x] Regenerate `dist/canon-workshop.zip` and verify the embedded `canon/README.md` and `canon/install.ps1` match the in-place flow.

## QA
<!-- Add sign-off items below. Keep this heading unchanged. -->
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [x] Tested locally
