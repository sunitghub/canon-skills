# canon — Publishing Runbook

Internal reference for maintaining and publishing canon to GitHub and npm.

---

## Overview

canon has two independent distribution channels:

| Channel | What it delivers | When to update |
|---------|-----------------|---------------|
| **GitHub** (`sunitghub/canon-skills`) | The public tool — skills, tools, standards, scripts | Every meaningful change |
| **npm** (`canon-skills`) | The installer only — `bin/install.js` | Rarely — only when the installer itself changes |

These are decoupled. GitHub is the source of truth. npm is just the discovery and delivery entry point. Most updates only touch GitHub.

---

## Channel 1 — GitHub

### Normal workflow (skills, tools, bug fixes, docs)

```bash
# make your changes, then:
git add <files>
git commit -m "feat: description"
git push          # → sunitghub/canon (private dev)
git push public   # → sunitghub/canon-skills (public install target)
```

**Both pushes are required.** `canon-skills` is what `install.sh` clones —
users never see `canon`. The `public` remote is pre-configured:
```bash
git remote -v   # should show: public → https://github.com/sunitghub/canon-skills.git
```

**Until `t-bb89` (pre-public cleanup) closes:** do NOT `git push public` —
`canon-skills` will be replaced with a clean tree at launch, not incrementally
updated. The dual-push workflow activates at launch.

**Long-term:** replace the manual dual-push with a GitHub repo mirror
(Settings → Repository → Mirror repository on `sunitghub/canon`). Tracked in
`t-4989`. After the mirror is live, `git push public` is no longer needed.

Users pick up changes automatically:
- **Existing installs** — next time they rerun the curl installer, it does `git pull`
- **Projects** — `@`-imports in `CLAUDE.md` are live references; Claude picks up changes on the next session start

### What goes to GitHub

Everything except what `.gitignore` excludes:
- `.tickets/` — local task board, never committed
- `HANDOFF.md` / `DECISIONS.md` — local session state, not release documentation
- `posts/` / `critique/` — marketing drafts and internal notes
- `CLAUDE.md` — generated per-checkout by `skills.sh init`; canon ships `AGENTS.md`, not a committed `CLAUDE.md`

### Branch strategy

No separate release branches — canon is a living library, not a versioned product. While the repo is private, work goes directly to `main` (test locally before pushing). Once the repo is public and the protection ruleset is applied, direct pushes stop and changes land through PRs that pass CI — see `CONTRIBUTING.md`.

### Continuous integration

`.github/workflows/ci.yml` runs `npm test` (core suite + `skills.sh lint`) on every push to `main` and every PR targeting it. While the repo is private the check is **advisory** — GitHub branch protection can't enforce it without a public repo or Pro.

### GitHub repo settings

- **Visibility:** The development repo is private. Do not flip it public unless
  its full git history has been audited and intentionally approved for public
  exposure. The first public launch should use a clean public source created
  from the current release tree, not the private development history.
- **Default branch:** `main`
- **Branch protection:** Staged as version-controlled config in `.github/rulesets/main-protection.json`, documented in `CONTRIBUTING.md`. Rulesets need a public repo (or Pro); apply it once public, after which all changes go through PRs that pass the `test` check.

### Release model

canon is a **living library tracked at `main`**, not a versioned product:

- **GitHub Releases align with npm publish events** — one release per installer publish, same version number. The first release (`v1.0.0`) lands with the first `npm publish`. Skills and standards don't trigger a release; they ship continuously via `git push`.
- **No auto-publish pipeline.** npm publish is manual and behind OTP/2FA. Automating it would require an npm token in GitHub secrets for near-zero benefit.
- **Release notes describe installer changes only** — not skill-level updates, which users get automatically via `git pull`.

---

## Channel 2 — npm (`canon-skills`)

### What the npm package contains

Only the installer package files — not the tool:

```
canon-skills@1.0.0
  bin/install.js     ← clones repo + runs skills.sh init
  package.json
  LICENSE
  README.md          ← included by npm automatically
```

The entire canon tool (skills, tools, standards, sprint-check, etc.) is NOT in the npm package. It lives in the GitHub repo and is cloned by the installer.

### Prerequisites

**npm account** — create once at https://www.npmjs.com/signup

**npm CLI authenticated:**
```bash
npm login
# prompts for username, password, email, OTP if 2FA enabled
# verify with:
npm whoami   # should return your npm username
```

### Public source preparation

The npm installer clones the GitHub repo over unauthenticated HTTPS. That source
must be public, but it does not have to expose the private development history.

Preferred launch path:

1. **Keep this development repo private.**
2. **Create a clean public repo from the release tree only.** Use `git archive`
   or an equivalent fresh checkout so the public repo starts with a new initial
   commit and no historical `.tickets/`, `HANDOFF.md`, `DECISIONS.md`,
   `CLAUDE.md`, removed assets, PDFs, or internal notes.
3. **Use the public repo URL in both installers** before publishing:
   `install.sh` and `bin/install.js` must point at the same public clone URL.
4. **Verify the public source before npm publish:**

   ```bash
   git clone <public-repo-url> /tmp/canon-public-check
   cd /tmp/canon-public-check
   git log --oneline --all
   git log --all --name-only --pretty=format: | sort -u \
     | rg -i '(^|/)(\.tickets|HANDOFF\.md|DECISIONS\.md|CLAUDE\.md)|octave|AI-Agents-Deck|skills/pdf|\.pdf$'
   rg -n --hidden --glob '!.git/**' -i \
     '(api[_-]?key|secret|token|password|credential|private key|/Users/|octave|AI-Agents-Deck|skills/pdf)' .
   npm pack --dry-run .
   ```

   The expected result is a short public-only history, no private workflow or
   removed internal files, and an npm package containing only `LICENSE`,
   `README.md`, `bin/install.js`, and `package.json`.

