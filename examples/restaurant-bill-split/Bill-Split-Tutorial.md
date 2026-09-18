# Session 4 — Running Two Tickets in Different Worktrees

This continues the **MealSplit** walkthrough from `Bill-Split-Tutorial.pdf` (Sessions 1–3).
Everything up to here ran one ticket at a time in the main checkout. This session covers a
newer canon capability: driving **two sprint tickets in parallel, each in its own git
worktree**, so work on one ticket never collides with uncommitted changes from another.

## Why worktrees

Two tickets in the same checkout share one working tree — starting ticket B while ticket A has
uncommitted edits means B's agent sees A's half-finished files. A **git worktree** gives each
ticket its own checked-out copy of the repo (same `.git`, separate working directory), so two
agents — or two terminal windows — can work simultaneously without stepping on each other.

canon's `sprint-check` board has a **Cockpit** mode built for exactly this: a **WORKTREE**
accordion in the ticket rail lets you point a sprint at a fresh or existing worktree instead of
the main checkout, per ticket.

## Option A — from the board (Cockpit)

1. Start the board as before: `sprint-check` (macOS/Linux) or `sprint-check-win` (Windows).
2. Create your two tickets first, same as Session 1/2 — e.g.:

   ```
   sprint start 'Add CSV export of the receipt'
   sprint start 'Add a dark mode toggle'
   ```

   Both land on the board as separate `OPEN` cards.
3. Click **▶ Start** on the first card. The board switches into **Cockpit mode**: the kanban
   lanes collapse into a left ticket rail with an embedded terminal in the center.
4. Open the rail's **WORKTREE** accordion. You'll see:
   - **Main checkout (current)** — the folder you're already in.
   - One row per real entry from `git worktree list --porcelain` (any worktree that already
     exists).
   - **+ New** — creates a sibling checkout at `<repo>-worktrees/<branch>` via `git worktree
     add`.
5. Pick **+ New** for this first ticket. A fresh `OPEN` start *requires* this explicit row pick
   before the terminal launches — Start is gated on it.
6. Once the agent is running, click **Esc / ← Board** to return to the kanban view.
7. Click **▶ Start** on the *second* card and repeat step 4–5, again picking **+ New**. This
   creates a second, separate sibling worktree — the two tickets are now running against two
   different working directories on two different branches.

**Notes:**
- Each ticket's resolved worktree is persisted to `.tickets/<ticket_id>/.cockpit-cwd`. Resuming
  an `IN_PROGRESS` ticket later reuses that path automatically — you won't be asked again unless
  the worktree was since deleted.
- A `.worktreeinclude` file at the project root (same convention as Claude Code's/Codex's own)
  copies matching gitignored files — e.g. `.env` — into a freshly created worktree, so secrets
  don't have to be re-created by hand in every checkout.
- Idle-reap timing differs by location: a worktree session reaps after 5 minutes idle; a
  main-checkout session gets a longer 30-minute safety net.
- The board itself only *displays* one terminal at a time (Start is disabled on other cards
  while a session is visibly attached in that tab). That's a UI constraint, not a daemon one —
  the daemon tracks sessions independently per ticket, so both agents keep running in the
  background regardless of which one the board is currently showing you.

## Option B — from two plain terminals (matches the earlier terminal-only sessions)

If you'd rather not use the board UI, worktrees work the same way from the command line:

1. From your `MealSplit` checkout, create a worktree per ticket:

   ```
   git worktree add ../MealSplit-worktrees/csv-export -b csv-export
   git worktree add ../MealSplit-worktrees/dark-mode -b dark-mode
   ```

2. Open a terminal in each new folder and run `claude` there, same as Session 1:

   ```
   cd ../MealSplit-worktrees/csv-export
   claude --permissions-mode auto
   ```

   Then in the chat: `sprint start 'Add CSV export of the receipt'`.
3. Repeat in the second terminal for `../MealSplit-worktrees/dark-mode`.
4. **Skills:** worktrees the board creates for you are auto-linked to current canon
   automatically. If you created the worktree by hand (as above), run this once from the main
   checkout so the new worktree picks up your canon skills:

   ```
   skills.sh link-worktree ../MealSplit-worktrees/csv-export
   skills.sh link-worktree ../MealSplit-worktrees/dark-mode
   ```

5. Run `sprint complete` in each worktree independently, same as Session 1 step 56–60. Each
   ticket closes on its own branch, with its own commit history.

## Cleaning up

Once a ticket's branch is merged (or abandoned), remove its worktree so `git worktree list`
stays tidy:

```
git worktree remove ../MealSplit-worktrees/csv-export
```

If the worktree still has uncommitted changes, `git worktree remove` will refuse — commit,
stash, or pass `--force` if you're sure you want to discard them.
