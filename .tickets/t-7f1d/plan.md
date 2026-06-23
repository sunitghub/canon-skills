# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-7f1d`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
Tier: normal | Risk: workshop packaging and launchers only; main risk is Windows shell/path quoting

- [x] Plan approved — proceed to implementation

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->

Tier: normal — workshop packaging touches installers, launchers, and dist output, but it is reversible and scoped to local CLI distribution.

Build on `t-8060`, which already created `dist/canon-workshop.zip`, `install.ps1`, and `scripts/build-zip.sh`.

1. Add Windows `.cmd` shims for `tkt`, `sprint`, and `sprint-check` that work from PowerShell, cmd.exe, and VS Code terminals by invoking Git Bash for the existing bash CLIs.
2. Add a Windows workshop `sprint-check` path that avoids Python. Preferred implementation is a small Go launcher/server for Windows only if Go is available locally; otherwise use the narrowest checked-in shim/artifact path that can be packaged in the zip and does not require user Python.
3. Update `scripts/build-zip.sh` so the workshop zip includes the new Windows artifacts.
4. Update `install.ps1` and `dist/README.md` so the workshop path is explicit: Windows + VS Code, no WSL, no Python, Git for Windows allowed.
5. Regenerate `dist/canon-workshop.zip`.
6. Include `examples/canon-todo-walkthrough` and `examples/todo-app` in the workshop zip.
7. Include `skills.sh` and required helper libs/shims so the walkthrough setup command works from VS Code on Windows.
8. Update the walkthrough README and implementation step with a Windows 11 / VS Code path that avoids WSL and Python.
9. Change the Windows workshop installer to in-place mode: add the extracted folder's `tools` directory to PATH without copying files into `%USERPROFILE%\.canon`.
10. Update the workshop README and installer output so Windows commands reference the extracted canon folder, not a second `.canon` copy.

Perspective check:
- User: VS Code users expect `sprint`, `tkt`, and `sprint-check` to work from the integrated terminal/agent shell after install.
- Security: command shims must quote paths and arguments correctly; no shell interpolation of untrusted input beyond passing CLI args.
- Architect: keep the existing Python implementation as the macOS/Linux source path and avoid a full rewrite before the workshop.

## Files
<!-- List files to create or modify. -->

- `tools/tkt.cmd`
- `tools/sprint.cmd`
- `tools/sprint-check.cmd`
- `tools/skills.cmd`
- `tools/sprint-check` or Windows-specific sprint-check artifact path, if needed for dispatch
- `tools/skills.sh`
- `tools/skill-lib.sh`
- `tools/hooks-lib.sh`
- `scripts/copy-todo-walkthrough.sh`
- `examples/canon-todo-walkthrough/`
- `examples/todo-app/`
- `install.ps1`
- `scripts/build-zip.sh`
- `dist/README.md`
- `dist/canon-workshop.zip`
- Possibly a small Go source/build script if needed for the no-Python Windows board path

## Decisions
<!-- Record non-obvious tradeoffs and why. Keep this heading unchanged. -->

- Keep the current Python sprint-check implementation for macOS/Linux and existing users; this sprint is about workshop packaging friction, not replacing the source implementation.
- Require Git for Windows if needed; explicitly do not require WSL or a user-installed Python on Windows.
- Treat Go as a workshop binary path for `sprint-check`, not as a full rewrite of `tkt` and `sprint` in this sprint.
- For the workshop zip, prefer in-place install over copying to `.canon`; users already extracted a complete canon folder, and a second copy makes PATH and walkthrough paths confusing.

Applicable `DECISIONS.md` constraints:
- 2026-06-10 delivery priority: zip/pkg-like delivery can conflict with the living-library model; this is acceptable only as a workshop artifact, not the default long-term product update model.
- 2026-06-03 canon stays a living library tracked at `main`; the workshop zip is a point-in-time training distribution.
- 2026-06-03 sprint-check Host allowlist and loopback binding must remain intact in any no-Python sprint-check path.
