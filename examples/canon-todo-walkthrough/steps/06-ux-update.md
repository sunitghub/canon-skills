# 06 - UX Update: A Second Ticket

**What this step does:** A second sprint, on a file the first sprint already
built. It shows two things ticket 1 didn't: handing the agent multiple
competing designs for the same decision, and recording a choice durably
enough that future tickets should follow it.

## Step 1 - Check the file's history first

Before touching `index.html` again, use the same lookup from
[04-implementation.md Step 5](04-implementation.md#step-5---commit-with-the-ticket-id):
switch `sprint-check`'s query mode from `Search` to `Why`, enter `index.html`,
and re-read the Todo ticket's Plan excerpt. This is the habit canon is for —
check *why* a file looks the way it does before changing it, not just what it
currently contains. (CLI equivalent: `tkt why src/index.html` or
`tkt why index.html`, depending on where the file ended up in Step 4.)

## Step 2 - Start the second ticket

```bash
sprint start "Update the Todo list's completed-item styling"
```

The agent creates a new ticket, independent of the first. Nothing about ticket
1 being closed matters here — a closed ticket's files are just files.

## Step 3 - Hand the agent two competing designs

Ticket 1's mockup demo used one candidate at a time. This time, give the agent
two options for the *same* decision and let it hold both until you choose.
Tell the agent:

```text
Here are two candidate styles for the completed-item look: mockups/Mockup-1.jpg
and mockups/Mockup-2.jpg. Plan with both — I'll pick one before you implement.
```

Per `start.md`'s multi-candidate rule, the agent:
- Saves both images distinctly (not overwriting one with the other)
- Embeds **both** in `plan.md` under `## Decisions`, side by side, with the
  tradeoff stated for each
- Does **not** yet embed either in `acceptance.md` — that happens after you choose

Open the **Plan** tab and confirm both mockups render inline, not as broken
links or bare filenames.

## Step 4 - Choose one

Tell the agent:

```text
Let's go with option 2.
```

The agent updates `acceptance.md` to embed only the chosen mockup as a real
`![alt](mockups/Mockup-2.jpg)` reference — never a bare or backticked filename
mention, which would render as plain text instead of an image. `plan.md` keeps
**both** mockups on record under `## Decisions`, so the rejected option isn't
lost — it's just not what shipped.

This split matters even outside this one sprint: if you came back in a later
session and said "use the other mockup instead," that promotion still has to
be a real embed, not a filename mention — the rule holds independent of which
turn or session does the promoting.

## Step 5 - Make the choice durable

`plan.md ## Decisions` explains why *this ticket* picked option 2. That's
ticket-scoped — it doesn't reach outside `.tickets/<id>/`. If this choice
should also bind *future* tickets (e.g. "always use the larger-touch-target
checkbox style going forward"), it belongs one level up. Tell the agent:

```text
This should apply to future UI work too, not just this ticket. Record it in DECISIONS.md.
```

The agent appends a row to repo-root `DECISIONS.md` — the durable,
cross-sprint decision log, separate from any single ticket's own Decisions
section. Open `DECISIONS.md` to confirm the new row states the choice and the
WHY, not just what changed.

## Step 6 - Implement, test, close

Same pipeline as ticket 1 — implement against the approved plan, run
`npm test`, update `acceptance.md` as criteria pass, then:

```text
Sprint complete
```

The wrapup → reviewer → evaluator → close sequence is unchanged from
[05-sprint-complete.md](05-sprint-complete.md); nothing about a second ticket
skips or shortcuts those gates.

Reload `sprint-check`. Both tickets now sit in Done, each with its own
Acceptance, Plan, and Summary tabs — and `DECISIONS.md` now has an entry this
ticket's Plan doesn't repeat, because it doesn't need to.
