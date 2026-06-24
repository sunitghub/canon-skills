---
name: skill-export
description: Exports any flat canon skill as a clean, paste-ready prompt for use in claude.ai Project instructions, system prompts, or other LLM systems. Invoke as skill-export <skill-name>. Rejects skills with sub-skills.
category: agent-ops
tags: [skills, export, prompt, claude-ai, portability]
---

# Skill Export

Reads a canon skill and outputs its content as clean, paste-ready text — no frontmatter, no SKILL.md structure. Use when you need to run a skill in claude.ai, a system prompt, or any environment that doesn't load SKILL.md files natively.

## Steps

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
