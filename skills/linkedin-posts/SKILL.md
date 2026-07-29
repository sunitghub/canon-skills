---
name: linkedin-posts
description: Prepares canon LinkedIn posts for plain-text copy/paste, editorial refinement, and manual image/GIF attachment. Use when editing posts/LinkedIn_Posts.md for LinkedIn's basic composer.
category: dev
tags: [linkedin, writing, media]
---

# LinkedIn Posts

Maintain `posts/LinkedIn_Posts.md` as an editorial queue and a publishing-ready source for LinkedIn's
basic composer.

## Workflow

1. Read the target entry, its footer instructions, nearby posts, and every referenced media file.
2. Preserve the entry's metadata (`Status`, `Format`, and `Core hook`) for editorial review.
3. Refine the post for a fast LinkedIn read:
   - sharpen the first two lines without inventing claims;
   - preserve the author's voice and factual wording; improve expression, not substance;
   - remove repetition and unexplained jargon;
   - keep concrete evidence, examples, and meaningful caveats;
   - use short paragraphs and plain-text bullets (`•`), not Markdown list syntax;
   - end with one specific question or invitation when it fits the post;
   - keep hashtags plain and at the end.
4. Put the final text under `### Copy/paste into LinkedIn`. This block must contain only text that can
   be pasted into the composer: no Markdown headings, backticks, image embeds, local paths, or editorial
   notes. Use Unicode punctuation and bullets when they improve readability.
5. Put media under `### Attachments`, outside the copy block. List exact repo-relative paths in upload
   order and identify which asset is evidence versus decorative or illustrative.
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

## Validation

- Confirm the copy block contains no Markdown image syntax, backticks, or local file paths.
- Confirm every attachment path exists and the upload order is explicit.
- Re-read the final post and media in context; fix any validation failure before handing it off.
- Do not publish, send, or call a LinkedIn API. Stop after preparing the copy and manual upload checklist.
