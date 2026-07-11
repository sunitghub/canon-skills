---
name: slugify
description: Converts a title or heading into a URL-safe slug (lowercase, hyphen-separated). Use when generating a filename, anchor link, or URL path segment from a title.
category: dev
---

# slugify

Converts an input string into a clean, URL-safe slug.

## Steps

1. Lowercase the entire input string.
2. Replace whitespace with hyphens.
3. Remove any character that isn't a lowercase letter, digit, hyphen, or apostrophe.
4. Collapse multiple consecutive hyphens into a single hyphen.
5. Trim any leading or trailing hyphens.
6. Return the resulting slug.

## Gotchas

- Numbers are kept as-is (e.g. "Top 10 Tips" → "top-10-tips").
- Punctuation like colons, commas, and question marks is simply dropped, not replaced with a hyphen.
