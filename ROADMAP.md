# Roadmap

Planned work, kept short. Day-to-day tickets live locally in `.tickets/` (gitignored);
this file is the public-facing shortlist.

## Held — for npm publish
- **Pre-public reference consistency** — verify the npm version badge and `npx canon-skills`
  resolve once the package is published, the package name and links agree, and `sunitghub`
  org references point at the real public repo. Includes aligning the install-terminal
  mockup with the installer's actual output.

## Near-term — operations and board scale

- **Repo sync: canon → canon-skills** — make every meaningful push to the private
  dev repo reach the public install repo. Current path is manual dual-push with
  `public` remote; target state is a GitHub mirror after public-launch cleanup.
  Tracked by `t-4989`.
- **Done-column scale and archive policy** — the board collapses Done/Discarded
  cards visually, but `/api/tickets` still loads all tickets each refresh. Decide
  whether closed tickets need windowed loading, pagination, or an explicit
  archived status. Archive should preserve ticket files and keep historical work
  searchable for `Why`/code archaeology. Tracked by `t-070b`.

## Backlog — ideas from ecosystem research

- **`session-learn` skill** — retrospective scan of `~/.claude/projects/<project>/*.jsonl` to
  surface cross-session patterns that live-memory misses: repeated tool failures, consistently
  rejected approaches, commands that blow up every sprint. Proposes targeted CLAUDE.md / memory
  updates. Inspired by [headroom's `learn` module](https://github.com/chopratejas/headroom).

  Design constraints before building:
  - **Subagent isolation required.** Reading raw JSONL logs into main context is exactly the
    token spend `efficiency.md` warns against. Headroom solves it with a separate model call +
    ~80K digest budget. Canon's zero-install equivalent must delegate to a subagent that returns
    only distilled patterns — not a read → analyze loop in the main session.
  - **Signal threshold: 2+ occurrences or explicit user direction.** Below that, it's noise
    injected into CLAUDE.md. False-positive "learnings" actively hurt. The scan must be strict.
  - **Fits alongside `context-check`**: context-check audits what's loaded now; session-learn
    mines history to improve what gets loaded next time. Natural pairing.
  - Not a fit until canon has meaningful session volume to scan against.

## Planned — post-traction

- **Windows 11 CI coverage** — add a WSL2 job to `.github/workflows/ci.yml` once the repo goes public; validates the `ss`/python3 port-detection path that `lsof` currently covers on macOS runners.
- **crit companion note** — document [crit](https://github.com/tomasz-tomczyk/crit) as a complementary tool: canon owns the sprint lifecycle; crit owns the human-in-the-loop diff review. Natural handoff point is `sprint complete` → `crit push` to sync inline comments to the PR. One paragraph in `docs/index.html` or `docs/setup.md`, no code changes.
- **Homebrew install path** — `brew install canon-skills` as an alternative to `npx` for users without Node. Canon's bash/markdown architecture means Homebrew installs a directory (not a binary), which works via `SKILLS_ROOT` but needs testing. A custom tap (`brew tap sunitghub/canon-skills`) is low-friction; homebrew-core requires public traction. Revisit if npm/Node proves a meaningful adoption barrier.
