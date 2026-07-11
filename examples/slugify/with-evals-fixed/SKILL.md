---
name: slugify
description: Converts a title or heading into a URL-safe slug (lowercase, hyphen-separated). Use when generating a filename, anchor link, or URL path segment from a title.
category: dev
---

# slugify

Converts an input string into a clean, URL-safe slug.

## Steps

1. Transliterate accented or diacritic characters to their closest plain-ASCII equivalent (é → e, ñ → n, ü → u, ç → c, etc.).
2. Lowercase the entire input string.
3. Replace whitespace with hyphens.
4. Remove any character that isn't a lowercase letter, digit, or hyphen.
5. Collapse multiple consecutive hyphens into a single hyphen.
6. Trim any leading or trailing hyphens.
7. Return the resulting slug.

## Gotchas

- Numbers are kept as-is (e.g. "Top 10 Tips" → "top-10-tips").
- Punctuation like colons, commas, and question marks is simply dropped, not replaced with a hyphen.
- Transliterate before stripping — don't just delete accented characters, or "Café" becomes "caf" instead of "cafe".
