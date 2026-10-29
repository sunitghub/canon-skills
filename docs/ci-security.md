# CI security: govulncheck and vendored code

`.github/workflows/govulncheck.yml` (`t-b525`) scans the Go daemon module, `tools/canon-go`, with
[govulncheck](https://go.dev/doc/security/vuln/). It reports only vulnerabilities the code can reach, and it
covers the Go standard library, which Dependabot does not see.

## When it runs

- Weekly (Monday 06:17 UTC), so a new advisory against unchanged code is caught.
- On demand: Actions › govulncheck › Run workflow (`workflow_dispatch`).
- On a push to `main` and on a pull request that touches `tools/canon-go/**` or the workflow file.

A reachable vulnerability fails the job (govulncheck exits non-zero; nothing swallows it). Fix it with a normal
sprint: usually a `toolchain` bump in `tools/canon-go/go.mod` for a standard-library finding, or a dependency bump.
Any go.mod change moves the daemon's and the board's source keys (`tools/src-key.sh`), so it needs a release; a
dependency bump also needs its new version named in `THIRD-PARTY-NOTICES.md` (`tests/fetch-daemon.sh` check 10).

## Safe on the public mirror

canon-skills mirrors every canon commit (`tkt push-main`), so the workflow runs there too. It has
`permissions: contents: read`, uses no secrets, triggers on `pull_request` (never `pull_request_target`), and never
comments on or labels anything. There is deliberately no `.github/dependabot.yml`: in the mirror it would switch
version updates on, which `t-8493` keeps off. `tests/ci-security-config.sh` (in `scripts/test.sh`) fails if the
permissions widen, `pull_request_target` or a secret appears, the pins below loosen, the scan is made non-fatal, or a
Dependabot config is added.

## Pins

`actions/checkout` and `actions/setup-go` are pinned to full commit SHAs (release tag in a trailing comment), and
govulncheck to an exact version. With no Dependabot, nothing bumps them: update them by hand in a sprint, taking the
SHA from `git ls-remote https://github.com/actions/<name> refs/tags/<tag>` and the version from
`go list -m -versions golang.org/x/vuln`.

## The canon-gate template (t-04f4)

`tools/canon-gate-template.yml` is the workflow the board's **Set up CI gate** writes into a project as
`.github/workflows/canon-gate.yml`. `tests/ci-security-config.sh` checks it with its own rules: it legitimately uses
the `ANTHROPIC_API_KEY` secret. The rules:

- `permissions: contents: read` and no job-level permissions;
- every action pinned to a full SHA (the same `actions/checkout` pin as the workflows above), with
  `persist-credentials: false` on every checkout;
- triggered by `pull_request` only, never `pull_request_target` or `workflow_run`;
- no secret but `ANTHROPIC_API_KEY`, and every `${{ … }}` a whole key value, never inside a `run:` script;
- the Claude Code CLI at an exact version, installed on a Node that the workflow sets up itself (`actions/setup-node` at a
  full SHA): an exact `x.y.z` not below the patched floor of its major (22.23.4, 24.22.1, 26.12.1: the releases that fixed
  CVE-2026-111497, a Brotli decoder flaw in `node:zlib`), a major with no floor (20 and older, 21, 23, 25) refused because it
  has no patched release (t-c4b4). The Node step and the CLI install run before any checkout, so no file of the PR (an
  `.npmrc`, a `yarn-path` script that setup-node's own `yarn --version` probe would run) can steer them. The step carries only
  `node-version`, `package-manager-cache: false` and `check-latest: false`; the workflow is one job with no `if:` and no
  override of `PATH`, `NODE_OPTIONS` or npm/yarn config.

The canon checkout carries `ref: __CANON_REF__`. The board replaces it with `v<VERSION>` of the install that writes
the file, and refuses on an install without a release version. A project's gate therefore runs the canon release that
generated it, and moves to a newer one only when someone deletes the file and runs Set up CI gate again. Existing
`canon-gate.yml` files are never rewritten by the board.

Bumping: take the checkout SHA as for the workflows above; the CLI version from `npm view @anthropic-ai/claude-code
version`. Change the template, then re-run `tests/ci-security-config.sh`.

Node is not an npm package, so Dependabot and the security-review gate do not see it, and the runner image's own Node is
not canon's to trust (the `ubuntu-24.04` image of 2026-10-12 shipped 22.23.3, a patch below the fix). To bump it: take the
newest release of the pinned line with `"security": true` from `https://nodejs.org/dist/index.json` (or any newer
release of that line), put it in `node-version:`, raise that major's floor in `check_template` when a security release
lands, and take the `actions/setup-node` SHA as for the other actions (`gh api repos/actions/setup-node/releases/latest`,
then the tag's commit). The SHA pins the action's code, not Node's bytes: setup-node downloads from GitHub's node-versions
release assets (falling back to nodejs.org) and checks only the version it ends up with, so the exact version is what canon
controls. Nothing opens a PR for this: the weekly report (below) watches the pin and fails when a security release of
its line is newer, and you bump it by hand. A project that already has a `canon-gate.yml` keeps its old Node
step until it deletes the file and runs Set up CI gate again.

## Run it locally

```bash
cd tools/canon-go
go install golang.org/x/vuln/cmd/govulncheck@v1.9.0   # the version the workflow pins
govulncheck ./...
```

It needs `vuln.go.dev`. Where that host is blocked but Google Cloud Storage is not, the same database is at
`govulncheck -db https://storage.googleapis.com/go-vulndb ./...`.

## Vendored third-party code: new versions and advisories

The daemon embeds three files it copies from npm rather than installing: `xterm.js` and `xterm.css` (`@xterm/xterm`
6.0.0) and `xterm-addon-fit.js` (`@xterm/addon-fit` 0.11.0), in `tools/canon-go/internal/daemon/web/vendor/`. With no
`package.json` or lockfile, neither `npm audit` nor Dependabot can see them (`t-93ff`). Three pieces cover them:

- **`tools/vendored.tsv`**, the manifest: one row per file with `file`, `package` (as published when vendored), `track`
  (the package that now carries new releases: xterm moved to `@xterm/xterm` and `@xterm/addon-fit`), `version`,
  `upstream`, `license`, `sha256` and `why`. It sits outside `web/vendor/`, so the embedded files and the daemon's source
  key do not change when the manifest does.
- **`tests/vendored-manifest.sh`** (in `scripts/test.sh`): every vendored file has a row and every row a file, each
  file's SHA-256 matches its row (nobody edits a vendored file by hand), and `THIRD-PARTY-NOTICES.md` has a
  `## <package> <version>` heading for each row.
- **`scripts/check-vendored.sh`**, the report: for each vendored package it asks the npm registry for the latest
  version of the `track` package, and asks [OSV](https://osv.dev) (`api.osv.dev/v1/query`, ecosystem `npm`) for the
  advisories that affect the **vendored** package and version. OSV does the version matching, so there is no range
  arithmetic here and no token is needed.

### When it runs

`.github/workflows/vendored-updates.yml` runs it weekly (Monday 06:41 UTC, a different minute from govulncheck) and on
demand (Actions › vendored-updates › Run workflow). Like govulncheck it has `permissions: contents: read`, uses no
secrets and no token, and opens no issue, PR or commit; `tests/ci-security-config.sh` now holds every workflow file to
those rules. The job fails only when an advisory affects a vendored version, or when a lookup failed: a lookup that
fails never reads as "no advisories". GitHub's own email for a failed scheduled run is the alert.

The workflow also runs on the public mirror, canon-skills. **GitHub pauses scheduled workflows on a public repository
after 60 days without repository activity**; a push re-enables them, or re-enable the workflow from the Actions tab.

### Run it locally

```bash
scripts/check-vendored.sh            # print the table; exit 0 clean, 1 advisory, 2 a lookup failed
scripts/check-vendored.sh --summary  # also append it to $GITHUB_STEP_SUMMARY when that is set (the workflow uses this)
```

It needs only `bash` and `curl`, on macOS, Linux and Git Bash. It uses `jq` when present and a grep/sed fallback when not
(`VENDORED_NO_JQ=1` forces the fallback); both decide "affected or not" the same way, and only the severity and fixed-in
columns are best-effort without `jq`. It needs `registry.npmjs.org`, `api.osv.dev` and `nodejs.org`.

### Reading the job summary

One row per vendored package: the package (and the package it moved to), the vendored and latest versions, how far
behind (`N major`, `N minor`, `N patch` or `up to date`), the advisories on the vendored version as
`<id> (<severity>, fixed in <version>)`, and the upstream release notes. A list under the table names each newer version,
each advisory and each failed lookup, and the last line is the verdict: `ok` (newer versions are information) or `FAIL`.

### The CI gate template's pins (t-2d0f)

The same report reads two pins from `tools/canon-gate-template.yml` (the template owns them; the script never copies a
version) and adds a row for each: the `node-version:` of the `actions/setup-node` step, and the
`npm install -g @anthropic-ai/claude-code@x.y.z` line. **Node** is checked against `https://nodejs.org/dist/index.json`:
a `"security": true` release of the pin's major that is newer than the pin fails the job (exit 1), with the newest one
named as the fixed-in version; a newer non-security release is information. The **Claude Code CLI** is checked against
npm's `latest` (information only) and OSV for the pinned version; any advisory fails the job. A pin the script cannot
find, or an answer it cannot read, exits 2, never 0. A failure means: bump the pin in `tools/canon-gate-template.yml`
**and** the floor table in `tests/ci-security-config.sh` (the offline guard, which would otherwise keep accepting the old
floor). Existing consumers' `canon-gate.yml` files are not rewritten: a project picks up the new pin when it deletes
the file and runs Set up CI gate again.

### What we do with a finding

- **A security advisory on a vendored version** becomes a P0 ticket the same day: upgrade to the fixed version, or show
  why the advisory cannot reach canon's use of the file.
- **A newer version with a performance or feature gain** becomes a ticket we weigh, like any other upgrade (the xterm 6
  upgrade was `t-d689`).
- **Nothing is upgraded or merged automatically.** The report never opens issues or PRs, and there is no Dependabot
  config (`t-8493`).

### Bumping a vendored file

In a sprint:

1. Replace the file in `web/vendor/` with the published one (from the package's npm tarball).
2. `scripts/check-vendored.sh --sha <file>` prints its SHA-256; put it, the new version (and `package`, if it moved) in
   the file's row of `tools/vendored.tsv`. The script never edits a file itself.
3. Update the file's `## <package> <version>` heading and license text in `THIRD-PARTY-NOTICES.md`, and the `integrity`
   hash in `tools/canon-go/internal/daemon/web/cockpit.html`.
4. Run `bash tests/vendored-manifest.sh` and `bash tests/fetch-daemon.sh`. The embedded files move the daemon's source
   key, so the change needs a daemon release.

**Rolling back.** The old files stay in git history. To go back to xterm 5.3.0 (the release before `t-d689`), restore
the four places together, then rebuild and release the daemon:

```bash
git checkout 67cb7e8c -- tools/canon-go/internal/daemon/web/vendor tools/canon-go/internal/daemon/web/cockpit.html tools/vendored.tsv THIRD-PARTY-NOTICES.md
```

Never restore `web/vendor/` alone: the Option/Alt+Left/Right mapping `t-d689` added to `cockpit.html` calls
`term.input`, which 5.3.0 does not have (5.3.0 sends those keys itself), and the `integrity` hashes must match the files.
