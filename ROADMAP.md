# Roadmap

Planned work, kept short. Day-to-day tickets live locally in `.tickets/` (gitignored);
this file is the public-facing shortlist.

## Held — for npm publish
- **Pre-public reference consistency** — verify the npm version badge and `npx canon-skills`
  resolve once the package is published, the package name and links agree, and `sunitghub`
  org references point at the real public repo. Includes aligning the install-terminal
  mockup with the installer's actual output.

## Planned — post-traction

- **Windows 11 CI coverage** — add a WSL2 job to `.github/workflows/ci.yml` once the repo goes public; validates the `ss`/python3 port-detection path that `lsof` currently covers on macOS runners.
- **crit companion note** — document [crit](https://github.com/tomasz-tomczyk/crit) as a complementary tool: canon owns the sprint lifecycle; crit owns the human-in-the-loop diff review. Natural handoff point is `sprint complete` → `crit push` to sync inline comments to the PR. One paragraph in `docs/README.md` or `guides/AI-Agents-Setup.md`, no code changes.
- **Homebrew install path** — `brew install canon-skills` as an alternative to `npx` for users without Node. Canon's bash/markdown architecture means Homebrew installs a directory (not a binary), which works via `SKILLS_ROOT` but needs testing. A custom tap (`brew tap sunitghub/canon`) is low-friction; homebrew-core requires public traction. Revisit if npm/Node proves a meaningful adoption barrier.
