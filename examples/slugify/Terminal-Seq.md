# Terminal sequence — live slugify demo

Skips `skills.sh add` — its documented `examples/` path syntax doesn't work with
the current tool (`find_skill` only searches `standards/`, `tools/`, `skills/` by
frontmatter name, never `examples/`). This sets up a scratch project the same way `skills.sh add`
would under the hood: a real `skills/` dir, symlinked into `.claude/skills/`.

## One-time setup

```bash
mkdir -p ~/scratch/slugify-demo/skills
mkdir -p ~/scratch/slugify-demo/.claude
ln -s ../skills ~/scratch/slugify-demo/.claude/skills
```

## Act 1 — no evals

```bash
mkdir -p ~/scratch/slugify-demo/skills/slugify
cp ~/Developer/canon/examples/slugify/no-evals/SKILL.md ~/scratch/slugify-demo/skills/slugify/SKILL.md
cd ~/scratch/slugify-demo
claude
```

In the Claude Code session:

```
/slugify "Top 10 Tips for Beginners"
```

→ shows the clean pass.

```
/slugify "Don't Stop Believin'"
```

→ shows `don't-stop-believin'` — apostrophes wrongly kept, Tier 1's bug.

```
/slugify "Café Rules — 2024"
```

→ shows `caf-rules-2024` — the accent dropped, Tier 2's bug.

## Act 2 — with evals (still the buggy skill)

Exit the session, then:

```bash
rm ~/scratch/slugify-demo/skills/slugify/SKILL.md
cp -r ~/Developer/canon/examples/slugify/with-evals/* ~/scratch/slugify-demo/skills/slugify/
cd ~/scratch/slugify-demo
claude
```

```
/skill-eval slugify
```

→ runs the real structured executor+grader path against all 5 cases. Two fails:

- **Case 4 (apostrophe) — Tier 1.** The agent's own eval, written cold with zero
  hints about this bug, catches it immediately: 0/3.
- **Case 5 (accented character) — Tier 2.** Fails too, but only because the
  agent's proposed expectation was corrected by hand first — its first draft had
  quietly encoded the same bug as "expected." Worth pointing out live: the
  `evals.json` in this folder already has that correction baked in.

## Act 3 — fixed

```bash
rm -rf ~/scratch/slugify-demo/skills/slugify
mkdir -p ~/scratch/slugify-demo/skills/slugify
cp -r ~/Developer/canon/examples/slugify/with-evals-fixed/* ~/scratch/slugify-demo/skills/slugify/
cd ~/scratch/slugify-demo
claude
```

```
/skill-eval slugify
```

→ 15/15, no regressions — both the apostrophe fix (step 3) and the transliteration
fix (new step 1) verified in one command.

## Caveats

- Start a fresh `claude` session after each swap — skills load at session start,
  so reusing a session won't pick up the swapped file.
- `/skill-eval`'s own instructions say `skills/$ARGUMENTS/`, which is why this setup
  uses a real top-level `skills/` dir rather than dropping files straight into
  `.claude/skills/` — keeps the path skill-eval expects unambiguous.
