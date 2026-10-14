# Your Cockpit themes

Each `.json` file in this folder is a theme. It appears in the Cockpit's ◐ Theme menu, under Light or Dark by its
`mode`. Copy `example.json`, rename it, change the colours, then reopen the menu.

A theme file is exactly:

    { "name": "My Theme", "mode": "dark", "colors": { ...12 colours... } }

- File name: lowercase letters, digits and dashes, ending in `.json` (`my-theme.json`).
- `name`: 1 to 40 letters, digits, spaces or `. _ ( ) + -`.
- `mode`: `light` or `dark`.
- `colors`: exactly these 12 keys, each `#rgb` or `#rrggbb`:
  - `bg`: the page background
  - `surface`: panels and cards
  - `border`: lines and outlines
  - `text`: headings and main text
  - `body`: body text
  - `muted`: secondary text
  - `accent`: buttons, links and the selection
  - `ok`, `warn`, `bad`: done, attention and failure states
  - `info`: in-progress states
  - `term`: the terminal background (required; used once the terminal follows the theme)
- No other keys, at most 16 KiB, a plain file (not a link).

A file that breaks a rule is listed under "Your own" in the menu with the reason, and is never applied. A theme whose
text is hard to read is marked "Low contrast".

Full guide: https://getcanon.dev/docs/custom-themes
