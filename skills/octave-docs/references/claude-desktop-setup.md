# Using octave-docs in Claude Desktop

This skill also works outside the canon repo, as a custom Skill you upload to the
**Claude Desktop app**. This guide is for a first-time user who just wants to install it
and generate a deck or memo — no coding required.

## Before you start: which part of Claude Desktop?

As of 2026, the Claude Desktop app has three tabs: **Chat**, **Cowork**, and **Code**.
This guide is for the **Chat tab** — the normal conversation surface, where custom Skills
are uploaded via Settings.

The **Code tab** is a different product (it's Claude Code with a GUI). It also supports
"skills," but those run on your actual computer, not in Anthropic's sandbox — if you add
`octave-docs` there as a local project skill instead of following this guide, you *will*
need Python and `pip3 install python-pptx python-docx` installed on your machine. This
guide's Step 3 (no Python needed) only applies to the Chat tab flow below.



## Step 1: No Python install needed

Unlike running this on your own computer, Claude's Chat-tab sandbox already has the two
libraries this skill needs (`python-pptx`, `python-docx`) pre-installed. You will not be
asked to install anything — if the skill ever does ask you to run `pip3 install ...`,
that means it's running through the Code tab instead of Chat, and you should re-check
Step 1 of this guide.

## Step 2: Upload the skill

1. In the Claude Desktop app, make sure you're on the **Chat** tab.
2. Open **Settings → Customize → Skills**.
3. Click **+ → Create skill → Upload a skill**.
4. Choose the `octave-docs-skill.zip` file.
5. Once it uploads, toggle the skill **on**.

Custom Skills are private to your account — if a colleague also wants this, they need to
upload it themselves; there's no way to push it to their account for them.

## Step 3: Try it

The skill doesn't read from a file or URL on its own — it only works from the outline
text you give it in the conversation. If you just name your topics without real content
("agenda: hiring recap, roadmap"), Claude will ask you to fill in what actually happened
in each section rather than invent business facts. For a one-shot result, give it the
real content up front.

Start a **new** conversation (in the Chat tab) and ask something like:

> Give me a first-pass PowerPoint deck for our Q3 update.
> Agenda: hiring recap, roadmap for next quarter.
> Hiring recap: 12 new hires this quarter, time-to-fill down 18%.
> Roadmap: launching the new onboarding flow in Q4, hiring 3 more engineers.

Claude should recognize this matches the skill, read its instructions, and hand you back
a `.pptx` file built from the real Octave template — not a generic deck. Ask for a memo
the same way ("give me a first-pass Word memo about..., with these details: ...") to get
a `.docx` instead.

If Claude doesn't seem to use the skill, check that it's toggled on in Settings →
Customize → Skills, and that you started a new conversation after uploading it.

## Differences from canon-repo (Claude Code) usage

| | Claude Desktop, Chat tab | Claude Code / canon repo |
|---|---|---|
| Python setup | None — pre-installed in Claude's sandbox | Requires `pip3 install python-pptx python-docx` |
| Where the file goes | Claude hands it back to you in the conversation | `posts/octave-docs/<name>.pptx` in the repo |
| Updating the skill | Re-upload the zip after it changes | `git pull` |

## Gotchas

- Custom Skills don't sync across products — a Skill uploaded to the Chat tab is not
  automatically available through the Claude API or the Code tab. If you use this skill
  in more than one place, you upload it separately in each.
- If the upload is rejected for being too large: Anthropic doesn't publish an exact size
  limit. The bulk of this package's ~6.7MB size is the PowerPoint template
  (`Octave_PPT_Template_20260401.potx`, ~8MB uncompressed) — there isn't a smaller version
  of it to swap in.
