# CI security: govulncheck

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
