---
name: shared-gate-protocol
description: Shared protocol sections for reviewer and evaluator subagents — inputs, tools, evidence-vs-success framing, base-ref derivation, citation format, report-writing safety, visual verification
hidden: true
---

# Shared Gate Protocol

Referenced by `review.md` and `eval.md`. Do not invoke directly.

## Contents
- Evidence is not success
- Inputs
- Tools
- Report-writing safety (Windows Git Bash)
- Self-serve visual verification (no Node/Playwright required)
- Base-ref derivation
- Citation format

## Evidence is not success

Before grading anything, hold these three lines. They are the positive statement of
the Weak Evidence and Disposition rules the gate docs already enforce — canon's
governing frame is that **"the tests pass" is a claim, and it needs its own evidence**
(README.md).

- **A passed gate certifies only what that gate checked — not that the work is correct.**
  Your verdict covers the criteria in front of you against the changed files; it is not a
  blanket warrant that the sprint is sound. Grade what you can prove, and say what you did
  not check.
- **Reaching a limit is not success.** Retries exhausted, a token/time budget hit, a
  subagent that stopped, or "no more findings surfaced" are stopping conditions, not
  passing ones. Only satisfied criteria — with evidence — earn a `pass`.
- **Compaction or a context reset is not a completion signal.** A summarized or truncated
  history does not mean work finished. Re-derive state from the ticket artifacts and the
  changed files, never from the fact that the context was compacted.

## Inputs

You will receive:
- Ticket ID (e.g. `t-d53d`)
- The model you are running on, as designated by the caller — exactly `haiku`, the exact session model id (e.g. `claude-sonnet-5`), or the exact value of an explicit `Gate model:` override, never a paraphrase like "session default" or a parenthetical addition. Record it verbatim in your report; do not infer or reformat it yourself.
- Base ref (optional — only present for a headless CI dispatch grading an existing PR/diff; absent for a normal interactive sprint close, in which case the standard `git merge-base HEAD origin/main` derivation below applies unchanged).

## Tools

Use Read and Bash only. Do not use the Edit or Write tools, or Agent, or any other tool — save output via Bash (e.g. `cat >>`), never the Write tool. Never write to, edit, or modify `acceptance.md`, `plan.md`, or any ticket file other than your own report — findings go there only.

## Report-writing safety (Windows Git Bash)

One-heredoc reports have failed on live Windows Git-Bash with `unexpected EOF while looking for matching \`''` — prose (contractions, possessives) plus quoted source citations (e.g. JS string literals) can push the total literal `'` count in one heredoc body to odd, which an outer quoting layer mishandles. Root cause not fully traced (live-reproduced only) — treat as defensive mitigation, not proven fix.

Write the report in separate `cat >>` calls, one per section — never one heredoc. Verify each append landed (Bash exit code, or re-read file tail) before the next section. Heredoc failure: retry the same chunk in smaller pieces until it succeeds. Never drop content or paraphrase a quoted citation to dodge the error — quoted source text stays byte-exact.

**If Bash file-writing is refused outright** (a permission boundary, not a quoting/heredoc
failure — live-reproduced on a real harness install where `Plan`-type Bash refuses all
file-modifying commands, stricter than the Tools section above assumes): do not retry with
smaller chunks, that won't help a permission refusal. Do not ask for or accept broader tool
access (e.g. a re-dispatch as `general-purpose`) to work around it — that defeats the whole
reason this gate runs as `Plan` in the first place. Instead, include your full report,
verbatim, in the exact format specified in the calling protocol, in your final text response
to the caller. The orchestrating agent will save it itself.

## Self-serve visual verification (no Node/Playwright required)

<!-- Required-visual language locked by tests/doc-mirror-parity.sh Check E. -->
<!-- Base-ref/fallback commands below locked by Checks A and D. -->
<!-- review.md/eval.md reference this section (not inline copies) — Check B. -->

