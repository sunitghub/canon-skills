# Custom Themes

The Cockpit's **◐ Theme** menu lists the eight default themes ([Themes](../THEMES.md)) and any theme you add as a
file. A theme is a name, a mode and 12 colours; canon works out every other colour the Cockpit
and its boards need from those 12.

## Where the files go

`~/.canon/themes/` (or `$CANON_HOME/themes/` if you set `CANON_HOME`). Each `.json` file directly in that folder is
one theme. Click **Open themes folder** at the bottom of the ◐ Theme menu: if the folder does not exist yet, canon
creates it with a working `example.json` and a short `README.md`, then opens it. It never overwrites a file that is
already there, and it adds nothing to a folder that already exists.

A new or changed file shows up the next time you open the menu. Your theme appears with the built-ins of its mode
(Light or Dark); pick it like any other.

## The format

```json
{
  "name": "Example Dark",
  "mode": "dark",
  "colors": {
    "bg": "#1f2430",
    "surface": "#272d3a",
    "border": "#3a4252",
    "text": "#eef1f6",
    "body": "#c4cad6",
    "muted": "#a3abba",
    "accent": "#5aa9e6",
    "ok": "#6cc070",
    "warn": "#e6b450",
    "bad": "#ef6b73",
    "info": "#79b8ff",
    "term": "#171b24"
  }
}
```

| Key | Colours |
|---|---|
| `bg` | the page background |
| `surface` | panels, cards and menus |
| `border` | lines and outlines |
| `text` | headings and main text |
| `body` | body text |
| `muted` | secondary text and the Open column |
| `accent` | buttons, links, selection and focus |
| `ok` | done and success |
| `warn` | needs attention, working |
| `bad` | failures, needs you |
| `info` | in progress |
| `term` | the terminal background (required; used once the terminal follows the theme) |

## The rules

A theme file is read only when all of these hold:

- **File name:** lowercase letters, digits and dashes, starting with a letter or digit, at most 30 characters before
  `.json` (`my-theme.json`). The theme's id is `user-` plus that name.
- **A plain file** directly in the folder: a symbolic link is not read, and subfolders are not looked into. The folder
  itself may be a link (for example into your dotfiles).
- **At most 16 KiB**, UTF-8 without a byte order mark, valid JSON, nested at most 8 levels.
- **Exactly three keys:** `name`, `mode` and `colors`. Any other key, even `$schema`, refuses the file.
- **`name`:** 1 to 40 characters, each a letter, digit, space or one of `. _ ( ) + -`.
- **`mode`:** `light` or `dark`.
- **`colors`:** exactly the 12 keys above, each `#rgb` or `#rrggbb` (upper or lower case). No colour names, `rgb()`,
  `var()` or anything else.
- At most 50 theme files are read, in name order.

If a key appears twice, the last one counts.

The same rules are written as a JSON Schema in
[`tools/sprint-check-app/theme.schema.json`](../tools/sprint-check-app/theme.schema.json); the file-level rules (name,
link, size, encoding, nesting) are in its description.

## When a file is refused

A file that breaks a rule is never applied. It is listed under **Your own** in the ◐ Theme menu with the reason, for
example `my-theme.json: colors.accent must be #rgb or #rrggbb`. Fix the file and reopen the menu.

If the theme you picked is later deleted or refused, the Cockpit shows Canon Dark or Canon Light for that mode and keeps
your pick, so fixing the file brings your theme back.

## Readability

The default themes are all held to WCAG AA. Your theme is checked against the same floor: 4.5:1 for text on the
background and for muted text on panels, 3:1 for the accent on the background and for text on the accent. A theme below
it can still be used; its card says **Low contrast**, and hovering the mark shows which pair failed and its ratio.

## Safety

Anything can write to that folder, so canon treats its files as untrusted. Both board servers check every file with the
rules above and the page checks each one again before using it. Colours are set one variable at a time, never as CSS
text, and names and reasons are shown as plain text. **Open themes folder** opens that one folder in your file manager,
and nothing else.
