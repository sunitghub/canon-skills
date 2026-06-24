---
name: skill-export
description: Exports any flat canon skill as a paste-ready prompt, or refines an existing prompt using efficiency.md standards. Invoke as skill-export <skill-name> or skill-export <skill-name> "<prompt>". Rejects skills with sub-skills.
category: agent-ops
tags: [skills, export, prompt, claude-ai, portability]
---

# Skill Export

Reads a canon skill and outputs its content as clean, paste-ready text — no frontmatter, no SKILL.md structure. Use when you need to run a skill in claude.ai, a system prompt, or any environment that doesn't load SKILL.md files natively.

## Steps

0. **Refine mode.** If a second argument is present — a quoted string (`"…"` or `'…'`) after the skill name — enter refine mode:

   1. Take the quoted string as the raw prompt text.
   2. Apply `standards/efficiency.md` principles to produce a tighter version:
      - Remove hedging and filler: "please", "make sure to", "you should", "always remember to", "it's important to", "note that", "keep in mind that"
      - Remove preamble paragraphs that restate the task before giving instructions — start with the first instruction
      - Collapse multiple sentences that express the **same constraint** into one direct instruction
      - Imperative mood, active voice throughout
      - Do not merge sentences that express **different constraints** — each distinct instruction must survive in the output
   3. Before writing output, enumerate every distinct instruction in the raw prompt. Verify each has a counterpart in the refined version. If any would be dropped, retain it.
   4. Output the refined prompt with no preamble or wrapper. Then append:
      ```
      ---
      Source: refined from user input (standards/efficiency.md)
      ```
   5. Stop — do not continue to Step 1.

1. **Locate the skill.** Find `skills/<name>/SKILL.md` relative to the repo root. If the file does not exist, output:
   ```
   skill-export: '<name>' not found — run ./tools/skills.sh list to see available skills.
   ```
   Then stop.

2. **Flat check.** Run:
   ```
   find skills/<name> -maxdepth 1 -mindepth 1 -type d -not -name "evals"
   ```
   If any directory is returned, the skill has sub-skills and cannot be reliably distilled. Output:
   ```
   skill-export: '<name>' has sub-skills — not supported. Use Claude Code with skills.sh for full fidelity.
   ```
   Then stop.

3. **Strip frontmatter.** Read the SKILL.md. Remove everything between and including the opening `---` and closing `---` frontmatter delimiters (the `name:`, `description:`, `category:`, `tags:`, `hidden:` block at the top). Do not remove any `---` horizontal rules that appear later in the body.

4. **Output.** Print the following, with no added commentary:

   ```
   # <name> — paste into Project instructions or system prompt
   ```

   Then the stripped skill content verbatim — all headings, lists, code blocks, and prose exactly as written.

   Then a footer:
   ```
   ---
   Source: skills/<name>/SKILL.md
   ```

## Rules

- Output only the skill content. No preamble, no explanation, no "here is the exported skill" wrapper.
- Preserve every heading level, list item, and code block exactly. Do not reword, summarize, or reformat.
- If the skill body begins with blank lines after the frontmatter, preserve them.
