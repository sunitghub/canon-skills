---
name: check-offline
description: Checks HTML prototype files for external dependencies that require internet access. Use when preparing a demo for an offline or locked-down environment, or verifying a prototype is self-contained before presenting.
category: dev
---

# check-offline

Scans one or more HTML files for remote dependencies and reports whether the prototype is safe to run offline.

## Steps

1. Read each HTML file the user specifies, or all `.html` files in the current directory if none are named.
2. Scan for remote references:
   - `<script src="http...">` or `<script src="//..."`
   - `<link href="http...">` (stylesheets, fonts)
   - `<img src="http...">`, `<video src="http...">`, `<source src="http...">`
   - `@import url(http...)` inside `<style>` blocks
   - `fetch("http...)` or `XMLHttpRequest` calls targeting remote URLs
3. Skip URLs inside HTML comments (`<!-- ... -->`). Skip `data:` and `blob:` URIs — these are self-contained.
4. For each remote dependency found, report the tag, the URL, and a suggested fix (download the file locally and update the src/href, or inline the content).
5. If no remote dependencies are found: confirm "Offline-ready: no external dependencies detected."
6. If remote dependencies are found: list them all, then ask the user whether to fix them in place or just report.

## Gotchas

- CDN `<link rel="stylesheet">` references are just as blocking offline as `<script>` tags — flag them.
- Google Fonts (`fonts.googleapis.com`, `fonts.gstatic.com`) often appear in `<link>` tags and `@import` — flag them.
- A URL in a JS string literal (e.g. `const API = "https://..."`) is a runtime call, not a load-time dep — flag it only if it's inside `fetch()` or `XMLHttpRequest`.
- Relative paths (`./lib.js`, `../css/style.css`) are local — do not flag them.
- If the user can't go fully offline, suggest adding `integrity="sha384-..."` + `crossorigin="anonymous"` to any remaining CDN `<script>` or `<link>` tags (Subresource Integrity). It doesn't help offline but prevents CDN-compromise attacks.
