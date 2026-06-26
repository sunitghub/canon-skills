# Contributing

## Contributing a Skill

Conventions live in [`standards/skill-setup-std.md`](standards/skill-setup-std.md)
— standalone skills in `skills/<name>/SKILL.md`, hidden skills as `skills/<name>/SKILL.md` with `hidden: true`, required
frontmatter (`name`, `description`, `category`, `tags`), resolvable `@` imports,
and a `depends:` list that matches sibling imports. This section is the
workflow; defer to the standard for the rules.

Start with the [Update vs. new skill](standards/skill-setup-std.md#update-vs-new-skill)
decision: a nuance that changes *how* a skill does its one job is an edit; a
*distinct* job is a new skill.

### Update an existing skill

1. Edit `skills/<name>/SKILL.md`. Keep it to one job — if you find yourself
   adding "and then", it's a new skill, not an edit.
2. Bump `version:` / `updated:` if the file carries them (standards do; skills
   usually do not).
3. Run the [pre-PR checks](#before-opening-a-pr).

### Add a new skill

1. Create `skills/<name>/SKILL.md` following the standard's conventions. Add `hidden: true` frontmatter if the skill is only invoked by other skills.
2. If an existing skill imports it, add it to that skill's `depends:` list.
3. Regenerate the catalog: `./tools/canon-dev.sh catalog`, and commit `CATALOG.md`.
4. If it's standalone, mention it in `README.md` only if it warrants one.
5. Write at least 2 eval test cases in `skills/<name>/evals/evals.json` and run `/skill-eval <name>` to verify. See [docs/agent-playbook.md → Skill lifecycle](docs/agent-playbook.md#skill-lifecycle) for the format and coverage checklist.
6. Run the [pre-PR checks](#before-opening-a-pr).

### Before opening a PR

1. **Lint**: `./tools/skills.sh lint` — deterministic conformance check; must pass.
2. **Test**: `npm test` — runs the lint plus the core CLI workflow suite.
3. **Catalog**: `./tools/canon-dev.sh catalog` if you added or renamed a skill; commit `CATALOG.md`.

`standards/efficiency.md` is the canonical efficiency standard — it's always-on in any project that has canon registered.

`skills.sh lint` runs as part of `npm test`, so running the suite catches
non-conforming skills before they merge.

## Continuous Integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs `npm test` (the
core suite plus `skills.sh lint`) on every pull request to `main` and every
push to `main`.

While the repository is **private**, this check is **advisory** — GitHub branch
protection requires a public repo (or GitHub Pro), so a red check does not yet
block a merge. Do not merge a PR with a failing check.

Branch protection is kept as version-controlled config in
[`.github/rulesets/main-protection.json`](.github/rulesets/main-protection.json):
a PR is required (0 approvals — solo-friendly), the `test` check must pass with
the branch up to date, and `main` allows no deletion, force-push, or merge
commits (squash/rebase only). When the repo goes public, apply it once:

```bash
gh api --method POST repos/sunitghub/canon/rulesets \
  --input .github/rulesets/main-protection.json
```

After that, direct pushes to `main` stop — all changes land through PRs that
pass CI.

## Shipping a Change

canon is a living library — there's no release step for skills, tools, or docs.
Push to both remotes and users pick it up automatically:

```bash
git push          # → sunitghub/canon (dev)
git push public   # → sunitghub/canon-skills (public install target)
```

The curl installer (`install.sh`) is the primary distribution channel. On
re-run it does `git pull`, so every push is live for existing installs on the
next invocation.
