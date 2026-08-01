---
name: linkedin-posts
description: Prepares canon LinkedIn posts for plain-text copy/paste, editorial refinement, and manual image/GIF attachment. Use when editing posts/LinkedIn_Posts.md for LinkedIn's basic composer.
category: dev
tags: [linkedin, writing, media]
---

# LinkedIn Posts

Maintain `posts/LinkedIn_Posts.md` as an editorial queue and a publishing-ready source for LinkedIn's
basic composer.

Each entry must include `Status`, `Date`, `Format`, and either `Core hook` or `Target`. Keep standalone
`Post` entries first, followed by `Reply` entries; within each group, order by `Date` ascending (oldest
first). Use an ISO date (`YYYY-MM-DD`) for `Date`. If historical dates are unavailable, use the date the
draft was added and preserve the existing chronological order; do not invent a publication date and
present it as historical fact.

## Workflow

1. For a canon-related post or reply, read `posts/canon-linkedin-reply-reference.md` when it exists.
   Treat it as an editorial map, not product authority: verify material claims against the current
   tracked sources it names, and prefer those sources if they differ. Then read the target entry, its
   footer instructions, nearby posts, and every referenced media file.
2. Preserve the entry's metadata (`Status`, `Date`, `Format`, and `Core hook` or `Target`) for editorial
   review. When adding or updating an entry, place standalone posts before replies, then re-sort each
   group by `Date` ascending.
3. Refine the post for a fast LinkedIn read:
   - sharpen the first two lines without inventing claims;
   - preserve the author's voice and factual wording; improve expression, not substance;
   - remove repetition and unexplained jargon;
   - keep concrete evidence, examples, and meaningful caveats;
   - use short paragraphs and plain-text bullets (`•`), not Markdown list syntax;
   - end with one specific question or invitation when it fits the post;
   - keep hashtags plain and at the end.
   - For a standalone post, use at most one engaging or humorous GIF when it materially helps the
     hook. In the editorial entry, place its upload instruction immediately below the Core hook. The
     basic LinkedIn composer renders attached media as post media rather than truly inline; treat
     “below the hook” as the intended visual priority, not Markdown inside the copy block.
4. Put the final text under `### Copy/paste into LinkedIn`. This block must contain only text that can
   be pasted into the composer: no Markdown headings, backticks, image embeds, local paths, or editorial
   notes. Use Unicode punctuation and bullets when they improve readability.
5. Put media under `### Attachments`, outside the copy block. List exact repo-relative paths in upload
   order and identify which asset is evidence versus decorative or illustrative. If a GIF is used, list
   it first and explicitly say to place it below the hook; list any evidence screenshot after it.
6. Preserve grounded screenshots exactly unless the user explicitly requests an edit. Do not replace a
   real run artifact with an illustration.

## GIF workflow

When the entry calls for a GIF:

1. Generate or select a visually relevant source frame. Use the image-generation capability for a new
   illustration; do not invent a stock URL or claim that an unverified asset is usable.
2. Create a short, readable loop with the available local media tool, normally `ffmpeg`. Prefer a
   restrained motion or pulse that supports the post rather than a distracting animation.
3. Validate the final file before referencing it: confirm it opens as a GIF, has sensible dimensions
   (normally 640×360 or another feed-friendly wide ratio), contains multiple frames, has a short
   duration, and is configured to loop.
4. Inspect the rendered asset, verify the attachment path from the repo root, and remove any temporary
   source frames or work directories created during generation.

Use no more than one GIF per standalone post. The GIF is an attention device, not evidence; keep a real
run screenshot or other grounded artifact as a separate attachment when the claim needs proof.

## Validation

- Confirm the copy block contains no Markdown image syntax, backticks, or local file paths.
- Confirm every attachment path exists and the upload order is explicit.
- Re-read the final post and media in context; fix any validation failure before handing it off.
- Do not publish, send, or call a LinkedIn API. Stop after preparing the copy and manual upload checklist.
