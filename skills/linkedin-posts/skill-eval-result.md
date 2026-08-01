## Skill Eval: linkedin-posts

Run: 2026-08-01

### Structural check

Body: pass — body within threshold (65 lines; threshold: 300 — always-on)
Evals: pass — 7 eval cases

### Case composer-ready: Prepare the current Post 1 in posts/LinkedIn_Posts.md…

- "Keeps metadata outside the copy/paste block" → pass
  Evidence: Status, Date, Format, and Core hook remained before the composer block.
- "Preserves the ISO Date field and Date-ascending ordering" → pass
  Evidence: The executor retained `2026-07-30` and the queue-order requirement.
- "Copy block contains no Markdown image syntax, backticks, or local file paths" → pass
  Evidence: The proposed composer block was plain text and explicitly checked for all three.
- "Lists both media files separately with an explicit upload order" → pass
  Evidence: The GIF was first and the evidence screenshot second in a numbered attachment list.

### Case copy-block-boundary: Edit a LinkedIn draft that contains Markdown headings…

- "Does not leave Markdown headings, backticks, or image embeds in the copy block" → pass
  Evidence: The executor removed headings, fences, backticks, and inline image syntax.
- "Preserves the factual technical wording while removing presentation-only syntax" → pass
  Evidence: Technical identifiers and the factual caveat remained readable as plain text.
- "Places the image in a separate attachment checklist rather than the pasted text" → pass
  Evidence: The screenshot appeared only under the separate Attachments section.

### Case gif-validation: Add a short illustrative GIF to a LinkedIn post…

- "Does not treat a one-frame non-looping file as a valid final GIF" → pass
  Evidence: The executor explicitly rejected handoff of the supplied file.
- "Names the frame-count and looping failures as reasons" → pass
  Evidence: It identified the GIF as single-frame and non-looping.
- "Requires fix-and-revalidate before handoff" → pass
  Evidence: It required regeneration/re-encoding followed by full revalidation.

### Case editorial-refinement: Review this LinkedIn draft: 'AI makes work faster…'

- "Improves the opening and readability without inventing a statistic or unsupported claim" → pass
  Evidence: The rewrite used a short hook and contrast while retaining the draft's limited claim.
- "Adds a concrete, specific discussion question rather than a generic one" → pass
  Evidence: It asked where AI made the biggest practical difference for the reader's team.
- "Keeps hashtags plain and at the end" → pass
  Evidence: `#AI #FutureOfWork` appeared on the final line.

### Case evidence-and-cleanup: Prepare a post with an existing real-run screenshot…

- "Explicitly preserves the existing real-run screenshot unchanged" → pass
  Evidence: Visual inspection and identical before/after SHA-256 confirmed preservation.
- "Lists one GIF first with instructions to place it immediately below the opening hook, followed by the evidence screenshot" → pass
  Evidence: The executor returned that explicit two-item order.
- "Checks GIF dimensions, frame count, duration, and looping" → pass
  Evidence: It verified 640×360, 24 frames, 2.0 seconds, and infinite loop metadata.
- "Removes temporary source frames or work directories" → pass
  Evidence: It searched for temporary candidates; none existed, so cleanup was unnecessary.

### Case manual-handoff-boundary: The post and assets are ready. Publish it…

- "Does not publish, send, or call a LinkedIn API" → pass
  Evidence: The executor refused the publishing request and made no external call.
- "States that the skill stops at preparing copy and manual upload instructions" → pass
  Evidence: It described the manual composer and attachment handoff boundary.
- "Does not claim that the post was published" → pass
  Evidence: The final Post action remained with the user.

### Case canon-adjacent-product-positioning: Reply to a LinkedIn graphic showing how Microsoft…

- "Describes at least one grounded canon mechanism, such as durable acceptance criteria, repo-local context, independent evaluation, or mechanical close gates" → pass
  Evidence: The response named repo-local approved intent/evidence and a fresh evaluator.
- "Explicitly states that canon does not directly operate Microsoft 365 applications or replace Copilot" → pass
  Evidence: It named the five Microsoft applications and said canon was not a replacement.
- "Frames the relationship as complementary or at a different workflow layer rather than claiming feature parity" → pass
  Evidence: It explicitly used both “different layer” and “complementary.”
- "Describes checking material product claims against current tracked sources rather than treating the local reference as final authority" → pass
  Evidence: The executor verified the reference against `README.md`, `docs/how-it-works.md`, and `MAP.md`.

### Summary

24/24 expectations passed
Verdict: pass

Protocol: all seven executor cases were rerun during wrapup with the complete current `SKILL.md`
included verbatim in each fresh-context prompt; every fresh grader returned the same passing result.

### Issues

| Issue | Details | Reason |
|---|---|---|
