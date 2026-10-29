---
name: visual-verify
description: Browser-render detail for the gates' self-serve visual verification — browser paths per OS, flag rationale, Windows paths, theme caveats; read only when a UI change is being rendered
hidden: true
---

# Visual verify (detail)

Read by `review.md` and `eval.md` gates only when rendering a UI change. The trigger, the "required" rule and the
render command live in `shared-gate-protocol.md ## Self-serve visual verification`; this file holds the detail moved out of it.
Every `skills/...` path here is a plain relative path inside canon's own repo; in a consumer project resolve via
`.claude/skills/...` (Claude Code) or `.agents/skills/...` (Codex/Pi).

## Finding a browser (step 1)

Find a browser binary: macOS `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
(or Chromium/Edge at the equivalent path); Linux `which google-chrome`, `chromium`, or
`chromium-browser`; Windows `where chrome`, or check the default `Program Files\Google\Chrome\Application\chrome.exe`.
If none exist anywhere, the check stays `not-run` — this recipe only covers the common
case where a browser IS installed but wasn't being used.

## Render flags, platform and theme notes (steps 2-3)

`<scratch>` is your own `mktemp -d`. `--user-data-dir` keeps the render off the user's real profile;
`--use-mock-keychain` (a macOS switch) and `--password-store=basic` (a Linux one; each is ignored elsewhere)
keep it off the system keychain and keyring. Without them macOS can show a "Keychain Not Found" dialog on the
user's desktop (t-3488); never click its Reset To Defaults. Run on Chrome on macOS only (exit 0, a PNG, no new
SecurityAgent process); Edge and Brave are expected to behave the same and are untested. On Windows a pinned
HOME does not move Chrome's profile (it lives under `%LOCALAPPDATA%`), so `--user-data-dir` is what isolates
it, and in Git Bash it must be Chrome's native form: `--user-data-dir="$(cygpath -m "<scratch>")/chrome-profile"`;
the Windows run is untested (`not-run`).
`--no-first-run --disable-background-networking --disable-sync --disable-default-apps`
avoids a live-reproduced hang: a fresh browser profile's background network calls (e.g.
GCM registration) can block the process from exiting. Size `<W>,<H>` to the full page —
a too-short window silently crops content below the fold rather than erroring.
**Windows + Git Bash `file://` path:** the `<absolute-path-to-page>` must be Chrome's native
form `file:///C:/Users/...`, not Git Bash's MSYS `/c/Users/...` — `file:///c/Users/...` loads a
blank page (silently, no error), so the shot is empty and the check mis-grades. Convert with
`cygpath -m` (emits `C:/Users/...` with forward slashes): `"file:///$(cygpath -m "<absolute-path>")"`.
macOS/Linux paths need no conversion.
3. To check a specific theme rather than inheriting the host's OS setting:
`--blink-settings=preferredColorScheme=1` (light) is confirmed reliable, but `=2` (dark)
is **not** — live-reproduced on Chrome 149.0.7827.201: `=2` silently produced light
instead of erroring, and `--force-dark-mode`/`--enable-features=WebContentsForceDark`
don't help either — those invert page colors as an accessibility feature, they don't
affect the `prefers-color-scheme` media query at all (confirmed by combining them with
`=1` and still getting light). Never trust a color-scheme flag silently — verify with a
throwaway page (`window.matchMedia('(prefers-color-scheme: dark)').matches`) before
relying on it for a real check. For dark specifically, or for any page that has its own
explicit theme override (a `data-theme` attribute, a class toggle, a `localStorage` key
— common in dashboards with a light/dark button), the robust method is to make a scratch
copy of the page's HTML with that attribute/class pre-set directly, rather than
depending on browser-level scheme emulation at all — this works regardless of Chrome
version or host OS.

