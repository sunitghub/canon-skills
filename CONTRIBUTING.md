# Contributing

## Contributing a Skill

Skills follow [`standards/skill-setup-std.md`](standards/skill-setup-std.md) —
flat under `skills/`, lowercase-hyphenated filename matching `name:`, required
frontmatter (`name`, `description`, `category`, `tags`), resolvable `@` imports,
and a `depends:` list that matches sibling imports.

Before opening a PR:

1. **Lint**: `./skills.sh lint` — deterministic conformance check; must pass.
2. **Test**: `npm test` — runs the lint plus the core CLI workflow suite.
3. **Catalog**: `./skills.sh catalog` if you added or renamed a skill; commit `CATALOG.md`.
4. One skill, one job. If the description needs an "and then", split it.

`skills.sh lint` runs as part of `npm test`, so running the suite catches
non-conforming skills before they merge.

## Release Checklist

1. **Bump version** in `package.json` (follow semver: patch for fixes, minor for new skills, major for breaking changes)
2. **Update** any `standards/*.md` files that changed — bump their `version:` and `updated:` frontmatter
3. **Run tests**: `npm test`
4. **Commit** the bump: `git commit package.json -m "chore: bump version to X.Y.Z"`
5. **Tag** the commit: `git tag vX.Y.Z && git push --tags`
6. **Dry run** to verify the package contents: `npm pack --dry-run`
7. **Publish**: `npm publish --access public`
8. **Verify** live: `npm info canon-skills version` and `npx canon-skills@latest`
