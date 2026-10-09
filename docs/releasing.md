# Releasing canon

For the maintainer. Consumers install from `public` (`sunitghub/canon-skills`) and `canon update` takes its `main` at once, so a release is the point a consumer can pin to or return to. This page is the one place the build and release steps are written down in order.

## Versioning

`VERSION` holds `X.Y.Z` ([SemVer](https://semver.org)): a patch for fixes, a minor for features that keep working as before, a major for a change that breaks a tool's command line or the install layout. `CHANGELOG.md` records each release in Keep a Changelog form; commits since the last release sit under `## [Unreleased]`.

A release is **not** every push. Several pushes a day share one `VERSION`, and a tag name is unique. Between releases `public` main is unreleased work; consumers who want stability pin to the last release.

## The pipeline, in order

1. **Merge and push.** Merge to `main`, then push both remotes: `git push origin main` and `git push public main` (canon-skills is the install target).
2. **If Go source changed, release the binaries first.** `scripts/release-daemon.sh` builds the cockpit daemon (macOS, Linux, Windows), the Windows board and the headless helper, publishes them as GitHub releases named by the tree hash of their source, and records each SHA-256 in `tools/cockpit-daemon.sha256`. Commit that manifest. Run it *before* the manifest reaches `public`: installs verify what they download against it. `scripts/check-binaries-released.sh` is the guard to run before pushing to `public`; it is red between a Go commit and its release, by design (`--download` also re-checks every asset's hash).
3. **To release:** bump `VERSION`, add a dated `## [X.Y.Z] - YYYY-MM-DD` section to `CHANGELOG.md` that says what matters to a user, commit, and push to both remotes.
4. **Cut it:** `scripts/release.sh --dry-run`, read what it would do, then `scripts/release.sh`. It refuses, changing nothing, unless `VERSION` is `X.Y.Z`, the CHANGELOG has the dated section with content, `VERSION` and `CHANGELOG.md` match `HEAD`, `HEAD` is `main` and equals `public/main`, and the tag exists neither locally nor on `public`. Then it creates the annotated tag `vX.Y.Z`, pushes only that tag to `public`, and creates the GitHub release with the CHANGELOG section as its notes (`gh` must be logged in). If the GitHub step fails after the tag is pushed, it says so and prints the `gh release create` command to finish; it never deletes a pushed tag. It also builds `canon-X.Y.Z.zip` from the tag (`scripts/release-zip.sh`), attaches it to the GitHub release, and prints the manifest line for step 5; a zip that cannot be built stops everything before the push.
5. **Publish the manifest line.** Installers install a release only if `https://getcanon.dev/releases.txt` lists it (`<tag> <zip sha256> <tag commit sha>`, newest first, under the comment header). That file lives in the **canon-site** repo (`site/releases.txt`), a different write path from this repo: commit the printed line there and push it to canon-site's origin, then wait for the deploy. Until it is live, `canon update --to vX.Y.Z` and the Windows installer refuse that release (they fail closed). A lost asset is rebuilt to the same hash with `scripts/release-zip.sh vX.Y.Z <folder>` and uploaded with `gh release upload`.
6. **Check it:** on a machine, `canon update --to vX.Y.Z`, then `canon version`, then `canon update --to main`. On Windows (a zip install) the output says `Verified vX.Y.Z`.

Nothing in the sprint close pushes a tag or refuses a push while the ticket is open: a refusal would need a Claude Code hook, and canon installs none (`t-f01d`). Close (step 9) already comes before push (step 10).

## What the verification does and does not protect

A release is installed only if the published manifest lists it. A git install (`canon update --to`) also needs the fetched tag's commit to equal the manifest's; a Windows zip install needs the downloaded zip to hash to the manifest's SHA-256, checked before anything is extracted. Anything else (manifest unreachable, no line for the tag, a malformed line, two lines that disagree, a mismatch) refuses with the reason and changes nothing. There is no override; `canon update --to main` is the way out.

It does **not** verify `main`, which moves with every change, and it cannot protect against someone who controls `install.sh`/`install.ps1` themselves: `getcanon.dev/install.*` rewrites to the same GitHub repo as the zip, so such a person could remove the check. What it adds is a second write path (the canon-site repo) that must agree with the zip, and protection against a corrupt, truncated or changed download. The manifest fetch is a plain GET of a static file; it carries no identifier.

## Rolling back (what a consumer does)

```bash
canon update --to v0.3.0     # pin to that release; the daemon and projects are refreshed as in a normal update
canon update --to main       # follow main again
```

On a git install a plain `canon update` refuses while pinned and says how to return, so an update never moves a pin by accident. A Windows zip install records no pin: a plain `canon update` there takes main. On a git install the tag is fetched into the shallow clone; on a Windows install made by the one-line installer (a zip, no git) the installer is re-run with `CANON_REF=vX.Y.Z` and fetches that release's zip and copies it over the install (files only the newer tree had are left behind, as in any Windows update). `--to` accepts only `main` or `vN.N.N`. Binaries need nothing extra: an older tree names its own release assets, which are never overwritten.

`v0.3.0` is the first tag and already contains `--to`, so a pinned install can always return with `canon update --to main`. An install made before `--to` existed cannot use it until it has updated once: run a plain `canon update` first (it takes main), then `canon update --to vX.Y.Z`.