Only use a history rewrite of the development repo if you explicitly accept the
force-push impact on every clone and remote integration. A clean public repo is
safer for launch because old private objects were never pushed there.

Tracked cleanup issue: https://github.com/sunitghub/canon/issues/1

### First-time publish

First launch path:

1. **Prepare and verify the clean public source.**

   The installer clones over unauthenticated HTTPS. Publishing to npm while the
   installer target is private can reserve the package name, but the public
   curl installer will fail for normal users until the installer target is
   public.

2. **Authenticate npm:**

   ```bash
   npm login
   npm whoami
   ```

3. **Dry run from the canon checkout:**

   ```bash
   npm pack --dry-run .
   # confirm only LICENSE, README.md, bin/install.js, and package.json are listed
   ```

4. **Publish the installer:**

   ```bash
   npm publish . --access public
   ```

   `--access public` is required because the package name is unscoped. Without
   it, npm defaults to private (paid plan required).

5. **Verify npm and the live installer:**

   ```bash
   npm info canon-skills
   npm info canon-skills version
   curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash
   ```

6. **Create the first GitHub Release after live npm verification:**

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   gh release create v1.0.0 --title "v1.0.0" --notes "First public installer release"
   ```

The GitHub Releases panel appears after the tag/release step above. For canon,
Releases track installer publishes, not every skill or docs update.

Legacy shorthand:

```bash
npm publish <path-to-canon> --access public
```

### When to republish to npm

**Republish ONLY when `bin/install.js` or `package.json` changes.** Specifically:

| Change | GitHub push | npm publish |
|--------|------------|-------------|
| New skill added | ✓ | ✗ |
| Sprint skill updated | ✓ | ✗ |
| sprint-check UI updated | ✓ | ✗ |
| New tool added | ✓ | ✗ |
| Bug in `install.js` fixed | ✓ | ✓ |
| Default install path changed | ✓ | ✓ |
| New installer flag added | ✓ | ✓ |
| `package.json` keywords updated | ✓ | ✓ |

### How to publish an update to npm

1. **Make the change** to `bin/install.js` or `package.json`

2. **Bump the version** in `package.json` — follow semver:
   - `1.0.x` — patch: bug fix in installer
   - `1.x.0` — minor: new installer feature (e.g. new flag, new agent wired)
   - `x.0.0` — major: breaking change (e.g. install path changed, different init flow)

   ```json
   "version": "1.0.1"
   ```

3. **Dry run first** — always verify what will be published:
   ```bash
   npm pack --dry-run <path-to-canon>
   # confirm only bin/install.js, package.json, README.md are listed
   # confirm package size is small (should be ~3-8KB packed)
   ```

4. **Commit and push to GitHub first:**
   ```bash
   git add bin/install.js package.json
   git commit -m "chore: bump installer to v1.0.1 — fix X"
   git push
   ```

5. **Create a GitHub Release:**
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   gh release create vX.Y.Z --title "vX.Y.Z" --notes "Brief description of installer change"
   ```

6. **Publish:**
   ```bash
   npm publish <path-to-canon> --access public
   ```

7. **Verify:**
   ```bash
   npm info canon-skills version   # should show new version
   curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash
   ```

### Caveats and gotchas

**Version must be bumped before publish.** npm rejects publishing the same version twice — even if the content changed. Always bump `package.json` version before running `npm publish`.

**`--access public` is required every time.** Unscoped packages default to private on publish; npm CLI will error out on a paid-only action if you forget it.

**npm publish uses the local files, not git.** You are publishing whatever is on disk, not what is in git. Always push to GitHub before publishing to npm so they stay in sync.

**`.npmignore` controls what ships.** The current `.npmignore` excludes everything except `bin/` and `package.json`. If you add a file that should not be public, verify `.npmignore` covers it:
```bash
npm pack --dry-run <path-to-canon>
# review the file list — if you see unexpected files, update .npmignore
```

**README.md is always included** — npm automatically includes it regardless of `.npmignore`. The public README is what appears on the npmjs.com package page. Keep it user-facing.

**OTP required if 2FA is enabled** — npm will prompt for a one-time password from your authenticator app during publish. Enable 2FA on your npm account (recommended).

**Unpublishing has a 72-hour window.** After 72 hours, a published version cannot be unpublished unless it has zero downloads. Test with `npm pack --dry-run` and the public curl installer before publishing.

---

## Quick reference

### GitHub only (most common)

```bash
git add <files>
git commit -m "..."
git push
```

### GitHub + npm (installer changed)

```bash
# 1. bump version in package.json
# 2. commit and push
git add bin/install.js package.json
git commit -m "chore: bump installer to vX.X.X"
git push

# 3. dry run
npm pack --dry-run <path-to-canon>

# 4. create GitHub Release (tag + release notes)
git tag vX.X.X
git push origin vX.X.X
gh release create vX.X.X --title "vX.X.X" --notes "Brief description"

# 5. publish
npm publish <path-to-canon> --access public

# 6. verify
npm info canon-skills version
curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash
```

### Check current published state

```bash
npm info canon-skills          # full package info
npm info canon-skills version  # just the version
npm info canon-skills dist-tags # latest tag
```

### Authenticate / check auth

```bash
npm whoami      # who you're logged in as
npm login       # re-authenticate
```
