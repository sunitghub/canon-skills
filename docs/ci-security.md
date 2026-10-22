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

## Run it locally

```bash
cd tools/canon-go
go install golang.org/x/vuln/cmd/govulncheck@v1.9.0   # the version the workflow pins
govulncheck ./...
```

It needs `vuln.go.dev`. Where that host is blocked but Google Cloud Storage is not, the same database is at
`govulncheck -db https://storage.googleapis.com/go-vulndb ./...`.

## Vendored third-party code: new versions and advisories

The daemon embeds three files it copies from npm rather than installing: `xterm.js` and `xterm.css` (xterm 5.3.0) and
`xterm-addon-fit.js` (0.8.0), in `tools/canon-go/internal/daemon/web/vendor/`. With no `package.json` or lockfile,
neither `npm audit` nor Dependabot can see them (`t-93ff`). Three pieces cover them:

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
columns are best-effort without `jq`. It needs `registry.npmjs.org` and `api.osv.dev`.

### Reading the job summary

One row per vendored package: the package (and the package it moved to), the vendored and latest versions, how far
behind (`N major`, `N minor`, `N patch` or `up to date`), the advisories on the vendored version as
`<id> (<severity>, fixed in <version>)`, and the upstream release notes. A list under the table names each newer version,
each advisory and each failed lookup, and the last line is the verdict: `ok` (newer versions are information) or `FAIL`.

### What we do with a finding

- **A security advisory on a vendored version** becomes a P0 ticket the same day: upgrade to the fixed version, or show
  why the advisory cannot reach canon's use of the file.
- **A newer version with a performance or feature gain** becomes a ticket we weigh, like any other upgrade (the xterm 6
  upgrade has its own ticket).
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
