# Contributing

## Release Checklist

1. **Bump version** in `package.json` (follow semver: patch for fixes, minor for new skills, major for breaking changes)
2. **Update** any `standards/*.md` files that changed — bump their `version:` and `updated:` frontmatter
3. **Run tests**: `npm test`
4. **Commit** the bump: `git commit package.json -m "chore: bump version to X.Y.Z"`
5. **Tag** the commit: `git tag vX.Y.Z && git push --tags`
6. **Dry run** to verify the package contents: `npm pack --dry-run`
7. **Publish**: `npm publish --access public`
8. **Verify** live: `npm info canon-skills version` and `npx canon-skills@latest`