**Check for a project-level override first.** If the project's own `AGENTS.md`/`CLAUDE.md`
explicitly forbids scripted/automated verification (e.g. "verify only by clicking through
the app yourself — no scripts, no automation, in any language or tool" — a real workshop
rule, deliberately teaching manual verification), that rule wins. Do not run this recipe;
grade the test-plan item `not-run` and say so, so a human verifies it by hand instead. This
check costs one file read and prevents silently violating an explicit project constraint
the rest of this protocol never otherwise surfaces to you.

Otherwise, this recipe is **required, not optional**, for any criterion or change
that affects rendered UI — layout, theme, styling/CSS (**including CSS embedded in
code**: Streamlit `_CSS` strings, styled-components/CSS-in-JS, inline styles, theme
tokens), chart output, or a widget swap. You have Bash, and a browser binary is
often already installed even when there is no Node/npm/Playwright in the project
(canon workshops deliberately run on machines without Node.js). If a browser binary
exists, render and grade against it — **do not report `not-run`** for a visual item
you could have rendered. The trigger is user-visible impact, not the file extension
in the diff: a change touching no `.css`/`.html` file can still be a UI change.

**Check adjacent/related elements, not just the one the sprint changed.** A change
that is in-scope and behaviorally correct can still silently break the *rendered*
styling of a nearby element — e.g. wrapping an input in a form changes a widget's
rendered testid, so CSS selectors defined elsewhere stop matching and the element
reverts to default styling (live case: overtone `t-b75f` — a button lost its
gradient this exact way, invisible to code review and to logic-only tests like
Streamlit AppTest). When you render, confirm the affected element AND the elements
around it still match their intended appearance, and flag any unintended visual
regression as a finding even if it falls outside the sprint's stated focus.

1. Find a browser binary: macOS `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
   (or Chromium/Edge at the equivalent path); Linux `which google-chrome`, `chromium`, or
   `chromium-browser`; Windows `where chrome`, or check the default `Program Files\Google\Chrome\Application\chrome.exe`.
   If none exist anywhere, the check stays `not-run` — this recipe only covers the common
   case where a browser IS installed but wasn't being used.
2. Render and capture in one call:
   ```
   "<browser>" --headless=new --disable-gpu --no-first-run --disable-background-networking \
     --disable-sync --disable-default-apps --screenshot="<out>.png" \
     --window-size=<W>,<H> --hide-scrollbars "file://<absolute-path-to-page>"
   ```
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
4. `Read` the resulting PNG directly — Read supports images — and grade the test-plan item
   against what you actually see, same evidentiary bar as any other citation.

## Base-ref derivation

If an explicit `Base ref` was passed (headless CI dispatch), run:
```
git diff --name-only <base-ref> HEAD
```
Otherwise (normal interactive sprint close), run:
```
git diff --name-only $(git merge-base HEAD origin/main) HEAD
```
Use this output as your changed-files list. Do not trust a file list passed by the invoker — always derive from git.

If that fails — `origin/main` does not exist (no remote, detached HEAD) **or** the directory is not a git repository at all — fall back in two tiers:
- If `HEAD` resolves (the repo has ≥1 commit): diff against the repo's first commit instead — `git diff --name-only $(git rev-list --max-parents=0 HEAD) HEAD`, plus untracked files (`git status --porcelain`) — and read those real changed files rather than falling back to ticket artifacts.
- If `HEAD` does not resolve (zero commits) or git itself is unavailable: log a warning noting no git baseline is available and treat every file currently in the working tree as the changed-file set (excluding `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next`).

## Citation format

When citing evidence: `file:line — \`quoted text\`` (the exact line content). A line number without the quoted text is not evidence — it is unfalsifiable. If the quoted text itself contains a backtick, escape it as `` \` `` inside the citation — the board's renderer treats a backslash-escaped backtick as literal, so the whole citation still renders as one code span.
