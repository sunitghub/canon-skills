# canon — Publishing Runbook

Internal reference for maintaining and publishing canon to GitHub and npm.

---

## Overview

canon has two independent distribution channels:

| Channel | What it delivers | When to update |
|---------|-----------------|---------------|
| **GitHub** (`sunitghub/canon`) | The actual tool — skills, tools, standards, scripts | Every meaningful change |
| **npm** (`canon-skills`) | The installer only — `bin/install.js` | Rarely — only when the installer itself changes |

These are decoupled. GitHub is the source of truth. npm is just the discovery and delivery entry point. Most updates only touch GitHub.

---

## Channel 1 — GitHub

### Normal workflow (skills, tools, bug fixes, docs)

```bash
# make your changes, then:
git add <files>
git commit -m "feat: description"
git push
```

Users pick up changes automatically:
- **Existing installs** — next time they run `npx canon-skills@latest`, the installer does `git pull`
- **Projects** — `@`-imports in `CLAUDE.md` are live references; Claude picks up changes on the next session start

### What goes to GitHub

Everything except:
- `Emacs/` — in `.gitignore`
- `CSVs/` — in `.gitignore`
- `.tickets/` — local task board, never committed
- `HANDOFF.md` / `DECISIONS.md` — local session state, not release documentation

### Branch strategy

All work goes directly to `main`. No separate release branches — canon is a living library, not a versioned product. If a change is experimental, test locally before pushing.

### GitHub repo settings

- **Visibility:** Public (`sunitghub/canon`)
- **Default branch:** `main`
- **No branch protection rules** — solo repo, push directly

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

### First-time publish

```bash
npm publish <path-to-canon> --access public
```

`--access public` is required because the package name is unscoped. Without it, npm defaults to private (paid plan required).

Verify immediately after:
```bash
npm info canon-skills
# should show version 1.0.0, description, etc.
```

Test the live package:
```bash
npx canon-skills@latest
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

5. **Publish:**
   ```bash
   npm publish <path-to-canon> --access public
   ```

6. **Verify:**
   ```bash
   npm info canon-skills version   # should show new version
   npx canon-skills@latest         # smoke test
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

**Unpublishing has a 72-hour window.** After 72 hours, a published version cannot be unpublished unless it has zero downloads. Test with `npm pack --dry-run` and `npx ./canon-skills-x.x.x.tgz` locally before publishing.

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

# 4. publish
npm publish <path-to-canon> --access public

# 5. verify
npm info canon-skills version
npx canon-skills@latest
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
