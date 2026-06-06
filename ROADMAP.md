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
